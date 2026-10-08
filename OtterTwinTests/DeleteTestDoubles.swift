import Foundation
@testable import OtterTwin

struct InjectedFault: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Provider for delete tests: performs real operations on a temp fixture tree
/// (via `LocalProvider`), with per-URL fault injection. "Trash" is simulated by
/// moving items into a test-owned folder, so nothing leaves the temp dir.
///
/// TODO(#24): replace with the fault-injecting provider from the data-safety
/// harness once it is merged.
final class FaultInjectingDeleteProvider: VFSProvider {
    private let local = LocalProvider()
    private let fakeTrash: URL

    var supportsTrash: Bool
    /// When set, the provider only manages paths inside this root (like a mounted share).
    var managedRoot: URL?
    var trashFaults: [URL: InjectedFault] = [:]
    var deleteFaults: [URL: InjectedFault] = [:]
    private(set) var trashCalls: [URL] = []
    private(set) var deleteCalls: [URL] = []

    init(fakeTrash: URL, supportsTrash: Bool = true) {
        self.fakeTrash = fakeTrash
        self.supportsTrash = supportsTrash
    }

    func trash(_ url: URL) async throws -> URL? {
        trashCalls.append(url)
        guard supportsTrash else { throw TrashNotSupportedError() }
        if let fault = trashFaults[url] { throw fault }
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let target = fakeTrash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    func delete(_ url: URL) async throws {
        deleteCalls.append(url)
        if let fault = deleteFaults[url] { throw fault }
        try await local.delete(url)
    }

    func manages(_ url: URL) -> Bool {
        guard let managedRoot else { return true }
        return url.isContained(in: managedRoot)
    }

    // Not used by the delete flow.
    func listDirectory(_ url: URL) async throws -> [FileItem] { try await local.listDirectory(url) }
    func attributes(of url: URL) async throws -> FileItem { try await local.attributes(of: url) }
    func readChunks(of url: URL, chunkSize: Int) -> AsyncThrowingStream<Data, Error> {
        local.readChunks(of: url, chunkSize: chunkSize)
    }
    func createDirectory(at url: URL) async throws { try await local.createDirectory(at: url) }
    func move(from: URL, to: URL) async throws { try await local.move(from: from, to: to) }
    func makeWriter(at url: URL) throws -> ChunkedWriter { try local.makeWriter(at: url) }
}

/// Scripted answers for the delete dialogs, recording every question asked.
@MainActor
final class ScriptedDeleteConfirmer: DeleteConfirming {
    var trashAnswer: TrashConfirmation = .cancel
    /// Answers to successive permanent-delete confirmations; missing → false.
    var permanentAnswers: [Bool] = []
    var resultAnswer = false

    private(set) var trashQuestions: [[URL]] = []
    private(set) var permanentQuestions: [(urls: [URL], reason: PermanentDeleteReason)] = []
    private(set) var shownResults: [(result: DeleteResult, offeredPermanent: Bool)] = []
    /// Whether every item still existed on disk whenever a confirmation was asked.
    private(set) var allItemsExistedWhenAsked = true

    func confirmTrash(_ urls: [URL]) async -> TrashConfirmation {
        trashQuestions.append(urls)
        noteExistence(urls)
        return trashAnswer
    }

    func confirmPermanentDelete(_ urls: [URL], reason: PermanentDeleteReason) async -> Bool {
        permanentQuestions.append((urls, reason))
        noteExistence(urls)
        return permanentAnswers.isEmpty ? false : permanentAnswers.removeFirst()
    }

    func showResult(_ result: DeleteResult, offerPermanentDelete: Bool) async -> Bool {
        shownResults.append((result, offerPermanentDelete))
        return resultAnswer
    }

    private func noteExistence(_ urls: [URL]) {
        if !urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            allItemsExistedWhenAsked = false
        }
    }
}
