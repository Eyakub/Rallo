import AppKit

/// Developer diagnostic describing Rallo's own windows, so window behaviour
/// can be verified without Screen Recording permission. Contains no note text.
enum WindowReport {
    @MainActor
    static func make(pet: PetController, notesWindow: NSWindow?) -> [String: Any] {
        func describe(_ window: NSWindow) -> [String: Any] {
            [
                "title": window.title,
                "frame": NSStringFromRect(window.frame),
                "level": window.level.rawValue,
                "collection_behavior": window.collectionBehavior.rawValue,
                "is_visible": window.isVisible,
                "is_key": window.isKeyWindow,
                "is_on_active_space": window.isOnActiveSpace,
                "occlusion_visible": window.occlusionState.contains(.visible),
                "screen": window.screen?.localizedName ?? NSNull(),
                "can_become_key": window.canBecomeKey,
                "window_number": window.windowNumber,
            ]
        }
        var report: [String: Any] = [
            "at_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "app_is_active": NSApp.isActive,
            "activation_policy": NSApp.activationPolicy().rawValue,
            "frontmost_app": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull(),
            "screens": NSScreen.screens.map { ["name": $0.localizedName, "frame": NSStringFromRect($0.frame),
                                               "visible_frame": NSStringFromRect($0.visibleFrame)] },
            "pet": describe(pet.window),
        ]
        if let notesWindow { report["notes"] = describe(notesWindow) }
        return report
    }
}
