import AppKit
import XCTest

/// The menu's eye-break section (0022 §7), shared by the paw and the pet's context menu.
@MainActor
final class StatusMenuEyeBreakTests: XCTestCase {
    private func controller() -> StatusMenuController {
        StatusMenuController(
            actions: .init(togglePet: {}, toggleAnimations: {}, openNotes: {}, openNotesWindow: {},
                           jumpToWaitingAgent: {}, selectAgentSession: { _ in }, openSettings: {},
                           openUpdate: {}, quit: {}),
            petVisible: { true })
    }

    private func choose(_ item: NSMenuItem) {
        _ = (item.target as? NSObject)?.perform(item.action!, with: item)
    }

    func testWhileOffOnlyTurnOnShows() {
        var turnedOn = false
        let menu = controller()
        menu.eyeBreakActions.turnOn = { turnedOn = true }
        let items = menu.makeMenu().items
        XCTAssertFalse(items.map(\.title).contains("Take a Break Now"))
        choose(items.first { $0.title == "Turn On Eye Breaks" }!)
        XCTAssertTrue(turnedOn)
    }

    func testWhileOnTheStatusLineTakeABreakAndPauseSitBetweenThePetItemsAndSettings() {
        let menu = controller()
        menu.eyeBreakStatus = { .due(in: 754) }
        let items = menu.makeMenu().items
        let titles = items.map(\.title)
        let line = titles.firstIndex(of: "Eye break in 12:34")!
        XCTAssertFalse(items[line].isEnabled)
        XCTAssertEqual(titles[line + 1], "Take a Break Now")
        XCTAssertEqual(titles[line + 2], "Pause Eye Breaks")
        XCTAssertEqual(items[line + 2].submenu?.items.map(\.title), ["For 30 Minutes", "For 1 Hour", "Until Tomorrow"])
        XCTAssertGreaterThan(line, titles.firstIndex(of: "Pause Animations")!)
        XCTAssertLessThan(line, titles.firstIndex(of: "Settings…")!)
    }

    func testTakeABreakNowAndAPauseReachTheirActions() {
        var tookBreak = false
        var pausedUntil: Date?
        let menu = controller()
        menu.eyeBreakStatus = { .paused(until: Date().addingTimeInterval(600)) }
        menu.eyeBreakActions.takeBreakNow = { tookBreak = true }
        menu.eyeBreakActions.pause = { pausedUntil = $0 }
        let items = menu.makeMenu().items
        XCTAssertTrue(items.contains { $0.title.hasPrefix("Eye breaks paused until ") })
        choose(items.first { $0.title == "Take a Break Now" }!)
        XCTAssertTrue(tookBreak)
        let before = Date()
        choose(items.first { $0.title == "Pause Eye Breaks" }!.submenu!.items[1])
        XCTAssertEqual(pausedUntil!.timeIntervalSince(before), 3600, accuracy: 2)
    }
}
