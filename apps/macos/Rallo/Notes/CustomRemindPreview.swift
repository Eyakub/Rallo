import Foundation

/// "Remind Me → Custom…" (0016): the Rust core resolves the typed time live,
/// with the same rules as `rallo remind --at`.
struct CustomRemindPreview: Equatable {
    static let examples = "e.g. fri 5pm, tomorrow 9am, in 2h"

    /// The resolved deadline; nil while the text isn't a time.
    let date: Date?
    /// "→ Fri 9 Oct at 17:00", the core's hint, or the examples.
    let message: String

    init(text: String, now: Date = .now) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            date = nil
            message = Self.examples
            return
        }
        do {
            let ms = try resolveReminderTime(text: trimmed, nowMs: Int64(now.timeIntervalSince1970 * 1000))
            let resolved = Date(timeIntervalSince1970: Double(ms) / 1000)
            date = resolved
            message = "→ " + ReminderLabel.text(for: resolved)
        } catch let error as RalloError {
            date = nil
            message = error.displayMessage
        } catch {
            date = nil
            message = Self.examples
        }
    }
}
