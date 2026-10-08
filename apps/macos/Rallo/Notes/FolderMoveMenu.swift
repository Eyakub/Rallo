import SwiftUI

/// A menu row with a native checkmark when `checked`.
struct MenuChoice: View {
    let title: String
    let checked: Bool
    let action: () -> Void

    var body: some View {
        Toggle(title, isOn: Binding(get: { checked }, set: { _ in action() }))
    }
}
