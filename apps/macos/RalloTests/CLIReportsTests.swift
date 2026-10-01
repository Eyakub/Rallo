import XCTest

final class CLIReportsTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testDoctorChecksPicksOutHooksAndSkill() {
        let checks = CLIReports.doctorChecks(data("""
        {"ok": false, "checks": [
          {"id": "agent_skill", "status": "ok", "summary": "Installed", "fix": null},
          {"id": "agent_hooks", "status": "warning", "summary": "Stale path", "fix": "rallo setup hooks"}],
         "problem_count": 0, "warning_count": 1}
        """))
        XCTAssertEqual(checks["agent_hooks"], .init(status: "warning", summary: "Stale path"))
        XCTAssertEqual(checks["agent_skill"]?.status, "ok")
        XCTAssertTrue(CLIReports.doctorChecks(data("nope")).isEmpty)
    }

    func testHooksOutcomeListsAgentsAndSurfacesErrors() {
        XCTAssertEqual(
            CLIReports.hooksOutcome(data(#"{"ok":true,"hooks":{"targets":[{"agent":"claude","status":"already_installed"},{"agent":"codex","status":"installed"}]}}"#)),
            .done("Claude Code: already installed. Codex: installed."))
        XCTAssertEqual(
            CLIReports.hooksOutcome(data(#"{"ok":false,"error":{"code":"NOT_INSTALLED","message":"Not installed."}}"#)),
            .failed("Not installed."))
        XCTAssertEqual(CLIReports.hooksOutcome(Data()), .failed("Rallo couldn’t read the result."))
    }

    func testSkillOutcome() {
        XCTAssertEqual(
            CLIReports.skillOutcome(data(#"{"ok":true,"skill":{"installs":[{"agent":"claude","status":"updated","path":"/x","rules":null}]}}"#)),
            .done("Claude Code: updated."))
    }

    func testUpdateOutcome() {
        XCTAssertEqual(
            CLIReports.updateOutcome(data(#"{"ok":true,"current":"0.6.2","latest":"0.7.0","update_available":true,"release_url":"u"}"#)),
            .available(current: "0.6.2", latest: "0.7.0"))
        XCTAssertEqual(
            CLIReports.updateOutcome(data(#"{"ok":true,"current":"0.6.2","latest":"0.6.2","update_available":false,"release_url":"u"}"#)),
            .upToDate(current: "0.6.2"))
        XCTAssertEqual(
            CLIReports.updateOutcome(data(#"{"ok":false,"error":{"code":"UPDATE_CHECK_FAILED","message":"offline"}}"#)),
            .failed("offline"))
    }

    func testIsNewer() {
        XCTAssertTrue(CLIReports.isNewer("0.7.10", than: "0.7.9"))
        XCTAssertTrue(CLIReports.isNewer("v1.0.0", than: "0.9.9"))
        XCTAssertFalse(CLIReports.isNewer("0.7.0", than: "0.7.0"))
        XCTAssertFalse(CLIReports.isNewer("0.6.9", than: "0.7.0"))
        XCTAssertFalse(CLIReports.isNewer("garbage", than: "0.7.0"))
        XCTAssertFalse(CLIReports.isNewer("0.8.0", than: "?"))
    }
}
