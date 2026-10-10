/// Who owns the pet panel while a summon borrows it (0021 §3, §8, §11):
/// its saved placement and the user's Show/Hide choice stay the user's.
struct PetSummonState: Equatable {
    enum End: Equatable {
        case returnHome
        case hide
    }

    private(set) var isActive = false
    /// The user's own choice, which a summon never changes.
    private(set) var userWantsVisible = false

    mutating func begin(panelVisible: Bool) {
        guard !isActive else { return }
        isActive = true
        userWantsVisible = panelVisible
    }

    /// Show/Hide Pet during a summon: remembered, applied at the end.
    mutating func userSetVisible(_ visible: Bool) {
        userWantsVisible = visible
    }

    /// A drag that ends mid-summon is not a placement.
    var savesDrag: Bool { !isActive }
    /// Core reloads and screen changes don't move a summoned pet.
    var followsPlacement: Bool { !isActive }

    mutating func end() -> End? {
        guard isActive else { return nil }
        isActive = false
        return userWantsVisible ? .returnHome : .hide
    }

    /// What the menu, Settings and `togglePet` call "visible".
    func isVisible(panelVisible: Bool) -> Bool {
        isActive ? userWantsVisible : panelVisible
    }
}
