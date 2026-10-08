import Foundation

func testFolder(_ id: String, _ name: String, open: UInt32 = 0) -> FolderSnapshot {
    FolderSnapshot(id: id, name: name, openCount: open, noteCount: open, revision: 1)
}

func testOverview(all: UInt32, unfiled: UInt32, folders: [FolderSnapshot]) -> FolderOverview {
    FolderOverview(allOpen: all, unfiledOpen: unfiled, due: 0, done: 0, deleted: 0, folders: folders)
}
