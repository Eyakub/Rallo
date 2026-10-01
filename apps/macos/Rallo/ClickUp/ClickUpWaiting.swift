import Foundation

/// Who is waiting on the user in ClickUp (docs/decisions/0010), worked out
/// from the chat API's JSON. ClickUp's API exposes no read state, so a direct
/// or group message counts while its latest message is someone else's; it
/// clears when the user replies. Pure, so it's unit-testable.
enum ClickUpWaiting {
    static let bundleID = "com.clickup.desktop-app"

    struct Conversation: Equatable {
        var id: String
        var group: Bool
        var latestAt: Int64
    }

    struct Latest: Equatable {
        var at: Int64
        var sender: String
    }

    /// Direct and group messages from a channel listing, with the time of
    /// their latest message; channels are left out (mentions there are a
    /// later step).
    static func conversations(_ channels: [[String: Any]]) -> [Conversation] {
        channels.compactMap { channel in
            guard let id = string(channel["id"]), isChatID(id),
                  let type = channel["type"] as? String, type == "DM" || type == "GROUP_DM",
                  let latestAt = int64(channel["latest_comment_at"])
            else { return nil }
            return Conversation(id: id, group: type == "GROUP_DM", latestAt: latestAt)
        }
    }

    /// The rows for the core: conversations whose latest message isn't the
    /// user's, named after whoever sent it.
    static func items(
        conversations: [Conversation], latest: [String: Latest], me: String, names: [String: String],
        workspaceID: String, appPath: String?
    ) -> [ExternalWaitingInput] {
        conversations.compactMap { conversation in
            guard let last = latest[conversation.id], last.at == conversation.latestAt, last.sender != me else { return nil }
            return ExternalWaitingInput(
                id: conversation.id, who: names[last.sender] ?? "Someone", group: conversation.group,
                appPath: appPath, focus: "clickup:\(workspaceID):\(conversation.id)", latestAtMs: conversation.latestAt
            )
        }
    }

    /// The conversation's address from a stored focus
    /// ("clickup:<workspace>:<chat>"): the desktop app's `clickup://` link,
    /// which loads the same page as the web address, or the web address.
    static func link(focus: String?, desktop: Bool) -> URL? {
        guard let focus, focus.hasPrefix("clickup:") else { return nil }
        let parts = focus.dropFirst("clickup:".count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }), isChatID(parts[1])
        else { return nil }
        return URL(string: "\(desktop ? "clickup" : "https")://app.clickup.com/\(parts[0])/chat/r/\(parts[1])")
    }

    /// Chat ids look like "2kyqzpv9-21195".
    static func isChatID(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// ClickUp mixes string and numeric ids (`user_id` is a string, member
    /// ids are numbers).
    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as NSNumber: value.int64Value
        case let value as String: Int64(value)
        default: nil
        }
    }
}
