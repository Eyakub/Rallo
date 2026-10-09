import XCTest

/// The editor session against a real temp store; `other` is a second handle,
/// standing in for the CLI or an agent.
@MainActor
final class NoteEditorSessionTests: XCTestCase {
    private var dataDir: URL!
    private var core: CoreClient!
    private var other: RalloStore!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-editor-\(UUID().uuidString)")
        core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        other = try RalloStore.open(dataDir: dataDir.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func session(delay: TimeInterval = 0.05) -> NoteEditorSession {
        NoteEditorSession(core: core, saveDelay: delay)
    }

    private func stored(_ id: String) throws -> ItemSnapshot {
        try XCTUnwrap(other.listOpenItems(limit: 50).first { $0.id == id })
    }

    /// Only for checks that something did NOT happen; to wait for a save, use `settle`.
    private func pause(_ seconds: Double = 0.3) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits for the debounced save to land (at most 2 s) instead of sleeping a fixed time.
    private func settle(_ session: NoteEditorSession) async {
        let deadline = Date().addingTimeInterval(2)
        while session.hasUnsavedText, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await session.flush()  // a save that is still running finishes
    }

    func testTypingSavesAfterTheDelay() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        session.textChanged("v2")
        XCTAssertEqual(try stored(note.id).text, "v1", "not yet")
        await settle(session)
        XCTAssertEqual(try stored(note.id).text, "v2")
        XCTAssertFalse(session.hasUnsavedText)
        XCTAssertEqual(session.note?.revision, 2, "the session keeps the saved revision")
    }

    func testFlushSavesRightAway() async throws {
        let note = try await core.createNote("v1")
        let session = session(delay: 60)
        session.show(.note(note))
        session.textChanged("v2")
        await session.flush()
        XCTAssertEqual(try stored(note.id).text, "v2")
    }

    /// Review focus 2.
    func testAnEmptiedNoteIsNeverSavedAndComesBack() async throws {
        let note = try await core.createNote("Keep me")
        let session = session(delay: 60)
        session.show(.note(note))
        session.textChanged("   \n ")
        await session.flush()
        XCTAssertEqual(try stored(note.id).text, "Keep me")
        let message = await session.leave()
        XCTAssertNil(message, "restoring an emptied note is silent")
        XCTAssertEqual(session.text, "Keep me")
        XCTAssertFalse(session.hasUnsavedText)
    }

    /// Review focus 3.
    func testAChangeSomewhereElseShowsTheConflictBar() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.textChanged("mine")
        await session.flush()
        XCTAssertTrue(session.conflict)
        XCTAssertEqual(session.text, "mine", "the typing stays in the editor")
        XCTAssertEqual(try stored(note.id).text, "theirs")
        await pause()
        XCTAssertEqual(try stored(note.id).text, "theirs", "nothing saves behind the bar")
    }

    func testKeepMineSavesOnTheNewRevision() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.textChanged("mine")
        await session.flush()
        session.keepMine(try stored(note.id))
        await settle(session)
        XCTAssertFalse(session.conflict)
        XCTAssertEqual(try stored(note.id).text, "mine")
    }

    func testShowTheirsTakesTheLatestText() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.textChanged("mine")
        await session.flush()
        session.showTheirs(try stored(note.id))
        XCTAssertFalse(session.conflict)
        XCTAssertEqual(session.text, "theirs")
        XCTAssertFalse(session.hasUnsavedText)
    }

    func testLeavingWithAnUnansweredConflictSaysSo() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.textChanged("mine")
        await session.flush()
        let message = await session.leave()
        XCTAssertEqual(message, "Your last changes to “v1” weren’t saved.")
    }

    func testATextTooLongIsShownInlineAndKept() async throws {
        let note = try await core.createNote("v1")
        let session = session(delay: 60)
        session.show(.note(note))
        let tooLong = String(repeating: "a", count: 70_000)  // the core's limit is 64 KiB
        session.textChanged(tooLong)
        await session.flush()
        XCTAssertNotNil(session.error)
        XCTAssertFalse(session.conflict)
        XCTAssertEqual(session.text, tooLong)
        XCTAssertEqual(try stored(note.id).text, "v1")
        session.textChanged("short")
        XCTAssertNil(session.error, "typing clears the message")
    }

    /// Review focus 3.
    func testAReloadNeverOverwritesTyping() async throws {
        let note = try await core.createNote("v1")
        let session = session(delay: 60)
        session.show(.note(note))
        session.textChanged("typing")
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.sync(try stored(note.id))
        XCTAssertEqual(session.text, "typing")
        XCTAssertEqual(session.note?.revision, 1, "it still saves on the revision it started from")
    }

    func testAReloadUpdatesAnIdleEditor() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.sync(try stored(note.id))
        XCTAssertEqual(session.text, "theirs")
        XCTAssertEqual(session.note?.revision, 2)
    }

    /// Review focus 1.
    func testMarkedTextDelaysTheSave() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        session.isComposing = true
        session.textChanged("v2 にほ")
        await pause()
        XCTAssertEqual(try stored(note.id).text, "v1", "never save a half-composed word")
        session.isComposing = false
        session.textChanged("v2 日本")
        await settle(session)
        XCTAssertEqual(try stored(note.id).text, "v2 日本")
    }

    func testADraftIsCreatedByTheFirstNonEmptySaveInItsFolder() async throws {
        let work = try await core.createFolder("Work")
        let session = session()
        var created: [ItemSnapshot] = []
        session.onCreated = { created.append($0) }
        session.show(.draft(folderID: work.id, seed: ""), focus: true)
        XCTAssertTrue(session.isDraft)
        session.textChanged("  ")
        await session.flush()
        XCTAssertTrue(try other.listOpenItems(limit: 50).isEmpty, "a blank draft is discarded, not saved")
        session.textChanged("Hello #bug")
        await session.flush()
        let all = try other.listOpenItems(limit: 50)
        XCTAssertEqual(all.map(\.text), ["Hello #bug"])
        XCTAssertEqual(all.first?.folderId, work.id)
        XCTAssertEqual(created.map(\.id), all.map(\.id))
        XCTAssertEqual(session.note?.id, all.first?.id, "the session now edits the created note")
        session.textChanged("Hello #bug again")
        await session.flush()
        XCTAssertEqual(try other.listOpenItems(limit: 50).map(\.text), ["Hello #bug again"], "later saves edit, not create")
    }

    func testADraftThatStillReadsAsItsSeedIsEmpty() async throws {
        let session = session()
        session.show(.draft(folderID: nil, seed: "#bug "))
        XCTAssertEqual(session.text, "#bug ")
        session.textChanged("#bug ")
        await session.flush()
        XCTAssertTrue(try other.listOpenItems(limit: 50).isEmpty)
        let message = await session.leave()
        XCTAssertNil(message)
    }

    func testAnUnsavedDraftSurvivesLeavingByBeingSaved() async throws {
        let session = session(delay: 60)
        session.show(.draft(folderID: nil, seed: ""))
        session.textChanged("Write this down")
        await session.leave()
        XCTAssertEqual(try other.listOpenItems(limit: 50).map(\.text), ["Write this down"])
    }

    func testADeletedNoteIsReadOnly() async throws {
        let note = try await core.createNote("gone")
        let deleted = try await core.deleteItem(note)
        let session = session()
        session.show(.note(deleted))
        XCTAssertFalse(session.isEditable)
        session.show(.note(note))
        XCTAssertTrue(session.isEditable)
    }
}
