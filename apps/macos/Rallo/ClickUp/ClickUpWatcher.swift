import AppKit
import Security

/// The ClickUp personal API token, in the login Keychain (0010): never in
/// the database, the logs, or a file.
enum ClickUpToken {
    static let service = "rallo-clickup-token"

    static func read() -> String? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    static func save(_ token: String) -> Bool {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecAttrLabel as String: "Rallo: ClickUp API token",
            kSecValueData as String: Data(token.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}

enum ClickUpError: Error {
    case unauthorized, rateLimited, failed(Int), malformed
}

/// GET-only ClickUp REST client. The token goes in `Authorization` as is
/// (ClickUp takes no "Bearer" prefix).
struct ClickUpAPI {
    let token: String

    /// In-memory only: no response cache, cookies, or connection records on
    /// disk, whatever ClickUp's headers say (0010).
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://api.clickup.com/api" + path)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: throw ClickUpError.unauthorized
        case 429: throw ClickUpError.rateLimited
        case let code: throw ClickUpError.failed(code)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClickUpError.malformed }
        return object
    }
}

/// Polls ClickUp once a minute while connected (0010) and hands the
/// conversations waiting on the user to the core, which stores them beside
/// agent sessions in the runtime file. A quiet minute costs one request:
/// the latest sender is fetched only for a conversation whose latest
/// message changed.
@MainActor
final class ClickUpWatcher {
    private let core: CoreClient
    private let log: DiagnosticsLog
    /// Called after a sync changed the stored rows.
    var onChange: () -> Void = {}
    /// One line for the menu: who is connected, or why it stopped.
    private(set) var status: String?

    private var api: ClickUpAPI?
    private var timer: Timer?
    private var checking = false
    private var me = ""
    private var workspaceID = ""
    private var names: [String: String] = [:]
    private var identityLoadedAt = Date.distantPast
    private var latest: [String: ClickUpWaiting.Latest] = [:]
    private var skipChecks = 0
    private var backoff = 1

    var isConnected: Bool { api != nil }

    init(core: CoreClient, log: DiagnosticsLog) {
        self.core = core
        self.log = log
    }

    /// Starts polling if a token is in the Keychain; otherwise clears any
    /// rows a previous connection left behind. The read is off the main
    /// thread: macOS may ask the user to allow it, and the call waits.
    func start() {
        Task {
            guard let token = await Task.detached(operation: { ClickUpToken.read() }).value else {
                await clearRows()
                return
            }
            begin(ClickUpAPI(token: token))
        }
    }

    /// Checks the token against ClickUp before saving it; throws if ClickUp
    /// rejects it or can't be reached. Returns who is connected, for the
    /// dialog: "eyakub in SDS Manager".
    @discardableResult
    func connect(token: String) async throws -> String {
        let api = ClickUpAPI(token: token)
        let who = try await loadIdentity(api)
        guard ClickUpToken.save(token) else { throw ClickUpError.failed(0) }
        log.record("clickup_connected")
        begin(api)
        return who
    }

    func disconnect() async {
        stopTimer()
        api = nil
        status = nil
        ClickUpToken.delete()
        log.record("clickup_disconnected")
        await clearRows()
    }

    private func begin(_ api: ClickUpAPI) {
        self.api = api
        latest = [:]
        stopTimer()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        Task { await check() }
    }

    private func check() async {
        guard let api, !checking else { return }
        if skipChecks > 0 {
            skipChecks -= 1
            return
        }
        checking = true
        defer { checking = false }
        do {
            if me.isEmpty || Date().timeIntervalSince(identityLoadedAt) > 3600 {
                try await loadIdentity(api)
            }
            let since = Int64((Date().timeIntervalSince1970 - 24 * 3600) * 1000)
            // ponytail: first 100 conversations with a message in the last
            // day; page with `next_cursor` if anyone has more.
            let page = try await api.get("/v3/workspaces/\(workspaceID)/chat/channels",
                                         ["limit": "100", "is_follower": "true", "with_message_since": "\(since)"])
            let conversations = ClickUpWaiting.conversations(page["data"] as? [[String: Any]] ?? [])
            for conversation in conversations where latest[conversation.id]?.at != conversation.latestAt {
                let messages = try await api.get("/v3/workspaces/\(workspaceID)/chat/channels/\(conversation.id)/messages",
                                                 ["limit": "1"])
                let first = (messages["data"] as? [[String: Any]])?.first
                latest[conversation.id] = .init(at: conversation.latestAt, sender: ClickUpWaiting.string(first?["user_id"]) ?? me)
            }
            let ids = Set(conversations.map(\.id))
            latest = latest.filter { ids.contains($0.key) }
            let appPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClickUpWaiting.bundleID)?.path
            let items = ClickUpWaiting.items(conversations: conversations, latest: latest, me: me, names: names,
                                             workspaceID: workspaceID, appPath: appPath)
            backoff = 1
            if try await core.syncClickupWaiting(items) { onChange() }
        } catch ClickUpError.unauthorized {
            log.record("clickup_unauthorized")
            stopTimer()
            self.api = nil
            status = "ClickUp rejected the token"
            await clearRows()
        } catch ClickUpError.rateLimited {
            skipChecks = backoff
            backoff = min(backoff * 2, 16)
            log.record("clickup_rate_limited", ["skip": "\(skipChecks)"])
        } catch {
            // Offline, asleep, or a ClickUp hiccup: the next minute retries.
            log.record("clickup_check_failed", ["error": Self.describe(error)])
        }
    }

    /// Who "me" is, the first workspace, and its member names; returns
    /// "<user> in <workspace>".
    @discardableResult
    private func loadIdentity(_ api: ClickUpAPI) async throws -> String {
        let user = try await api.get("/v2/user")["user"] as? [String: Any]
        guard let me = ClickUpWaiting.string(user?["id"]),
              let team = (try await api.get("/v2/team")["teams"] as? [[String: Any]])?.first,  // ponytail: first workspace only
              let workspaceID = ClickUpWaiting.string(team["id"])
        else { throw ClickUpError.malformed }
        var names: [String: String] = [:]
        for member in team["members"] as? [[String: Any]] ?? [] {
            guard let user = member["user"] as? [String: Any], let id = ClickUpWaiting.string(user["id"]) else { continue }
            names[id] = (user["username"] as? String) ?? (user["email"] as? String) ?? "Someone"
        }
        self.me = me
        self.workspaceID = workspaceID
        self.names = names
        identityLoadedAt = Date()
        let who = (user?["username"] as? String) ?? "you"
        let workspace = (team["name"] as? String) ?? "your workspace"
        status = "ClickUp: \(who) · \(workspace)"
        return "\(who) in \(workspace)"
    }

    /// An error code only: a URL error's description carries the request
    /// address (workspace and conversation ids), which the log never gets.
    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as URLError: "URLError \(error.code.rawValue)"
        case let error as ClickUpError: "\(error)"
        default: String(describing: type(of: error))
        }
    }

    private func clearRows() async {
        do {
            if try await core.syncClickupWaiting([]) { onChange() }
        } catch {
            log.record("clickup_clear_failed", ["error": "\(error)"])
        }
    }
}
