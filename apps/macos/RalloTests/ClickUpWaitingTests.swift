import XCTest

/// Who counts as waiting in ClickUp, and where a click goes (0010).
final class ClickUpWaitingTests: XCTestCase {
    private let channels: [[String: Any]] = [
        ["id": "2kyqzpv9-21195", "type": "DM", "latest_comment_at": NSNumber(value: 1_000)],
        ["id": "2kyqzpv9-9695", "type": "GROUP_DM", "latest_comment_at": "2000"],
        ["id": "2kyqzpv9-1", "type": "CHANNEL", "name": "Daily", "latest_comment_at": 3_000],
        ["id": "bad id;", "type": "DM", "latest_comment_at": 4_000],
        ["id": "2kyqzpv9-2", "type": "DM"],
    ]

    func testOnlyDirectAndGroupMessagesWithAValidIDAndTime() {
        XCTAssertEqual(ClickUpWaiting.conversations(channels), [
            .init(id: "2kyqzpv9-21195", group: false, latestAt: 1_000),
            .init(id: "2kyqzpv9-9695", group: true, latestAt: 2_000),
        ])
    }

    func testWaitingWhileTheLatestMessageIsSomeoneElses() {
        let conversations = ClickUpWaiting.conversations(channels)
        let latest: [String: ClickUpWaiting.Latest] = [
            "2kyqzpv9-21195": .init(at: 1_000, sender: "42"),  // Muhsin wrote last
            "2kyqzpv9-9695": .init(at: 2_000, sender: "7"),    // the user replied
        ]
        let items = ClickUpWaiting.items(conversations: conversations, latest: latest, me: "7",
                                         names: ["42": "Muhsin Ahmed"], workspaceID: "90152360809", appPath: nil)
        XCTAssertEqual(items.map(\.who), ["Muhsin Ahmed"])
        XCTAssertEqual(items.first?.focus, "clickup:90152360809:2kyqzpv9-21195")
        XCTAssertEqual(items.first?.latestAtMs, 1_000)
        XCTAssertEqual(items.first?.group, false)
    }

    func testAStaleSenderLookupIsNotTrusted() {
        let conversations = ClickUpWaiting.conversations(channels)
        let latest: [String: ClickUpWaiting.Latest] = ["2kyqzpv9-21195": .init(at: 500, sender: "42")]
        XCTAssertTrue(ClickUpWaiting.items(conversations: conversations, latest: latest, me: "7", names: [:],
                                           workspaceID: "1", appPath: nil).isEmpty)
    }

    func testUnknownSenderIsSomeone() {
        let items = ClickUpWaiting.items(conversations: [.init(id: "a-1", group: false, latestAt: 1)],
                                         latest: ["a-1": .init(at: 1, sender: "99")], me: "7", names: [:],
                                         workspaceID: "1", appPath: nil)
        XCTAssertEqual(items.map(\.who), ["Someone"])
    }

    func testLinkOpensTheDesktopAppOrTheWeb() {
        let focus = "clickup:90152360809:2kyqzpv9-21195"
        XCTAssertEqual(ClickUpWaiting.link(focus: focus, desktop: true)?.absoluteString,
                       "clickup://app.clickup.com/90152360809/chat/r/2kyqzpv9-21195")
        XCTAssertEqual(ClickUpWaiting.link(focus: focus, desktop: false)?.absoluteString,
                       "https://app.clickup.com/90152360809/chat/r/2kyqzpv9-21195")
    }

    func testMalformedFocusHasNoLink() {
        for focus in [nil, "tty:/dev/ttys001", "clickup:abc:2kyqzpv9-1", "clickup:1", "clickup:1:a/../b", "clickup::x"] {
            XCTAssertNil(ClickUpWaiting.link(focus: focus, desktop: true), String(describing: focus))
        }
    }
}
