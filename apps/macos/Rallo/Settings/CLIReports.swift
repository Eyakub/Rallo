import Foundation

/// Reads the embedded CLI's `--json` output for the Settings window
/// (docs/cli-contract.md). Pure parsing, so it is unit-tested without
/// running the CLI.
enum CLIReports {
    struct Check: Equatable {
        let status: String
        let summary: String
    }

    enum SetupOutcome: Equatable {
        case done(String)
        case failed(String)
    }

    enum UpdateOutcome: Equatable {
        case upToDate(current: String)
        case available(current: String, latest: String)
        case failed(String)
    }

    /// `rallo doctor --json` → each check's status and summary by `id`.
    static func doctorChecks(_ data: Data) -> [String: Check] {
        guard let checks = object(data)?["checks"] as? [[String: Any]] else { return [:] }
        var result: [String: Check] = [:]
        for check in checks {
            if let id = check["id"] as? String, let status = check["status"] as? String,
               let summary = check["summary"] as? String {
                result[id] = Check(status: status, summary: summary)
            }
        }
        return result
    }

    /// `rallo setup hooks --json`: "Claude Code: installed. Codex: already installed."
    static func hooksOutcome(_ data: Data) -> SetupOutcome {
        setupOutcome(data, path: ["hooks", "targets"])
    }

    /// `rallo setup skill --json`, same line per targeted agent.
    static func skillOutcome(_ data: Data) -> SetupOutcome {
        setupOutcome(data, path: ["skill", "installs"])
    }

    /// `rallo update --check --json`.
    static func updateOutcome(_ data: Data) -> UpdateOutcome {
        guard let json = object(data) else { return .failed("Rallo couldn’t read the update check.") }
        if let message = errorMessage(json) { return .failed(message) }
        guard let current = json["current"] as? String, let latest = json["latest"] as? String else {
            return .failed("Rallo couldn’t read the update check.")
        }
        return json["update_available"] as? Bool == true
            ? .available(current: current, latest: latest)
            : .upToDate(current: current)
    }

    /// Numeric major.minor.patch comparison; a leading "v" is ignored and
    /// anything unparsable is "not newer".
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int]? {
            let numbers = version.drop { $0 == "v" || $0 == "V" }.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard numbers.count == 3, numbers.allSatisfy({ $0 != nil }) else { return nil }
            return numbers.compactMap { $0 }
        }
        guard let new = parts(latest), let old = parts(current) else { return false }
        return new.lexicographicallyPrecedes(old) == false && new != old
    }

    private static func setupOutcome(_ data: Data, path: [String]) -> SetupOutcome {
        guard let json = object(data) else { return .failed("Rallo couldn’t read the result.") }
        if let message = errorMessage(json) { return .failed(message) }
        guard let section = json[path[0]] as? [String: Any], let entries = section[path[1]] as? [[String: Any]] else {
            return .failed("Rallo couldn’t read the result.")
        }
        let lines = entries.compactMap { entry -> String? in
            guard let agent = entry["agent"] as? String, let status = entry["status"] as? String else { return nil }
            let name = agent == "claude" ? "Claude Code" : agent == "codex" ? "Codex" : agent == "grok" ? "Grok" : agent == "gemini" ? "Gemini CLI" : agent
            return "\(name): \(status.replacingOccurrences(of: "_", with: " "))."
        }
        return .done(lines.isEmpty ? "Done." : lines.joined(separator: " "))
    }

    private static func errorMessage(_ json: [String: Any]) -> String? {
        guard json["ok"] as? Bool == false else { return nil }
        return (json["error"] as? [String: Any])?["message"] as? String ?? "The command failed."
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
