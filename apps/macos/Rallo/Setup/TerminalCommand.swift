import Foundation

/// Puts the bundled CLI on the user's PATH as a symlink (spec §10, "Terminal
/// command setup"). Only `~/.local/bin` or `~/bin` are used, never another
/// tool's directory, and an existing `rallo` that is not Rallo's own link is
/// never replaced.
enum TerminalCommand {
    enum State: Equatable {
        /// `link` already points at this app's CLI.
        case enabled(link: URL, onPath: Bool)
        /// Nothing there yet; `onPath` says whether `directory` is on PATH.
        case available(directory: URL, onPath: Bool)
        /// Rallo's link from a moved or deleted copy of the app.
        case repairable(link: URL, oldTarget: String, onPath: Bool)
        /// Some other `rallo` exists; leave it alone.
        case conflict(existing: URL)
        /// Running from a disk image or build folder, not an installation.
        case notInstalled
    }

    static let name = "rallo"

    static func cliURL(in appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/Helpers/rallo")
    }

    static func isInstalled(_ appURL: URL, home: URL) -> Bool {
        let parent = appURL.deletingLastPathComponent().standardizedFileURL.path
        return parent == "/Applications" || parent == home.appendingPathComponent("Applications").standardizedFileURL.path
    }

    /// Preferred link directories, in order.
    static func candidates(home: URL) -> [URL] {
        [home.appendingPathComponent(".local/bin"), home.appendingPathComponent("bin")]
    }

    static func inspect(appURL: URL, home: URL, pathDirectories: [String], fileManager: FileManager = .default) -> State {
        guard isInstalled(appURL, home: home) else { return .notInstalled }
        let target = cliURL(in: appURL).standardizedFileURL.path
        let onPath = Set(pathDirectories.map { URL(fileURLWithPath: $0).standardizedFileURL.path })

        // A `rallo` earlier on PATH that isn't ours would shadow any link we add.
        for directory in pathDirectories {
            let existing = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard fileManager.fileExists(atPath: existing.path) || isSymlink(existing) else { continue }
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: existing.path),
               isRalloCLI(destination) {
                break
            }
            return .conflict(existing: existing)
        }

        let candidates = candidates(home: home)
        let directory = candidates.first { onPath.contains($0.standardizedFileURL.path) } ?? candidates[0]
        let link = directory.appendingPathComponent(name)
        let linkOnPath = onPath.contains(directory.standardizedFileURL.path)
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
            if destination == target { return .enabled(link: link, onPath: linkOnPath) }
            if isRalloCLI(destination) {
                return .repairable(link: link, oldTarget: destination, onPath: linkOnPath)
            }
            return .conflict(existing: link)
        }
        if fileManager.fileExists(atPath: link.path) { return .conflict(existing: link) }
        return .available(directory: directory, onPath: linkOnPath)
    }

    /// Creates (or, for `repairable`, replaces Rallo's own) link and checks
    /// that it resolves to an executable CLI.
    static func enable(_ state: State, appURL: URL, fileManager: FileManager = .default) throws -> URL {
        let target = cliURL(in: appURL)
        guard fileManager.isExecutableFile(atPath: target.path) else { throw SetupError.cliMissing(target.path) }
        let link: URL
        switch state {
        case let .available(directory, _):
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
            link = directory.appendingPathComponent(name)
        case let .repairable(existing, _, _):
            link = existing
            try fileManager.removeItem(at: link)
        case let .enabled(existing, _):
            return existing
        case .conflict, .notInstalled:
            throw SetupError.notAllowed
        }
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        guard fileManager.isExecutableFile(atPath: link.path) else { throw SetupError.cliMissing(link.path) }
        return link
    }

    /// The user's PATH as their interactive login shell sets it (a GUI app
    /// inherits only launchd's minimal PATH). `nil` if the shell does not
    /// answer within the timeout.
    ///
    /// Drains the pipe with a `readabilityHandler` while the shell runs,
    /// rather than waiting for it to exit first: an interactive login shell
    /// can print far more than the pipe's kernel buffer holds (theme/prompt
    /// banners, `nvm`/`pyenv`/`direnv` hooks, etc.), and reading only after
    /// termination risks the classic `Process`/`Pipe` deadlock where the
    /// child blocks forever writing to a pipe nobody is emptying.
    static func loginShellPath(interactive: Bool = true, timeout: TimeInterval = 3) -> [String]? {
        let shell = userShell
        let marker = "__RALLO_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [interactive ? "-ilc" : "-lc", "printf '\\n\(marker)%s\\n' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var collected = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            collected.append(chunk)
            lock.unlock()
        }
        defer { output.fileHandleForReading.readabilityHandler = nil }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        lock.lock()
        let text = String(decoding: collected, as: UTF8.self)
        lock.unlock()
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else { return nil }
        return line.dropFirst(marker.count).split(separator: ":").map(String.init)
    }

    static var userShell: String {
        let shell = String(cString: getpwuid(getuid()).pointee.pw_shell)
        return shell.isEmpty ? "/bin/zsh" : shell
    }

    /// The startup file a login shell reads even when it isn't interactive
    /// (tools such as some agents and IDE tasks run `zsh -lc`, skipping
    /// ~/.zshrc).
    static var loginProfile: String {
        switch URL(fileURLWithPath: userShell).lastPathComponent {
        case "bash": "~/.bash_profile"
        case "zsh": "~/.zprofile"
        default: "~/.profile"
        }
    }

    private static func isRalloCLI(_ path: String) -> Bool {
        path.hasSuffix("/Rallo.app/Contents/Helpers/rallo")
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    enum SetupError: LocalizedError {
        case cliMissing(String)
        case notAllowed

        var errorDescription: String? {
            switch self {
            case let .cliMissing(path): "The command-line tool is missing or not executable at \(path)."
            case .notAllowed: "Rallo won’t replace an existing command."
            }
        }
    }
}
