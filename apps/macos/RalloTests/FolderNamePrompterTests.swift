import XCTest

/// 0019 §10: the in-panel name dialog keeps asking until the core accepts,
/// shows the core's own message, and always resumes its caller exactly once.
@MainActor
final class FolderNamePrompterTests: XCTestCase {
    private func ask(_ prompter: FolderNamePrompter, validate: @escaping (String) async throws -> Void = { _ in }) -> Task<String?, Never> {
        let task = Task { await prompter.ask(title: "New Folder", initial: "", confirmTitle: "Create", validate: validate) }
        return task
    }

    private func waitForRequest(_ prompter: FolderNamePrompter) async {
        while prompter.request == nil { await Task.yield() }
    }

    func testAThrowingValidateShowsTheCoreMessageAndKeepsAsking() async {
        let prompter = FolderNamePrompter()
        let asked = ask(prompter) { _ in throw RalloError.InvalidInput(code: "FOLDER_NAME", message: "That name is taken.") }
        await waitForRequest(prompter)
        await prompter.submit("Work")
        XCTAssertEqual(prompter.error, "That name is taken.")
        XCTAssertNotNil(prompter.request)
        XCTAssertFalse(prompter.isSaving)
        prompter.cancel()
        let result = await asked.value
        XCTAssertNil(result)
    }

    func testASucceedingValidateReturnsTheNameAndClosesTheDialog() async {
        let prompter = FolderNamePrompter()
        let asked = ask(prompter)
        await waitForRequest(prompter)
        await prompter.submit("Errands")
        let result = await asked.value
        XCTAssertEqual(result, "Errands")
        XCTAssertNil(prompter.request)
        XCTAssertNil(prompter.error)
    }

    func testCancelReturnsNil() async {
        let prompter = FolderNamePrompter()
        let asked = ask(prompter)
        await waitForRequest(prompter)
        prompter.cancel()
        let result = await asked.value
        XCTAssertNil(result)
        XCTAssertNil(prompter.request)
    }

    func testASecondAskCancelsTheFirst() async {
        let prompter = FolderNamePrompter()
        let first = ask(prompter)
        await waitForRequest(prompter)
        let firstID = prompter.request?.id
        let second = ask(prompter)
        let firstResult = await first.value
        XCTAssertNil(firstResult)
        while prompter.request?.id == firstID { await Task.yield() }
        await prompter.submit("Second")
        let secondResult = await second.value
        XCTAssertEqual(secondResult, "Second")
    }

    func testCancelIsIgnoredWhileSaving() async {
        let prompter = FolderNamePrompter()
        var release: CheckedContinuation<Void, Never>?
        let asked = ask(prompter) { _ in await withCheckedContinuation { release = $0 } }
        await waitForRequest(prompter)
        let submitting = Task { await prompter.submit("Slow") }
        while release == nil { await Task.yield() }
        XCTAssertTrue(prompter.isSaving)
        prompter.cancel()
        XCTAssertNotNil(prompter.request, "cancel must wait for the save")
        release?.resume()
        await submitting.value
        let result = await asked.value
        XCTAssertEqual(result, "Slow")
    }
}
