import Foundation
@testable import OtterTwin

/// The error every injected fault throws (unless a test passes its own).
struct InjectedFault: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// A fault that fires once the byte stream of one file reaches `offset`.
struct ByteFault {
    /// Bytes `0..<offset` get through; the fault fires on the first byte at `offset`.
    let offset: Int64
    var error = InjectedFault(message: "Injected I/O fault")
}

// MARK: - FaultInjectingProvider

/// Data-safety harness (#24): a `VFSProvider` that performs real operations
/// through `LocalProvider` and injects deterministic faults per path:
///
/// - read fault at byte N, write fault at byte N, silent corruption (one byte
///   flipped in the written data), close fault, delete / move / trash faults;
/// - pause points before the k-th chunk read of a file, so a test can act
///   (e.g. cancel) exactly during the copy or exactly during verification.
///
/// Reads are pull-based and do their own I/O (opened on the first pull, one
/// chunk read per pull, no read-ahead): at a pause point before chunk k the
/// consumer has processed exactly k chunks and no further byte has been read.
///
/// "Trash" is simulated by moving items into a test-owned folder, so nothing
/// ever leaves the test's temp directory. Faults match on the standardized path.
///
/// Since #27 a copy is verified in the writer's temporary file, before it is
/// moved into place. Reads of a writer's temporary file therefore count as
/// reads of its final URL: read faults, pause points and recorded reads are
/// keyed by the final URL, as before. `rename` replaces the renames that
/// writers and `replaceItem` finalize with (see `AtomicRename.withoutRenameFlags`).
///
/// Verification reads (#28) go through `openForVerification`, which opens the
/// file with the production `UncachedFileReader` (new descriptor, `F_NOCACHE`)
/// and records each open in `verificationOpens`, with the state of the writer
/// at that moment (flushed and closed or not). Read faults and pause points
/// apply to these reads as to `readChunks`. `flush` replaces the flush
/// primitives writers use (see `FileFlush.withoutFullFsync`).
final class FaultInjectingProvider: VFSProvider, @unchecked Sendable {
    private let local = LocalProvider()
    private let fakeTrash: URL
    private let lock = NSLock()

    private var _supportsTrash: Bool
    private var _managedRoot: URL?
    private var _readFaults: [URL: ByteFault] = [:]
    private var _writeFaults: [URL: ByteFault] = [:]
    private var _corruptions: [URL: Int64] = [:]
    private var _closeFaults: [URL: InjectedFault] = [:]
    private var _deleteFaults: [URL: InjectedFault] = [:]
    private var _moveFaults: [URL: InjectedFault] = [:]
    private var _trashFaults: [URL: InjectedFault] = [:]
    private var _readPauses: [URL: [Int: PausePoint]] = [:]
    private var _finalizeHooks: [URL: @Sendable () -> Void] = [:]
    private var _rename: AtomicRename = .system
    private var _flush: FileFlush = .system
    private var _writers: [String: WeakWriter] = [:]
    private var _verificationOpens: [VerificationOpen] = []
    private var _temporaryFiles: [String: URL] = [:]
    private var _replaceCalls: [(source: URL, destination: URL)] = []
    private var _trashCalls: [URL] = []
    private var _deleteCalls: [URL] = []
    private var _moveCalls: [(from: URL, to: URL)] = []
    private var _readCalls: [URL] = []
    private var _writerCalls: [URL] = []
    private var _bytesDelivered: [String: Int64] = [:]
    private var _finishedReads: [String: Int] = [:]

    init(fakeTrash: URL, supportsTrash: Bool = true) {
        self.fakeTrash = fakeTrash
        self._supportsTrash = supportsTrash
    }

    private func locked<T>(_ body: () -> T) -> T { lock.withLock(body) }

    // MARK: Configuration

