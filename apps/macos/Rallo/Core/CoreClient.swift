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

    /// A note with its reminder in one write; `when` is RFC 3339 or a phrase
    /// such as "fri 5pm" (0016).
    func createReminder(_ text: String, when: String) async throws -> ItemSnapshot {
        try await worker.perform { try $0.createReminder(text: text, when: when) }
    }

    /// A note with images (0018); `text` may be empty when there are images.
    /// `folderID` files it in a folder (0019); nil is the built-in Notes.
    func createNote(_ text: String, images: [Data], folderID: String? = nil) async throws -> ItemSnapshot {
        try await worker.perform { try $0.createNoteWithImages(text: text, images: images, folderId: folderID) }
    }

    func createReminder(_ text: String, when: String, images: [Data], folderID: String? = nil) async throws -> ItemSnapshot {
        try await worker.perform {
            try $0.createReminderWithImages(text: text, when: when, images: images, folderId: folderID)
        }
    }

    func attachImages(_ item: ItemSnapshot, images: [Data]) async throws -> ItemSnapshot {
        try await worker.perform { try $0.attachImages(id: item.id, images: images, ifRevision: item.revision) }
    }

    func detachImage(_ item: ItemSnapshot, imageID: String) async throws -> ItemSnapshot {
        try await worker.perform { try $0.detachImage(id: item.id, imageId: imageID, ifRevision: item.revision) }
    }

    func sweepImages() async throws -> SweepResult {
        try await worker.perform { try $0.sweepImages() }
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

    func deleteItem(_ item: ItemSnapshot) async throws -> ItemSnapshot {
        try await worker.perform { try $0.deleteItem(id: item.id, ifRevision: item.revision) }
    }

    func restoreItem(_ item: ItemSnapshot) async throws -> ItemSnapshot {
        try await worker.perform { try $0.restoreItem(id: item.id, ifRevision: item.revision) }
    }

    /// `duration` uses the CLI's `--in` syntax, e.g. "20m" or "1h".
    func remindIn(_ item: ItemSnapshot, duration: String) async throws -> ItemSnapshot {
        try await worker.perform { try $0.remindIn(id: item.id, duration: duration, ifRevision: item.revision) }
    }

    func remindAt(_ item: ItemSnapshot, date: Date) async throws -> ItemSnapshot {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let instant = formatter.string(from: date)
        return try await worker.perform { try $0.remindAt(id: item.id, rfc3339: instant, ifRevision: item.revision) }
    }

    // MARK: Export and import (0004)

    func exportToFile(_ path: String, format: TransferFormat, overwrite: Bool) async throws -> ExportResult {
        try await worker.perform { try $0.exportToFile(path: path, format: format, overwrite: overwrite) }
    }

    func previewImportFile(_ path: String) async throws -> ImportSummary {
        try await worker.perform { try $0.previewImportFile(path: path) }
    }

    func applyImportFile(_ path: String) async throws -> ImportSummary {
        try await worker.perform { try $0.applyImportFile(path: path) }
    }

    // MARK: Notification protocol (0005)

    func recordNativeObservations(
        authorization: NotificationAuthorization, pending: [NativeRequest], delivered: [NativeRequest]
    ) async throws -> CleanupPlan {
        try await worker.perform {
            try $0.recordNativeObservations(authorization: authorization, pending: pending, delivered: delivered)
        }
    }

    /// As last observed by the drainer (0005); the core's copy, so every
    /// view agrees with the scheduling status it reports.
    func notificationAuthorization() async throws -> NotificationAuthorization {
        try await worker.perform { try $0.notificationAuthorization() }
    }

    func notificationIdentifierPrefix() async throws -> String {
        try await worker.perform { $0.notificationIdentifierPrefix() }
    }

    func nextPlatformWork() async throws -> NextWork {
        try await worker.perform { try $0.nextPlatformWork() }
    }

    func beginPlatformAttempt(intentId: Int64, generation: Int64) async throws -> BeginOutcome {
        try await worker.perform { try $0.beginPlatformAttempt(intentId: intentId, generation: generation) }
    }

    func finishPlatformAttempt(token: AttemptToken, outcome: NativeOutcome) async throws -> Finished {
        try await worker.perform { try $0.finishPlatformAttempt(token: token, outcome: outcome) }
    }

    func applyNotificationAction(
        reminderId: String, generation: Int64, action: NotificationAction
    ) async throws -> ActionOutcome {
        try await worker.perform {
            try $0.applyNotificationAction(reminderId: reminderId, generation: generation, action: action)
        }
    }

    // MARK: Pet (0006)

    func petSnapshot() async throws -> PetSnapshot {
        try await worker.perform { try $0.petSnapshot() }
    }

    func petAnimationsPaused() async throws -> Bool {
        try await worker.perform { try $0.petAnimationsPaused() }
    }

    @discardableResult
    func setPetAnimationsPaused(_ paused: Bool) async throws -> Bool {
        try await worker.perform { try $0.setPetAnimationsPaused(paused: paused) }
    }

    func acknowledgeReminder(_ item: ItemSnapshot) async throws -> ItemSnapshot {
        try await worker.perform { try $0.acknowledgeReminder(id: item.id, ifRevision: item.revision) }
    }

    func snoozeReminder(_ item: ItemSnapshot, duration: String) async throws -> ItemSnapshot {
        try await worker.perform { try $0.snoozeReminder(id: item.id, duration: duration, ifRevision: item.revision) }
    }

    /// First page of a scope's open notes (0019); the default is every folder, as before.
    func openItems(scope: FolderScope = .all, limit: UInt32 = 50) async throws -> [ItemSnapshot] {
        try await worker.perform { try $0.listItems(kind: .open, scope: scope, tag: nil, limit: limit, cursor: nil).items }
    }

    // MARK: Folders (0019)

    func folderOverview() async throws -> FolderOverview {
        try await worker.perform { try $0.folderOverview() }
    }

    func createFolder(_ name: String) async throws -> FolderSnapshot {
        try await worker.perform { try $0.createFolder(name: name) }
    }

    func deleteFolder(_ id: String, keepNotes: Bool) async throws -> FolderDeleteResult {
        try await worker.perform { try $0.deleteFolder(id: id, keepNotes: keepNotes) }
    }

    /// `folderID` nil moves the note to the built-in Notes.
    func moveItem(_ item: ItemSnapshot, folderID: String?) async throws -> ItemSnapshot {
        try await worker.perform { try $0.moveItem(id: item.id, folderId: folderID, ifRevision: item.revision) }
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

    // MARK: Agent attention (0007)

    func agentSessions() async throws -> [AgentSessionSnapshot] {
        try await worker.perform { try $0.agentSessions() }
    }

    /// Replaces the ClickUp rows with the conversations now waiting (0010).
    @discardableResult
    func syncClickupWaiting(_ items: [ExternalWaitingInput]) async throws -> Bool {
        try await worker.perform { try $0.syncClickupWaiting(items: items) }
    }

    @discardableResult
    func dismissAgentSession(_ session: AgentSessionSnapshot) async throws -> Bool {
        try await worker.perform { try $0.dismissAgentSession(agent: session.agent, sessionId: session.sessionId) }
    }

    // MARK: Agent attention reach (0008)

    func agentsNotifyLongWait() async throws -> Bool {
        try await worker.perform { try $0.agentsNotifyLongWait() }
    }

    @discardableResult
    func setAgentsNotifyLongWait(_ enabled: Bool) async throws -> Bool {
        try await worker.perform { try $0.setAgentsNotifyLongWait(enabled: enabled) }
    }
}
