import XCTest
@testable import OtterTwin

/// #24: every `FaultInjectingProvider` fault fires deterministically — at the
/// same byte, whatever the chunk size, every time — and only for its path.
final class FaultInjectingProviderTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var provider: FaultInjectingProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("FaultInjectingProviderTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        provider = FaultInjectingProvider(fakeTrash: tempDir.appendingPathComponent("FakeTrash", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        tempDir = nil
        provider = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private let fault = InjectedFault(message: "injected")

    private func makeFile(_ name: String, size: Int) throws -> (URL, Data) {
        let url = tempDir.appendingPathComponent(name)
        let data = FixtureTree.content(for: name, size: size, seed: 42)
        try data.write(to: url)
        return (url, data)
    }

    /// Reads the whole stream; returns the bytes received and the error it ended with.
    private func readAll(_ url: URL, chunkSize: Int) async -> (Data, Error?) {
        var received = Data()
        do {
            for try await chunk in provider.readChunks(of: url, chunkSize: chunkSize) {
                received.append(chunk)
            }
            return (received, nil)
        } catch {
            return (received, error)
        }
    }

    /// Writes `data` in `chunkSize` pieces; returns how many `write` calls succeeded and the error.
    private func writeAll(_ data: Data, to url: URL, chunkSize: Int) throws -> (succeeded: Int, error: Error?) {
        let writer = try provider.makeWriter(at: url)
        var succeeded = 0
        var offset = 0
        do {
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                try writer.write(data.subdata(in: offset..<end))
                succeeded += 1
                offset = end
            }
            try writer.close()
            return (succeeded, nil)
        } catch {
            writer.abort()
            return (succeeded, error)
        }
    }

    // MARK: - Read fault

    func testReadFaultFiresAtTheSameByteForAnyChunkSize() async throws {
        let (url, data) = try makeFile("source.bin", size: 10_000)
        for offset in [0, 1, 4095, 4096, 4097, 9_999] {
            provider.readFaults = [url: ByteFault(offset: Int64(offset), error: fault)]
            for chunkSize in [1_024, 4_096, 7_777, 65_536] {
                for _ in 0..<2 {
                    let (received, error) = await readAll(url, chunkSize: chunkSize)
                    XCTAssertEqual(received, data.prefix(offset), "offset \(offset), chunk \(chunkSize)")
                    XCTAssertEqual(error as? InjectedFault, fault, "offset \(offset), chunk \(chunkSize)")
                }
            }
        }
    }

    func testReadFaultBeyondEndOfFileNeverFires() async throws {
        let (url, data) = try makeFile("source.bin", size: 5_000)
        provider.readFaults = [url: ByteFault(offset: 5_000, error: fault)]
        let (received, error) = await readAll(url, chunkSize: 1_024)
        XCTAssertEqual(received, data)
        XCTAssertNil(error)
    }

    func testReadFaultOnlyAffectsItsPath() async throws {
        let (url, _) = try makeFile("faulty.bin", size: 5_000)
        let (other, otherData) = try makeFile("other.bin", size: 5_000)
        provider.readFaults = [url: ByteFault(offset: 10, error: fault)]
        let (received, error) = await readAll(other, chunkSize: 1_024)
        XCTAssertEqual(received, otherData)
        XCTAssertNil(error)
        XCTAssertEqual(provider.readCalls, [other])
    }

    // MARK: - Write fault

    func testWriteFaultStoresExactlyTheBytesBeforeTheFault() throws {
        let data = FixtureTree.content(for: "w", size: 10_000, seed: 1)
        for offset in [0, 1, 4095, 4096, 4097, 9_999] {
            for chunkSize in [1_024, 4_096, 7_777, 65_536] {
                let url = tempDir.appendingPathComponent("w-\(offset)-\(chunkSize).bin")
                provider.writeFaults = [url: ByteFault(offset: Int64(offset), error: fault)]
                let (succeeded, error) = try writeAll(data, to: url, chunkSize: chunkSize)
                XCTAssertEqual(error as? InjectedFault, fault, "offset \(offset), chunk \(chunkSize)")
                XCTAssertEqual(succeeded, offset / chunkSize, "the write that reaches the offset throws")
                XCTAssertEqual(try Data(contentsOf: url), data.prefix(offset), "offset \(offset), chunk \(chunkSize)")
            }
        }
    }

    func testWriteFaultKeepsFiringAfterTheFirstTime() throws {
        let url = tempDir.appendingPathComponent("w.bin")
        provider.writeFaults = [url: ByteFault(offset: 3, error: fault)]
        let writer = try provider.makeWriter(at: url)
        XCTAssertThrowsError(try writer.write(Data([1, 2, 3, 4])))
        XCTAssertThrowsError(try writer.write(Data([5])))
        writer.abort()
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
    }

    // MARK: - Silent corruption

    func testCorruptionFlipsExactlyOneByteSilently() throws {
        let data = FixtureTree.content(for: "c", size: 10_000, seed: 1)
        for offset in [0, 4095, 4096, 9_999] {
            for chunkSize in [1_024, 4_096, 65_536] {
                let url = tempDir.appendingPathComponent("c-\(offset)-\(chunkSize).bin")
                provider.corruptions = [url: Int64(offset)]
                let (_, error) = try writeAll(data, to: url, chunkSize: chunkSize)
                XCTAssertNil(error, "corruption must not throw")
                let written = try Data(contentsOf: url)
                XCTAssertEqual(written.count, data.count)
                let differing = (0..<data.count).filter { written[$0] != data[$0] }
                XCTAssertEqual(differing, [offset], "offset \(offset), chunk \(chunkSize)")
                XCTAssertEqual(written[offset], data[offset] ^ 0xFF)
            }
        }
    }

    // MARK: - Close fault

    func testCloseFaultThrowsAfterTheDataIsWritten() throws {
        let data = FixtureTree.content(for: "x", size: 3_000, seed: 1)
        let url = tempDir.appendingPathComponent("close.bin")
        provider.closeFaults = [url: fault]
        for _ in 0..<2 {
            try? fm.removeItem(at: url)  // reset between the two identical runs; absent on the first
            let (succeeded, error) = try writeAll(data, to: url, chunkSize: 1_000)
            XCTAssertEqual(succeeded, 3, "all writes succeed")
            XCTAssertEqual(error as? InjectedFault, fault)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testWriterWithoutFaultsWritesThrough() throws {
        let data = FixtureTree.content(for: "ok", size: 10_000, seed: 1)
        let url = tempDir.appendingPathComponent("ok.bin")
        let (succeeded, error) = try writeAll(data, to: url, chunkSize: 4_096)
        XCTAssertNil(error)
        XCTAssertEqual(succeeded, 3)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(provider.writerCalls, [url])
    }

    func testWriterKeepsExclusiveCreate() throws {
        let (url, data) = try makeFile("existing.bin", size: 100)
        XCTAssertThrowsError(try provider.makeWriter(at: url)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EEXIST)
        }
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    // MARK: - Delete, move, trash faults

    func testDeleteFault() async throws {
        let (url, _) = try makeFile("keep.bin", size: 10)
        provider.deleteFaults = [url: fault]
        for _ in 0..<2 {
            do {
                try await provider.delete(url)
                XCTFail("delete must fail")
            } catch {
                XCTAssertEqual(error as? InjectedFault, fault)
            }
            XCTAssertTrue(fm.fileExists(atPath: url.path))
        }
        provider.deleteFaults = [:]
        try await provider.delete(url)
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        XCTAssertEqual(provider.deleteCalls, [url, url, url])
    }

    func testMoveFault() async throws {
        let (url, _) = try makeFile("from.bin", size: 10)
        let destination = tempDir.appendingPathComponent("to.bin")
        provider.moveFaults = [url: fault]
        do {
            try await provider.move(from: url, to: destination)
            XCTFail("move must fail")
        } catch {
            XCTAssertEqual(error as? InjectedFault, fault)
        }
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))

        provider.moveFaults = [:]
        try await provider.move(from: url, to: destination)
        XCTAssertTrue(fm.fileExists(atPath: destination.path))
        XCTAssertEqual(provider.moveCalls.count, 2)
    }

    func testTrashFaultAndFakeTrash() async throws {
        let (url, data) = try makeFile("trash-me.bin", size: 10)
        provider.trashFaults = [url: fault]
        do {
            try await provider.trash(url)
            XCTFail("trash must fail")
        } catch {
            XCTAssertEqual(error as? InjectedFault, fault)
        }
        XCTAssertTrue(fm.fileExists(atPath: url.path))

        provider.trashFaults = [:]
        let trashed = try await provider.trash(url)
        let location = try XCTUnwrap(trashed)
        XCTAssertTrue(location.isContained(in: tempDir), "the fake Trash stays inside the temp dir")
        XCTAssertEqual(try Data(contentsOf: location), data)
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }

    func testFaultsMatchStandardizedPaths() async throws {
        let (url, _) = try makeFile("std.bin", size: 10)
        let spelledDifferently = tempDir.appendingPathComponent("sub/../std.bin")
        provider.deleteFaults = [spelledDifferently: fault]
        do {
            try await provider.delete(url)
            XCTFail("delete must fail")
        } catch {
            XCTAssertEqual(error as? InjectedFault, fault)
        }
    }

    // MARK: - Pause points

    func testPauseHoldsTheReadBeforeTheRequestedChunk() async throws {
        let (url, data) = try makeFile("paused.bin", size: 10_000)
        let pause = provider.pauseRead(of: url, beforeChunk: 2)
        let reader = Task { await readAll(url, chunkSize: 1_000) }

        let reached = await pause.waitUntilReached()
        XCTAssertTrue(reached)
        XCTAssertEqual(provider.bytesDelivered(from: url), 2_000, "exactly two chunks before the pause")
        // Nothing moves while paused.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(provider.bytesDelivered(from: url), 2_000)

        pause.release()
        let (received, error) = await reader.value
        XCTAssertNil(error)
        XCTAssertEqual(received, data)
    }

    func testCancellingWhilePausedStopsTheRead() async throws {
        let (url, _) = try makeFile("cancelled.bin", size: 10_000)
        let pause = provider.pauseRead(of: url, beforeChunk: 3)
        let reader = Task { await readAll(url, chunkSize: 1_000) }

        let reached = await pause.waitUntilReached()
        XCTAssertTrue(reached)
        reader.cancel()
        pause.release()
        let (received, _) = await reader.value

        XCTAssertLessThanOrEqual(received.count, 3_000)
        XCTAssertEqual(provider.bytesDelivered(from: url), 3_000, "no chunk is read after the cancelled pause")
    }

    func testPauseReleasedBeforeArrivalDoesNotBlock() async throws {
        let (url, data) = try makeFile("prereleased.bin", size: 3_000)
        let pause = provider.pauseRead(of: url, beforeChunk: 1)
        pause.release()
        let (received, error) = await readAll(url, chunkSize: 1_000)
        XCTAssertNil(error)
        XCTAssertEqual(received, data)
        XCTAssertTrue(pause.isReached)
    }

    func testUnreachedPauseTimesOut() async throws {
        let (url, _) = try makeFile("short.bin", size: 1_000)
        let pause = provider.pauseRead(of: url, beforeChunk: 5)
        _ = await readAll(url, chunkSize: 1_000)
        let reached = await pause.waitUntilReached(timeout: 0.1)
        XCTAssertFalse(reached)
    }
}