    var supportsTrash: Bool {
        get { locked { _supportsTrash } }
        set { locked { _supportsTrash = newValue } }
    }
    /// When set, the provider only manages paths inside this root (like a mounted share).
    var managedRoot: URL? {
        get { locked { _managedRoot } }
        set { locked { _managedRoot = newValue } }
    }
    /// Reading the file yields bytes `0..<offset`, then the stream throws.
    var readFaults: [URL: ByteFault] {
        get { locked { _readFaults } }
        set { locked { _readFaults = newValue } }
    }
    /// Writing the file stores bytes `0..<offset`, then `write` throws (and keeps throwing).
    var writeFaults: [URL: ByteFault] {
        get { locked { _writeFaults } }
        set { locked { _writeFaults = newValue } }
    }
    /// Silent corruption: the written byte at this offset is XOR-ed with 0xFF; nothing throws.
    var corruptions: [URL: Int64] {
        get { locked { _corruptions } }
        set { locked { _corruptions = newValue } }
    }
    /// `close()` closes the handle (data already written stays) and then throws.
    var closeFaults: [URL: InjectedFault] {
        get { locked { _closeFaults } }
        set { locked { _closeFaults = newValue } }
    }
    var deleteFaults: [URL: InjectedFault] {
        get { locked { _deleteFaults } }
        set { locked { _deleteFaults = newValue } }
    }
    /// Keyed by the move's source.
    var moveFaults: [URL: InjectedFault] {
        get { locked { _moveFaults } }
        set { locked { _moveFaults = newValue } }
    }
    var trashFaults: [URL: InjectedFault] {
        get { locked { _trashFaults } }
        set { locked { _trashFaults = newValue } }
    }

    /// Runs right after a writer for the URL (the final destination) has
    /// successfully committed (moved its file into place), synchronously in the
    /// task that called `commit()`. Lets a test act (e.g. cancel the current task
    /// with `withUnsafeCurrentTask`) exactly between finalizing and what follows.
    var finalizeHooks: [URL: @Sendable () -> Void] {
        get { locked { _finalizeHooks } }
        set { locked { _finalizeHooks = newValue } }
    }

    /// The rename primitive writers and `replaceItem` use to finalize.
    var rename: AtomicRename {
        get { locked { _rename } }
        set { locked { _rename = newValue } }
    }

    /// The flush primitives writers use in `finishWriting()` (#28).
    var flush: FileFlush {
        get { locked { _flush } }
        set { locked { _flush = newValue } }
    }

    /// Returns a pause point that holds the next read of `url` right before its
    /// `chunkIndex`-th chunk (0-based) is read, in every read stream of `url`.
    @discardableResult
    func pauseRead(of url: URL, beforeChunk chunkIndex: Int) -> PausePoint {
        let pause = PausePoint()
        locked { _readPauses[url, default: [:]][chunkIndex] = pause }
        return pause
    }

    // MARK: Recorded calls

    var trashCalls: [URL] { locked { _trashCalls } }
    var deleteCalls: [URL] { locked { _deleteCalls } }
    var moveCalls: [(from: URL, to: URL)] { locked { _moveCalls } }
    var replaceCalls: [(source: URL, destination: URL)] { locked { _replaceCalls } }
    var readCalls: [URL] { locked { _readCalls } }
    var writerCalls: [URL] { locked { _writerCalls } }
    /// Every `openForVerification` call (#28), in order.
    var verificationOpens: [VerificationOpen] { locked { _verificationOpens } }

    /// One verification open (#28), as seen when the descriptor was opened.
    struct VerificationOpen {
        /// The final URL (a writer's temporary file is reported as its final URL).
        let url: URL
        /// The file actually opened (e.g. the writer's temporary file).
        let openedURL: URL
        /// `F_NOCACHE` was set on the new descriptor (`UncachedFileReader`).
        let cacheBypassed: Bool
        /// For a writer's temporary file: whether the writer had closed its
        /// descriptor, and how it had flushed, when verification opened the file.
        /// nil when the file was not written by a writer of this provider.
        let writerClosed: Bool?
        let writerFlushMode: FlushMode?
    }
    /// Bytes delivered so far by read streams of `url` (all streams combined).
    func bytesDelivered(from url: URL) -> Int64 { locked { _bytesDelivered[Self.key(url)] ?? 0 } }
    /// Read streams of `url` that ran to their end (EOF, error or cancellation).
    func finishedReadCount(of url: URL) -> Int { locked { _finishedReads[Self.key(url)] ?? 0 } }

