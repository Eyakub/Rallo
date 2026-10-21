import AppKit

/// Automatic backup (0024): settings, the daily check, and one backup run.
/// Plain class; the coordinator copies its state into `SettingsModel` and
/// `onChange` asks it to do that again.
@MainActor
final class BackupController {
    enum Kind: String {
        case off, icloud, folder
        case google   // part B
    }

    private enum Keys {
        static let kind = "backupKind"
        static let folder = "backupFolderPath"
        static let lastSuccess = "backupLastSuccess"
        static let lastRevision = "backupLastRevision"
        static let lastError = "backupLastError"
        static let handles = "backupHandles"
        static let handlesKey = "backupHandlesKey"
    }

    private let core: CoreClient
    private let defaults: UserDefaults
    private let log: DiagnosticsLog
    private let home: URL
    private let macName: String
    let isScratch: Bool
    private var timer: Timer?
    private(set) var isRunning = false
    var onChange: () -> Void = {}

    init(core: CoreClient, defaults: UserDefaults, log: DiagnosticsLog, isScratch: Bool,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         macName: String = Host.current().localizedName ?? "Mac") {
        self.core = core
        self.defaults = defaults
        self.log = log
        self.isScratch = isScratch
        self.home = home
        self.macName = macName
    }

    // MARK: State

    var kind: Kind { defaults.string(forKey: Keys.kind).flatMap(Kind.init(rawValue:)) ?? .off }
    var folderPath: String? { defaults.string(forKey: Keys.folder) }
    var lastSuccess: Date? { defaults.object(forKey: Keys.lastSuccess) as? Date }
    var lastRevision: Int64? { (defaults.object(forKey: Keys.lastRevision) as? NSNumber)?.int64Value }
    var lastError: String? { defaults.string(forKey: Keys.lastError) }
    private var handles: [String] { defaults.stringArray(forKey: Keys.handles) ?? [] }
    private var handlesKey: String? { defaults.string(forKey: Keys.handlesKey) }

    /// iCloud Drive is on and this isn't a scratch instance (0024 §6).
    var iCloudAvailable: Bool { !isScratch && FolderDestination.iCloudAvailable(home: home) }

    /// Where backups go now; nil when off, unavailable or not set up. Part B adds `.google` here.
    var destination: BackupDestination? {
        switch kind {
        case .off, .google: nil
        case .icloud: iCloudAvailable ? FolderDestination.iCloud(home: home) : nil
        case .folder: folderPath.map { FolderDestination(folder: URL(fileURLWithPath: $0, isDirectory: true)) }
        }
    }

    /// The folder Show in Finder opens.
    var destinationFolder: URL? { (destination as? FolderDestination)?.folder }

    func select(_ kind: Kind, folder: String? = nil) {
        if kind == .icloud, !iCloudAvailable { return }
        defaults.set(kind.rawValue, forKey: Keys.kind)
        if let folder { defaults.set(folder, forKey: Keys.folder) }
        adopt(destination?.key)
        onChange()
    }

    /// A different destination starts a new list and a fresh schedule; the old one's files stay.
    private func adopt(_ key: String?) {
        guard let key, key != handlesKey else { return }
        defaults.set(key, forKey: Keys.handlesKey)
        defaults.set([String](), forKey: Keys.handles)
        defaults.removeObject(forKey: Keys.lastSuccess)
        defaults.removeObject(forKey: Keys.lastRevision)
        defaults.removeObject(forKey: Keys.lastError)
    }

    var statusLine: String {
        if isRunning { return "Backing up…" }
        if let lastError { return "Couldn’t back up: \(lastError). Rallo tries again within the hour." }
        guard let lastSuccess else { return "No backup yet." }
        return "Last backup: \(Self.relative(lastSuccess))."
    }

    static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now) ?? now) {
            return "yesterday at \(time)"
        }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) at \(time)"
    }

    // MARK: Schedule

    /// First check about a minute after storage opens, then hourly (0024 §3).
    func start() {
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        let hourly = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        hourly.tolerance = 5 * 60
        timer = hourly
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        Task { await checkIfDue() }
    }

    func checkIfDue() async {
        guard kind != .off, !isRunning else { return }
        guard let revision = try? await core.changeRevision() else { return }
        if BackupSchedule.isDue(now: Date(), lastSuccess: lastSuccess, lastRevision: lastRevision, revision: revision) {
            await backUpNow()
        }
    }

    // MARK: Run

    /// Ignores the schedule. A second request while one runs is dropped.
    func backUpNow() async {
        guard !isRunning, kind != .off else { return }
        isRunning = true
        onChange()
        defer {
            isRunning = false
            onChange()
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            guard let destination else { throw BackupError(message: unavailableReason) }
            adopt(destination.key)
            let revision = try await core.changeRevision()
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let name = BackupNaming.fileName(mac: macName, date: Date(), timeZone: .current)
            let result = try await core.exportToFile(temp.appendingPathComponent(name).path, format: .zip, overwrite: false)
            let handle = try await destination.store(temp.appendingPathComponent(name), name: name)
            defaults.set(Date(), forKey: Keys.lastSuccess)
            defaults.set(NSNumber(value: revision), forKey: Keys.lastRevision)
            defaults.removeObject(forKey: Keys.lastError)
            defaults.set(handles + [handle], forKey: Keys.handles)
            log.record("backup_done", ["items": result.items, "kind": kind.rawValue])
            await prune(destination)
        } catch {
            let reason = (error as? BackupError)?.message ?? "\(error)"
            defaults.set(reason, forKey: Keys.lastError)
            log.record("backup_failed", ["error": reason, "kind": kind.rawValue])
        }
    }

    private var unavailableReason: String {
        switch kind {
        case .icloud: "iCloud Drive is off"
        case .folder: "no folder is chosen"
        default: "this destination isn’t available"
        }
    }

    /// Never fails the backup: a handle that can't be removed stays for next time.
    private func prune(_ destination: BackupDestination) async {
        let (kept, removed) = BackupRetention.split(handles, keep: BackupRetention.keep)
        var remaining = kept
        for handle in removed {
            do {
                try await destination.remove(handle)
            } catch {
                remaining.insert(handle, at: 0)
                log.record("backup_prune_failed", ["error": "\(error)"])
            }
        }
        defaults.set(remaining, forKey: Keys.handles)
    }
}
