# Testing OtterTwin

Unit and snapshot tests live in `OtterTwinTests/` (XCTest). They run in the macOS CI job
`build-and-test` on every pull request; that job is the merge gate. See `CLAUDE.md` for the
`xcodebuild` commands to run them locally.

File-operation code (copy, move, delete, verify) must be tested with the **data-safety harness**
below (`docs/agent-workflow.md`, section 3). Its own self-tests and the characterization tests of
the current behaviour are in `OtterTwinTests/HarnessTests/`.

## The data-safety harness (`OtterTwinTests/Harness/`)

All harness code is test-only. Production code has one documented test hook: `ChunkedWriter`
is not `final`, so the harness can subclass it to inject write faults.

### `FixtureTree`: disposable, deterministic trees

```swift
var options = FixtureTree.Options()   // seed, chunkSize, largeFileSize, includeSymlinks
options.chunkSize = 64 * 1024         // use the chunk size the code under test uses
let tree = try FixtureTree.build(at: tempDir.appendingPathComponent("tree"), options: options)
let source = tree.url(FixtureTree.Path.multiChunk)
```

The tree is built with POSIX calls, so names reach the disk byte-exactly. Content comes from
the seed and each file's path, so building with the same seed gives the same bytes. It contains:

- nested folders (depth ≥ 5) and empty folders;
- an empty file, files of exactly chunk − 1, chunk and chunk + 1 bytes, a multi-chunk file
  (≥ 3 chunks) and `large.bin` (64 MiB by default);
- hidden files and folders (`.dotfile`, `.hidden_dir/…`);
- the same Unicode name in NFC and in NFD form (in separate folders, because APFS treats both
  spellings as one name within a folder), names with spaces, emoji and a 255-byte name;
- symlinks to a file, to a folder, a dangling one and a two-link loop (`includeSymlinks`);
- a read-only file, a file with an extended attribute and a file with a custom mtime.

Set `largeFileSize` in a test, or the environment variable `OTTERTWIN_FIXTURE_LARGE_FILE_BYTES`,
to change the default 64 MiB. To pass that variable through `xcodebuild`, use
`TEST_RUNNER_OTTERTWIN_FIXTURE_LARGE_FILE_BYTES=…`.

Only build trees inside a temp directory the test owns and removes in `tearDown`.

### `TreeComparator`: independent comparison

`TreeComparator` walks both trees with `lstat`/`readdir`/`readlink`/`getxattr` and its own
SHA-256. It never uses the app's VFS code and never follows symlinks. It includes hidden entries,
and it keys entries by their raw UTF-8 bytes, so an NFC/NFD change shows up as one missing entry
plus one extra entry.

```swift
// Turn on only what the feature guarantees:
let comparator = TreeComparator(checks: .data)            // presence, type, size, content, symlink target
let strict     = TreeComparator(checks: .all, mtimeTolerance: 2)   // + mtime, permissions, xattrs
assertTreesEqual(expected: source, actual: destination, comparator: comparator)

// Prove that an operation left something untouched:
let before = try TreeSnapshot.capture(source)
// … operation …
assertTree(source, matches: before)                       // all checks, including mtime
```

Checks: `.presence` (missing or extra), `.type`, `.size`, `.content`, `.symlinkTarget`, `.mtime`
(with `mtimeTolerance`, for directories too), `.permissions`, `.xattrs` (ignores
`com.apple.provenance`, which macOS may add on its own). `excluding:` drops paths from both sides,
for example `TreeComparator.isHidden`.

### `FaultInjectingProvider`: deterministic faults

A `VFSProvider` that does real work through `LocalProvider` and injects faults by path:

| Property | Effect |
|---|---|
| `readFaults[url] = ByteFault(offset: N)` | reading `url` yields bytes `0..<N`, then throws |
| `writeFaults[url] = ByteFault(offset: N)` | writing `url` stores bytes `0..<N`, then `write` throws (and keeps throwing) |
| `corruptions[url] = N` | silent corruption: the written byte at `N` is flipped (XOR 0xFF) |
| `closeFaults[url]` | finishing the file (`finishWriting()`, also via `close()`) throws before finalizing; the data stays in the writer's temporary file until `abort()` |
| `deleteFaults[url]`, `moveFaults[source]`, `trashFaults[url]` | the call throws and changes nothing (`moveFaults` also apply to `replaceItem`) |
| `pauseRead(of: url, beforeChunk: k)` | returns a `PausePoint`; the read stops right before chunk `k` |
| `finalizeHooks[url] = { … }` | runs synchronously in the writing task right after a writer for `url` committed (moved its file into place), e.g. to cancel that task with `withUnsafeCurrentTask` |
| `rename = .withoutRenameFlags(intercept:)` | writers and `replaceItem` finalize as on smbfs/ExFAT (no `RENAME_EXCL`/`RENAME_SWAP`), so the fallback runs on APFS too; `intercept` can fail or act around each plain rename |
| `flush = .withoutFullFsync(fullFsyncError:fsyncError:calls:)` | writers flush as on smbfs/ExFAT: `F_FULLFSYNC` fails (`ENOTSUP` by default) and the real `fsync` runs, or fails with `fsyncError`; `FlushCalls` counts the calls |

Faults fire at the same byte for any chunk size, every time. Reads are pull-based: a chunk is
read only when the consumer asks for it. So at a pause point before chunk `k` of the source, the
copy has written exactly `k` chunks. A pause before chunk 0 of the destination is exactly the
start of verification:

```swift
let pause = provider.pauseRead(of: destination, beforeChunk: 0)   // = during verification
let operation = Task { /* run the copy */ }
let reached = await pause.waitUntilReached()   // false after a timeout
operation.cancel()                                                 // act at exactly this point
pause.release()
```

Writes go through `ChunkedWriter` (#6): the data is written to a hidden temporary file in the
destination folder, `.<name>.ottertwin-<uuid>.part` (`writer.temporaryURL`). Since #27 the copy is
verified in that file (`finishWriting()`, verify, then `commit()`), and it appears under the final
name only when `commit()` succeeds: `RENAME_EXCL` for a new destination, `RENAME_SWAP` for a copy
with `.overwrite`, or (without swap support) the fallback that parks the original as
`.<name>.ottertwin-<uuid>.old` and restores it on failure (see `AtomicRename`). Same-volume moves with
`.overwrite` (`replaceItem`) never swap: they always park the original as `.old`, so the old
destination can never land at the user-visible source path. Faults are still keyed by the final URL,
and reads of a writer's temporary file count as reads of its final URL (read faults, pause points,
`readCalls`), so a pause before chunk 0 of the destination is still exactly the start of
verification. To find partial files, filter a directory listing with
`ChunkedWriter.isDiscardablePartialFileName`; parked originals match
`ChunkedWriter.isParkedOriginalFileName`. A `.old` that remains (e.g. after a failed restore) can be
the user's only copy of the original and must never be deleted automatically.

"Trash" moves items into a folder you pass to `init(fakeTrash:)`, never into `~/.Trash`. The
provider also records calls (`readCalls`, `writerCalls`, `deleteCalls`, `moveCalls`,
`replaceCalls`, `trashCalls`).