    /// Waits until `count` read streams of `url` have finished. Returns false on timeout.
    func waitUntilReadsFinished(of url: URL, count: Int = 1, timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while finishedReadCount(of: url) < count {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)  // test polling; the deadline bounds the wait
        }
        return true
    }

    // MARK: VFSProvider

    func listDirectory(_ url: URL) async throws -> [FileItem] { try await local.listDirectory(url) }
    func attributes(of url: URL) async throws -> FileItem { try await local.attributes(of: url) }
    func createDirectory(at url: URL) async throws { try await local.createDirectory(at: url) }

    func readChunks(of url: URL, chunkSize: Int) -> AsyncThrowingStream<Data, Error> {
        let (logical, fault, pauses) = beginRead(of: url)
        return stream(of: logical, state: ReadState(url: url, chunkSize: chunkSize, reader: nil,
                                                    onFinish: finishedReadHandler(logical)),
                      fault: fault, pauses: pauses)
    }

    /// Opens the file now with the production `UncachedFileReader` and records
    /// the open (see `verificationOpens`). Faults and pauses as for `readChunks`.
    func openForVerification(_ url: URL, chunkSize: Int) throws -> VerificationRead {
        let (logical, fault, pauses) = beginRead(of: url)
        let writer = locked { _writers[Self.key(url)]?.writer }
        let reader = try UncachedFileReader(url: url)
        let open = VerificationOpen(url: logical, openedURL: url, cacheBypassed: reader.cacheBypassed,
                                    writerClosed: writer.map { $0.isWritingFinished },
                                    writerFlushMode: writer?.flushMode)
        locked { _verificationOpens.append(open) }
        let state = ReadState(url: url, chunkSize: chunkSize, reader: reader, onFinish: finishedReadHandler(logical))
        return VerificationRead(chunks: stream(of: logical, state: state, fault: fault, pauses: pauses),
                                cacheBypassed: reader.cacheBypassed)
    }

    /// Records a read of `url` and returns its logical URL, fault and pause points.
    private func beginRead(of url: URL) -> (URL, ByteFault?, [Int: PausePoint]) {
        locked { () -> (URL, ByteFault?, [Int: PausePoint]) in
            // A writer's temporary file is read as its final URL (#27, see above).
            let logical = _temporaryFiles[Self.key(url)] ?? url
            _readCalls.append(logical)
            return (logical, Self.lookup(_readFaults, logical), Self.lookup(_readPauses, logical) ?? [:])
        }
    }

    private func finishedReadHandler(_ logical: URL) -> () -> Void {
        let key = Self.key(logical)
        return { [self] in self.locked { self._finishedReads[key, default: 0] += 1 } }
    }

    private func stream(of logical: URL, state: ReadState, fault: ByteFault?,
                        pauses: [Int: PausePoint]) -> AsyncThrowingStream<Data, Error> {
        let key = Self.key(logical)
        return AsyncThrowingStream(unfolding: { [self] in
            if let pending = state.pendingError {
                state.pendingError = nil
                state.finished = true
                throw pending
            }
            if state.finished { return nil }
            if let pause = pauses[state.chunkIndex] {
                await pause.arrive()
            }
            do {
                try Task.checkCancellation()
            } catch {
                state.finished = true
                throw error
            }
            let next: Data?
            do {
                next = try state.readNextChunk()
            } catch {
                state.finished = true
                throw error
            }
            guard var chunk = next else {
                state.finished = true
                return nil
            }
            if let fault, state.offset + Int64(chunk.count) > fault.offset {
                let keep = Int(max(0, fault.offset - state.offset))
                guard keep > 0 else {
                    state.finished = true
                    throw fault.error
                }
                chunk = chunk.prefix(keep)
                state.pendingError = fault.error
            }
            state.offset += Int64(chunk.count)
            state.chunkIndex += 1
            let count = Int64(chunk.count)
            self.locked { self._bytesDelivered[key, default: 0] += count }
            return chunk
        })
    }

    func makeWriter(at url: URL, replacingExisting: Bool) throws -> ChunkedWriter {
        let (faults, rename, flush) = locked { () -> (FaultInjectingWriter.Faults, AtomicRename, FileFlush) in
            _writerCalls.append(url)
            return (FaultInjectingWriter.Faults(
                write: Self.lookup(_writeFaults, url),
                corruptAt: Self.lookup(_corruptions, url),
                close: Self.lookup(_closeFaults, url),
                afterFinalize: Self.lookup(_finalizeHooks, url)
            ), _rename, _flush)
        }
        let writer = try FaultInjectingWriter(url: url, replacingExisting: replacingExisting, rename: rename,
                                              flush: flush, faults: faults)
        locked {
            _temporaryFiles[Self.key(writer.temporaryURL)] = url
            _writers[Self.key(writer.temporaryURL)] = WeakWriter(writer: writer)
        }
        return writer
    }

    func delete(_ url: URL) async throws {
        let fault = locked { () -> InjectedFault? in
            _deleteCalls.append(url)
            return Self.lookup(_deleteFaults, url)
        }
        if let fault { throw fault }
        try await local.delete(url)
    }

    func move(from: URL, to: URL) async throws {
        let fault = locked { () -> InjectedFault? in
            _moveCalls.append((from, to))
            return Self.lookup(_moveFaults, from)
        }
        if let fault { throw fault }
        try await local.move(from: from, to: to)
    }

    /// Keyed by `source` for `moveFaults`, like `move`.
    func replaceItem(at destination: URL, withItemAt source: URL) async throws {
        let (fault, rename) = locked { () -> (InjectedFault?, AtomicRename) in
            _replaceCalls.append((source, destination))
            return (Self.lookup(_moveFaults, source), _rename)
        }
        if let fault { throw fault }
        try rename.replace(destination, with: source, backup: ChunkedWriter.backupURL(for: destination), swapping: false)
    }

    @discardableResult
    func trash(_ url: URL) async throws -> URL? {
        let (supported, fault) = locked { () -> (Bool, InjectedFault?) in
            _trashCalls.append(url)
            return (_supportsTrash, Self.lookup(_trashFaults, url))
        }
        guard supported else { throw TrashNotSupportedError() }
        if let fault { throw fault }
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let target = fakeTrash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    func manages(_ url: URL) -> Bool {
        guard let managedRoot else { return true }
        return url.isContained(in: managedRoot)
    }

    // MARK: Helpers

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private static func lookup<V>(_ table: [URL: V], _ url: URL) -> V? {
        if let exact = table[url] { return exact }
        let wanted = key(url)
        return table.first { key($0.key) == wanted }?.value
    }

    private struct WeakWriter {
        weak var writer: ChunkedWriter?
    }

    /// Mutable state of one pull-based read stream. Only touched by the
    /// stream's consumer, one `next()` at a time. The file is opened on the
    /// first pull and read one chunk per pull, so nothing is read ahead of the
    /// consumer (unlike `LocalProvider.readChunks`, which buffers ahead).
    private final class ReadState: @unchecked Sendable {
        let url: URL
        let chunkSize: Int
        private var handle: FileHandle?
        /// Verification reads (#28): the production uncached reader, already open.
        private var reader: UncachedFileReader?
        var offset: Int64 = 0
        var chunkIndex = 0
        var pendingError: Error?
        private let onFinish: () -> Void
        var finished = false {
            didSet {
                guard finished, !oldValue else { return }
                closeHandle()
                onFinish()
            }
        }

        init(url: URL, chunkSize: Int, reader: UncachedFileReader?, onFinish: @escaping () -> Void) {
            self.url = url
            self.chunkSize = chunkSize
            self.reader = reader
            self.onFinish = onFinish
        }

        /// Same calls as `LocalProvider.readChunks` (or, for verification
        /// reads, `UncachedFileReader`); nil at end of file.
        func readNextChunk() throws -> Data? {
            if let reader { return try reader.read(upToCount: chunkSize) }
            if handle == nil { handle = try FileHandle(forReadingFrom: url) }
            let chunk = try handle?.read(upToCount: chunkSize) ?? Data()
            return chunk.isEmpty ? nil : chunk
        }

        private func closeHandle() {
            try? handle?.close()  // read-only handle; nothing to flush, a close error cannot lose data
            handle = nil
            reader?.close()
            reader = nil
        }

        deinit { closeHandle() }
    }
}

