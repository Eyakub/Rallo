import Foundation

/// Typed façade over the Rust core used by UI code. Domain rules and SQL
/// live in Rust; this layer only moves calls onto the worker.
final class CoreClient {
    let dataDir: String
    private let worker = CoreWorker()

    init(dataDir: String) {
        self.dataDir = dataDir
    }

    func open() async throws {
        try await worker.open(dataDir: dataDir)
    }

    func changeRevision() async throws -> Int64 {
        try await worker.perform { try $0.changeRevision() }
    }

    func createNote(_ text: String) async throws -> ItemSnapshot {
        try await worker.perform { try $0.createNote(text: text) }
    }

    func completeItem(_ item: ItemSnapshot) async throws -> ItemSnapshot {
        try await worker.perform { try $0.completeItem(id: item.id, ifRevision: item.revision) }
    }

    func editItemText(_ item: ItemSnapshot, text: String) async throws -> ItemSnapshot {
        try await worker.perform { try $0.editItemText(id: item.id, text: text, ifRevision: item.revision) }
    }

    func reopenItem(_ item: ItemSnapshot) async throws -> ItemSnapshot {
        try await worker.perform { try $0.reopenItem(id: item.id, ifRevision: item.revision) }
    }

    func openItems(limit: UInt32 = 50) async throws -> [ItemSnapshot] {
        try await worker.perform { try $0.listOpenItems(limit: limit) }
    }

    func petVisibility() async throws -> PetVisibility? {
        try await worker.perform { try $0.petVisibility() }
    }

    @discardableResult
    func setPetVisibility(_ visibility: PetVisibility) async throws -> Bool {
        try await worker.perform { try $0.setPetVisibility(visibility: visibility) }
    }

    func petPlacement() async throws -> PetPlacement? {
        try await worker.perform { try $0.petPlacement() }
    }

    @discardableResult
    func setPetPlacement(_ placement: PetPlacement?) async throws -> Bool {
        try await worker.perform { try $0.setPetPlacement(placement: placement) }
    }

    func onboardingCompleted() async throws -> Bool {
        try await worker.perform { try $0.onboardingCompleted() }
    }

    @discardableResult
    func setOnboardingCompleted() async throws -> Bool {
        try await worker.perform { try $0.setOnboardingCompleted() }
    }
}
