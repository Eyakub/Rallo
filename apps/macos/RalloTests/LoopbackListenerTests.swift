import XCTest

final class LoopbackListenerTests: XCTestCase {
    func testIgnoresFaviconThenReturnsTheRedirectTarget() async throws {
        let listener = try await LoopbackListener()
        let waiting = Task { try await listener.waitForRequestTarget(timeout: 20) }
        let session = URLSession(configuration: .ephemeral)
        let (_, favicon) = try await session.data(from: URL(string: "\(listener.redirectURL.absoluteString)/favicon.ico")!)
        XCTAssertEqual((favicon as? HTTPURLResponse)?.statusCode, 404)
        let (body, response) = try await session.data(from: URL(string: "\(listener.redirectURL.absoluteString)/?code=abc&state=s")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("Rallo"))
        let target = try await waiting.value
        XCTAssertEqual(target, "/?code=abc&state=s")
    }

    func testCancelThrows() async throws {
        let listener = try await LoopbackListener()
        let waiting = Task { try await listener.waitForRequestTarget(timeout: 20) }
        try await Task.sleep(nanoseconds: 100_000_000)
        listener.cancel()
        do {
            _ = try await waiting.value
            XCTFail("expected cancel to throw")
        } catch {
            XCTAssertEqual(error as? GoogleDriveError, .cancelled)
        }
    }

    func testTimesOut() async throws {
        let listener = try await LoopbackListener()
        do {
            _ = try await listener.waitForRequestTarget(timeout: 0.2)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? GoogleDriveError, .timedOut)
        }
    }
}