// MARK: - FaultInjectingWriter

/// `ChunkedWriter` that writes through to the real (temporary) file and injects
/// the faults it was created with. Offsets are absolute positions in the file.
final class FaultInjectingWriter: ChunkedWriter {
    struct Faults {
        var write: ByteFault?
        var corruptAt: Int64?
        var close: InjectedFault?
        var afterFinalize: (@Sendable () -> Void)?
    }

    private let faults: Faults
    private var offset: Int64 = 0
    private var isClosed = false
    private var isCommitted = false

    init(url: URL, replacingExisting: Bool = false, rename: AtomicRename = .system,
         flush: FileFlush = .system, faults: Faults) throws {
        self.faults = faults
        try super.init(url: url, replacingExisting: replacingExisting, rename: rename, flush: flush)
    }

    override func write(_ chunk: Data) throws {
        var chunk = chunk
        let count = Int64(chunk.count)
        if let corruptAt = faults.corruptAt, corruptAt >= offset, corruptAt < offset + count {
            let index = chunk.startIndex + Int(corruptAt - offset)
            chunk[index] ^= 0xFF
        }
        if let fault = faults.write, offset + count > fault.offset {
            let keep = Int(max(0, fault.offset - offset))
            if keep > 0 {
                try super.write(chunk.prefix(keep))
                offset += Int64(keep)
            }
            throw fault.error
        }
        try super.write(chunk)
        offset += count
    }

