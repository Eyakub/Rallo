import Combine
import Foundation

/// Changes to the open note and the notes in the list (0019 §11). Each one
/// first lets the editor save, so a toolbar action never races the editor's
/// own revision; each says what it did, with Undo where the panel has it.
extension NotesWindowModel {
    /// The completion circle and Mark as Done / Reopen.
    func toggleDone(_ item: ItemSnapshot) async {
        let item = await fresh(item)
        do {
            if item.status == .done {
                _ = try await core.reopenItem(item)
            } else {
                let done = try await core.completeItem(item)
                announce("Marked “\(done.name)” as done") { [weak self] in
                    guard let self else { return }
                    let latest = await self.fresh(done)
                    await self.run { _ = try await $0.reopenItem(latest) }
                }
            }
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Soft delete (the trash button and ⌫); Undo restores it.
    func delete(_ item: ItemSnapshot) async {
        let item = await fresh(item)
        do {
            let deleted = try await core.deleteItem(item)
            announce("Deleted “\(deleted.name)”") { [weak self] in
                guard let self else { return }
                let latest = await self.fresh(deleted)
                await self.run { _ = try await $0.restoreItem(latest) }
            }
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Restore, in the Deleted view: the note returns to its folder (or Notes).
    func restore(_ item: ItemSnapshot) async {
        do {
            let restored = try await core.restoreItem(item)
            announce("Restored “\(restored.name)”")
            await reload()
        } catch {
            await report(error)
        }
    }

    /// The same three choices as the panel's Remind Me menu.
    func remind(_ item: ItemSnapshot, _ preset: RemindPreset) async {
        let item = await fresh(item)
        await setReminder { core in
            switch preset {
            case .inTwentyMinutes: try await core.remindIn(item, duration: "20m")
            case .inOneHour: try await core.remindIn(item, duration: "1h")
            case .tomorrowMorning: try await core.remindAt(item, date: RemindPreset.tomorrowMorning())
            }
        }
    }

    /// Custom…, with the time the popover previewed.
    func remind(_ item: ItemSnapshot, at date: Date) async {
        let item = await fresh(item)
        await setReminder { try await $0.remindAt(item, date: date) }
    }

    private func setReminder(_ change: (CoreClient) async throws -> ItemSnapshot) async {
        do {
            let updated = try await change(core)
            if let reminder = updated.reminder {
                let deadline = Date(timeIntervalSince1970: TimeInterval(reminder.deadlineMs) / 1000)
                announce("Reminder set for \(ReminderLabel.text(for: deadline))")
            }
            await reload()
        } catch {
            await report(error)
        }
    }

    /// The reminder pill's Cancel Reminder (0019 §9): the reminder becomes
    /// `cancelled`, the note stays open.
    func cancelReminder(_ item: ItemSnapshot) async {
        let item = await fresh(item)
        await run { _ = try await $0.cancelReminder(item) }
    }

    /// Add Image: the images the user picked, already normalised.
    func attachImages(_ images: [Data], to item: ItemSnapshot) async {
        let item = await fresh(item)
        do {
            try ImageClipboard.check(images, staged: item.images.count)
            _ = try await core.attachImages(item, images: images)
            await reload()
        } catch let refusal as ImageRefusal {
            errorMessage = refusal.message
        } catch {
            await report(error)
        }
    }

    /// Remove Image; the bytes are read first so Undo can attach the image again.
    func removeImage(_ image: ImageSnapshot, from item: ItemSnapshot) async {
        let item = await fresh(item)
        let data = try? Data(contentsOf: URL(fileURLWithPath: image.path))
        do {
            let updated = try await core.detachImage(item, imageID: image.id)
            announce("Removed the image", undo: data.map { data in
                { [weak self] in
                    guard let self else { return }
                    let latest = await self.fresh(updated)
                    await self.run { _ = try await $0.attachImages(latest, images: [data]) }
                }
            })
            await reload()
        } catch {
            await report(error)
        }
    }
}
