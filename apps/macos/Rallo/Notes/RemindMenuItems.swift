import SwiftUI

/// The Remind Me choices (0016), shared by the panel's rows and the notes
/// window: 20 minutes, 1 hour, tomorrow at 9:00, then Custom….
struct RemindMenuItems: View {
    let onPreset: (RemindPreset) -> Void
    let onCustom: () -> Void

    var body: some View {
        ForEach(RemindPreset.allCases) { preset in
            Button(preset.title) { onPreset(preset) }
        }
        Divider()
        Button("Custom…", action: onCustom)
    }
}
