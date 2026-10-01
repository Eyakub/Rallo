import Foundation

/// The CLI inside the app bundle (Contents/Helpers/rallo).
enum EmbeddedCLI {
    static let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rallo")

    /// Runs it off the main thread and returns its stdout. `doctor` exits 1
    /// on a problem yet still prints its report, so the exit status is
    /// ignored.
    static func run(_ arguments: [String]) async -> Data {
        await Task.detached {
            let process = Process()
            process.executableURL = url
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return Data() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
    }
}
