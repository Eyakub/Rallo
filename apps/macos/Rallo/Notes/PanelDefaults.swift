import Foundation

/// Which `UserDefaults` the notes panel's folder choice lives in (0019 §10).
/// Only the real data directory may use the app's own domain; any other one
/// (`--data-dir`, `RALLO_DATA_DIR`) gets a scratch suite so a test run never
/// writes `com.razlio.rallo`.
enum PanelDefaults {
    static let scratchSuite = "com.razlio.rallo.scratch"

    /// Mirrors `default_data_dir()` in crates/rallo-core/src/storage/paths.rs.
    static func realDataDir(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Razlio/Rallo", isDirectory: true)
    }

    static func isRealDataDir(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        return canonical(URL(fileURLWithPath: path)) == canonical(realDataDir(home: home))
    }

    static func suiteName(forDataDir path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        isRealDataDir(path, home: home) ? nil : scratchSuite
    }

    static func defaults(forDataDir path: String) -> UserDefaults {
        suiteName(forDataDir: path).flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
}