    /// With a close fault, finishing the file fails and nothing is finalized:
    /// the data written so far stays in `temporaryURL` until the caller's
    /// `abort()` removes it (#6).
    @discardableResult
    override func finishWriting() throws -> FlushMode {
        if let fault = faults.close {
            throw fault
        }
        return try super.finishWriting()
    }

    override func commit() throws {
        guard !isCommitted else { return }
        try super.commit()
        isCommitted = true
        isClosed = true
        faults.afterFinalize?()
    }

    override func abort() {
        guard !isClosed else { return }
        isClosed = true
        super.abort()
    }
}

// MARK: - PausePoint

/// A deterministic rendezvous between the provider (which `arrive()`s and
/// waits) and a test (which waits until the point is reached, acts, then
/// `release()`s it). Continuation-based: nothing runs past the point until
/// `release()` is called.
final class PausePoint: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    var isReached: Bool { lock.withLock { reached } }

    /// Provider side: marks the point reached and suspends until released.
    func arrive() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                reached = true
                if released { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Test side: lets the provider continue. Safe to call more than once.
    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }

    /// Test side: waits until the provider has arrived. Returns false on timeout.
    func waitUntilReached(timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isReached {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)  // test polling; the deadline bounds the wait
        }
        return true
    }
}

// MARK: - FileFlush simulations

extension FileFlush {
    /// Behaves like a file system without `F_FULLFSYNC` (e.g. smbfs; the macOS
    /// ExFAT and FAT32 drivers support it, at least on the CI runner):
    /// `F_FULLFSYNC` fails with `fullFsyncError` (`ENOTSUP` by default) and
    /// the real `fsync` runs, unless `fsyncError` makes it fail too. `calls`
    /// counts the calls.
    static func withoutFullFsync(fullFsyncError: Int32 = ENOTSUP, fsyncError: Int32? = nil,
                                 calls: FlushCalls = FlushCalls()) -> FileFlush {
        FileFlush(
            fullFsync: { _ in calls.recordFullFsync(); return fullFsyncError },
            fsync: { fd in
                calls.recordFsync()
                if let fsyncError { return fsyncError }
                return FileFlush.system.fsync(fd)
            }
        )
    }
}

/// Counts the flush calls of a simulated `FileFlush`.
final class FlushCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var _fullFsync = 0
    private var _fsync = 0
    var fullFsync: Int { lock.withLock { _fullFsync } }
    var fsync: Int { lock.withLock { _fsync } }
    func recordFullFsync() { lock.withLock { _fullFsync += 1 } }
    func recordFsync() { lock.withLock { _fsync += 1 } }
}

// MARK: - AtomicRename simulations

extension AtomicRename {
    /// Behaves like a file system without `RENAME_EXCL` and `RENAME_SWAP`
    /// (smbfs, ExFAT, FAT): every flagged rename fails with `ENOTSUP`, so
    /// `AtomicRename` takes its fallback. `intercept` runs before each plain
    /// rename; returning an errno fails that rename (nothing is renamed),
    /// returning nil lets it happen. Use it to inject failures, or to create a
    /// file, between the fallback's steps.
    static func withoutRenameFlags(
        intercept: @escaping (_ from: URL, _ to: URL) -> Int32? = { _, _ in nil }
    ) -> AtomicRename {
        AtomicRename { from, to, flags in
            if flags != 0 { return ENOTSUP }
            if let injected = intercept(URL(fileURLWithPath: from), URL(fileURLWithPath: to)) { return injected }
            return AtomicRename.system.renamex(from, to, 0)
        }
    }
}
