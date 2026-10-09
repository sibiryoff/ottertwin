import Foundation
@testable import OtterTwin

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

/// Stand-in for `LocalProvider`'s trasher: "trashes" by moving the item into a
/// test-owned folder, so tests never touch the real `~/.Trash`.
final class TrashSpy {
    let fakeTrash: URL
    var fault: InjectedFault?
    private(set) var calls: [URL] = []

    init(fakeTrash: URL) {
        self.fakeTrash = fakeTrash
    }

    func trash(_ url: URL) throws -> URL? {
        calls.append(url)
        if let fault { throw fault }
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let target = fakeTrash.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}
