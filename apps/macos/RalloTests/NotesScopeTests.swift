import XCTest

/// 0019 §10: which notes the panel shows, how that is remembered, and the text
/// the chip and the note field derive from it.
final class NotesScopeTests: XCTestCase {
    private let work = testFolder("w-1", "Work", open: 5)
    private let bangla = testFolder("b-2", "কাজ 🦊", open: 1)

    func testStoredValueRoundTrips() {
        for scope in [NotesScope.all, .unfiled, .folder("3F2A9C10-7B1E-4D55-9C0A-0123456789AB")] {
            XCTAssertEqual(NotesScope(stored: scope.stored), scope)
        }
        XCTAssertEqual(NotesScope.all.stored, "all")
        XCTAssertEqual(NotesScope.unfiled.stored, "unfiled")
        XCTAssertEqual(NotesScope.folder("w-1").stored, "w-1")
        XCTAssertEqual(NotesScope(stored: nil), .all, "nothing saved yet is All Notes")
        XCTAssertEqual(NotesScope(stored: ""), .all)
    }

    func testSavesUnderNotesPanelScopeInUserDefaults() throws {
        let suite = "rallo-tests-scope-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(NotesScope.load(from: defaults), .all)
        NotesScope.folder("w-1").save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: "notesPanelScope"), "w-1")
        XCTAssertEqual(NotesScope.load(from: defaults), .folder("w-1"))
        NotesScope.unfiled.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: "notesPanelScope"), "unfiled")
    }

    func testDeletedFolderFallsBackToAll() {
        XCTAssertEqual(NotesScope.folder("gone").resolved(in: [work]), .all)
        XCTAssertEqual(NotesScope.folder("gone").resolved(in: []), .all)
        XCTAssertEqual(NotesScope.folder("w-1").resolved(in: [work]), .folder("w-1"))
        XCTAssertEqual(NotesScope.unfiled.resolved(in: []), .unfiled)
        XCTAssertEqual(NotesScope.all.resolved(in: []), .all)
    }

    func testChipTitle() {
        XCTAssertEqual(NotesScope.all.title(in: [work]), "All Notes")
        XCTAssertEqual(NotesScope.unfiled.title(in: [work]), "Notes")
        XCTAssertEqual(NotesScope.folder("w-1").title(in: [work]), "Work")
        XCTAssertEqual(NotesScope.folder("b-2").title(in: [work, bangla]), "কাজ 🦊")
        XCTAssertEqual(NotesScope.folder("gone").title(in: [work]), "All Notes", "a vanished folder reads as its fallback")
    }

    func testNoteFieldPlaceholder() {
        XCTAssertEqual(NotesScope.all.placeholder(in: [work], hasNotes: false), "What’s on your mind?")
        XCTAssertEqual(NotesScope.all.placeholder(in: [work], hasNotes: true), "Something else on your mind?")
        XCTAssertEqual(NotesScope.unfiled.placeholder(in: [work], hasNotes: true), "Add to Notes…")
        XCTAssertEqual(NotesScope.folder("w-1").placeholder(in: [work], hasNotes: false), "Add to Work…")
        XCTAssertEqual(NotesScope.folder("gone").placeholder(in: [work], hasNotes: true), "Something else on your mind?")

        let long = testFolder("l", String(repeating: "x", count: 50))
        XCTAssertEqual(NotesScope.folder("l").placeholder(in: [long], hasNotes: false), "Add to " + String(repeating: "x", count: 23) + "…")
        let family = "👨‍👩‍👧"
        let zwj = testFolder("z", String(repeating: "a", count: 22) + family + "zzz")
        XCTAssertEqual(NotesScope.folder("z").placeholder(in: [zwj], hasNotes: false), "Add to " + String(repeating: "a", count: 22) + family + "…")
        let exact = testFolder("e", String(repeating: "y", count: 24))
        XCTAssertEqual(NotesScope.folder("e").placeholder(in: [exact], hasNotes: false), "Add to " + String(repeating: "y", count: 24) + "…")
        let bangla = testFolder("b", "কাজ 🦊👨‍👩‍👧")
        XCTAssertEqual(NotesScope.folder("b").placeholder(in: [bangla], hasNotes: false), "Add to কাজ 🦊👨‍👩‍👧…")
    }

    func testCountLine() {
        XCTAssertEqual(NotesScope.countLine(open: 0), "No open notes")
        XCTAssertEqual(NotesScope.countLine(open: 1), "1 open note")
        XCTAssertEqual(NotesScope.countLine(open: 24), "24 open notes")
    }

    func testOpenCountComesFromTheOverview() {
        let overview = testOverview(all: 60, unfiled: 7, folders: [work])
        XCTAssertEqual(NotesScope.all.openCount(in: overview), 60, "past the list's 50-note limit")
        XCTAssertEqual(NotesScope.unfiled.openCount(in: overview), 7)
        XCTAssertEqual(NotesScope.folder("w-1").openCount(in: overview), 5)
        XCTAssertEqual(NotesScope.folder("gone").openCount(in: overview), 0)
    }

    func testNewNotesGoToTheFolderOnlyInAFolderScope() {
        XCTAssertNil(NotesScope.all.newNoteFolderID)
        XCTAssertNil(NotesScope.unfiled.newNoteFolderID)
        XCTAssertEqual(NotesScope.folder("w-1").newNoteFolderID, "w-1")
    }

    func testMapsToTheCoreScope() {
        XCTAssertEqual(NotesScope.all.folderScope, FolderScope.all)
        XCTAssertEqual(NotesScope.unfiled.folderScope, FolderScope.unfiled)
        XCTAssertEqual(NotesScope.folder("w-1").folderScope, FolderScope.folder(id: "w-1"))
    }
}
