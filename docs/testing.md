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
| `closeFaults[url]` | `close()` closes the file (data stays) and throws |
| `deleteFaults[url]`, `moveFaults[source]`, `trashFaults[url]` | the call throws and changes nothing |
| `pauseRead(of: url, beforeChunk: k)` | returns a `PausePoint`; the read stops right before chunk `k` |

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

"Trash" moves items into a folder you pass to `init(fakeTrash:)`, never into `~/.Trash`. The
provider also records calls (`readCalls`, `writerCalls`, `deleteCalls`, `moveCalls`,
`trashCalls`).

### `ScratchVolume`: separate volumes made by the test

```swift
let volume = try makeScratchVolume(.apfs)    // or .exfat, .fat32; 64 MB by default
let destination = volume.mountPoint.appendingPathComponent("file.bin")
```

`hdiutil` creates a disk image in the test's temp folder and attaches it there with `-nobrowse`,
not under `/Volumes`. `makeScratchVolume` registers a teardown block that always detaches the
image and deletes it, and a failed detach fails the test. When `hdiutil` is missing the test is
skipped (`XCTSkip`). Use it for cross-volume behaviour (copy and verify, then delete the source)
and for non-APFS file systems (ExFAT and FAT have no xattrs, coarse timestamps and no rename
swap).

### Characterization tests and known gaps

`CopyMoveCharacterizationTests` records what `FileOperationService` does today for single-file
copy, folder copy and cross-volume move. Assertions outside `XCTExpectFailure` are guarantees.
Known gaps are wrapped in `XCTExpectFailure("#<issue>: …")`:

| Gap | Issue |
|---|---|
| cancelling does not stop the running copy | #6 |
| folder copy skips hidden entries and does not handle symlinks; folders cannot be moved across volumes | #9 |
| a failed overwrite destroys the original destination | #27 |
| a cross-volume move with checksums off does not verify; a failed source delete is an error, not a partial success | #28 |
| mtime, permissions and xattrs are not preserved | #30 |

Expected failures are strict. When a fix makes a block pass, the test fails until the fixing PR
removes that `XCTExpectFailure` and keeps the assertion. The gap then becomes a guarantee.

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
