import XCTest

/// 0019 §10: the panel's scope survives reloads, falls back when its folder is
/// gone, and gives way when a notification points at a note it doesn't show.
@MainActor
final class NotesViewModelScopeTests: XCTestCase {
    private var dataDir: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var core: CoreClient!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-scope-\(UUID().uuidString)")
        suite = "com.razlio.rallo.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        core = CoreClient(dataDir: dataDir.path)
        try await core.open()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        // removePersistentDomain leaves this suite's plist behind.
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist"))
        try? FileManager.default.removeItem(at: dataDir)
    }

    func testAVanishedFolderFallsBackToAllNotesAndIsForgotten() async throws {
        let errands = try await core.createFolder("Errands")
        _ = try await core.createNote("Kept", images: [])
        NotesScope.folder(errands.id).save(to: defaults)
        let model = NotesViewModel(core: core, defaults: defaults)
        XCTAssertEqual(model.scope, .folder(errands.id))

        _ = try await core.deleteFolder(errands.id, keepNotes: true)
        await model.reload()

        XCTAssertEqual(model.scope, .all)
        XCTAssertEqual(defaults.string(forKey: NotesScope.defaultsKey), "all")
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.scopeCountLine, "1 open note")
    }

    func testRevealSwitchesToAllNotesWhenTheNoteIsInAnotherFolder() async throws {
        let a = try await core.createFolder("A")
        let b = try await core.createFolder("B")
        let note = try await core.createNote("In A", images: [], folderID: a.id)
        let model = NotesViewModel(core: core, defaults: defaults)
        await model.setScope(.folder(b.id))
        XCTAssertTrue(model.items.isEmpty)

        await model.reveal(note.id)

        XCTAssertEqual(model.scope, .all)
        XCTAssertEqual(defaults.string(forKey: NotesScope.defaultsKey), "all")
        XCTAssertEqual(model.items.map(\.id), [note.id])
        XCTAssertEqual(model.highlightedItemID, note.id)
    }

    func testRevealKeepsTheScopeWhenItHoldsTheNote() async throws {
        let b = try await core.createFolder("B")
        let note = try await core.createNote("In B", images: [], folderID: b.id)
        let model = NotesViewModel(core: core, defaults: defaults)
        await model.setScope(.folder(b.id))

        await model.reveal(note.id)

        XCTAssertEqual(model.scope, .folder(b.id))
        XCTAssertEqual(defaults.string(forKey: NotesScope.defaultsKey), b.id)
    }
}