Verification reads (#28) go through `openForVerification`, which the harness implements with the
production `UncachedFileReader` (a new descriptor with `F_NOCACHE`). Each open is recorded in
`verificationOpens` with the final URL, the file actually opened, whether `F_NOCACHE` was set, and the
writer's state at that moment (`writerClosed`, `writerFlushMode`), so a test can prove the copy was
flushed and closed before it was read back. Read faults and pause points apply to these reads too
(they also count in `readCalls`).

### `ScratchVolume`: separate volumes made by the test

```swift
let volume = try makeScratchVolume(.apfs)    // or .exfat, .fat32; 64 MB by default
let destination = volume.mountPoint.appendingPathComponent("file.bin")
```

`hdiutil` creates a disk image in the test's temp folder and attaches it there with `-nobrowse`,
not under `/Volumes`. `makeScratchVolume` registers a teardown block that always detaches the
image and deletes it, and a failed detach fails the test. When `hdiutil` is missing the test is
skipped (`XCTSkip`). Use it for cross-volume behaviour (copy and verify, then delete the source)
and for non-APFS file systems (ExFAT and FAT have no xattrs and coarse timestamps; ExFAT has no
`RENAME_SWAP`, while the macOS msdos driver for FAT32 does support it, see `AtomicRenameTests`).

### Characterization tests and known gaps

`CopyMoveCharacterizationTests` records what `FileOperationService` does today for single-file
copy, folder copy and cross-volume move. Assertions outside `XCTExpectFailure` are guarantees.
Known gaps are wrapped in `XCTExpectFailure("#<issue>: …")`:

| Gap | Issue |
|---|---|
| folder copy skips hidden entries and does not handle symlinks; folders cannot be moved across volumes | #9 |
| copy rewrites NFC file names to NFD (single file started like the UI, and folder copy) | #48 |
| mtime, permissions and xattrs are not preserved | #30 |

Each block holds one assertion, so a partial fix shows up. Blocks that compare trees pass `options: .treeDifferencesOnly`, so a harness error (for example, a failing `lstat`) is never counted as the expected failure. Expected failures are strict. When a fix makes a block pass, the test fails until the fixing PR
removes that `XCTExpectFailure` and keeps the assertion. The gap then becomes a guarantee.

Closed gaps: #27 (a failed overwrite destroyed the original destination). Atomic finalize is covered
by `AtomicFinalizeTests` (every case on the same volume, with and without rename flags, and onto
APFS and ExFAT scratch volumes) and `AtomicRenameTests` (the fallback's failure paths).
#28 (a cross-volume move with checksums off did not verify; a failed source delete after a verified
copy was an error): see the next section.

## What verification proves, and its limits (#28)

A copy is verified like this:

1. `ChunkedWriter.finishWriting()` flushes the temporary file with `fcntl(F_FULLFSYNC)`. Where the
   file system reports that unsupported (`ENOTSUP`, `EOPNOTSUPP`, `EINVAL`, `ENOTTY`; smbfs and
   possibly ExFAT/FAT), it uses `fsync` instead. Any other flush error fails the copy. Then it
   closes the descriptor. The temporary file is also written with `F_NOCACHE`, so its pages are not
   kept in the buffer cache.
2. Verification opens the file again (`VFSProvider.openForVerification`, `UncachedFileReader`):
   a new descriptor with `F_NOCACHE`, and hashes what it reads.
3. `VerificationResult.verified` records `flushMode` (`.fullFsync` or `.fsync`) and
   `cacheBypassed` (whether `F_NOCACHE` was set on the verification descriptor), for the summary and
   report (#11, #13).

Moves: a cross-volume move always verifies, even when checksums are off in Settings, because it
deletes the source. If deleting the source fails after a verified copy, the copy is kept and the
move ends `.partiallyComplete(result:, issue: .sourceNotRemoved(error))`, not as a failure. A
same-volume move is an atomic rename (`.renamed`): the data is not rewritten, so nothing is hashed.

Limits (not something the client can fix):

- `F_NOCACHE` only affects this Mac's unified buffer cache. A NAS's own RAM cache, a RAID
  controller's cache or a drive's write cache can still answer the read. With `.fsync` (smbfs, some
  removable file systems) the data was handed to the server or device, which may still hold it in
  volatile memory.
- `F_NOCACHE` stops the file's pages from being cached; pages another process cached may still be
  used. The writer's own `F_NOCACHE` keeps the copy's pages out of the cache in the first place.
- smbfs may keep its own client-side state for an open file; the verification descriptor is opened
  only after the writer's descriptor was closed.
- The directory entry (the rename in `commit()`) is not flushed separately.

Tests: `VerificationDurabilityTests` (spy on the verification open, writer flush, the
`F_FULLFSYNC` → `fsync` fallback on ExFAT and FAT32 scratch volumes, failed flushes) and
`CopyMoveCharacterizationTests` (cross-volume moves with checksums off, corruption, failed source
delete). Real SMB shares and NAS caches are checked by the owner at the gates.

## What CI verifies vs. what the owner checks at gates

Verified in CI (`build-and-test`, macOS runner):

- all unit, snapshot and harness tests, including the 64 MiB fixture and APFS, ExFAT and FAT32
  scratch volumes created with `hdiutil` on the runner;
- byte-exact copies, fault handling and cleanup on local APFS and on disk images.

Not verified in CI. The owner checks these manually at the gate issues (#36 to #39):

- real external disks and USB drives (their own caches, disconnects, sleep);
- SMB shares and the NAS: network drops, server-side caches, smbfs quirks (see #33 and #34);
- the UI flow end to end (XCUITest runs in the non-blocking `ui-tests` job, see #45);
- performance on very large real-world trees.
