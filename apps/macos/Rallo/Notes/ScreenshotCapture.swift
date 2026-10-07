import AppKit
import CoreGraphics

/// ⌃⌥⌘S (0018): macOS's own region selection (`screencapture -i`) into a
/// temp file, read and deleted at once. Escape during the selection
/// cancels and nothing happens.
@MainActor
enum ScreenshotCapture {
    enum Outcome: Equatable {
        case captured(Data)
        case cancelled
        case needsPermission

        /// For the diagnostics log; never the image.
        var name: String {
            switch self {
            case .captured: "captured"
            case .cancelled: "cancelled"
            case .needsPermission: "needs_permission"
            }
        }
    }

    static let permissionMessage = "Rallo needs Screen Recording access to take a screenshot. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then press ⌃⌥⌘S again."

    static func capture() async -> Outcome {
        guard CGPreflightScreenCaptureAccess() else {
            // Shows macOS's prompt the first time; later calls do nothing.
            CGRequestScreenCaptureAccess()
            return .needsPermission
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-screenshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await run("/usr/sbin/screencapture", ["-i", "-x", url.path])
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return .cancelled }
        return .captured(data)
    }

    private static func run(_ path: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }
}
