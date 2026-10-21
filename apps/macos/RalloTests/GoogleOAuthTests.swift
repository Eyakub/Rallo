import XCTest

final class GoogleOAuthTests: XCTestCase {
    func testRFC7636Vector() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testMadeVerifierIs64UnreservedCharsAndMatchesItsChallenge() {
        let pkce = PKCE.make()
        XCTAssertEqual(pkce.verifier.count, 64)
        XCTAssertNil(pkce.verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~").inverted))
        XCTAssertEqual(pkce.challenge, PKCE.challenge(for: pkce.verifier))
        XCTAssertNotEqual(PKCE.make().verifier, pkce.verifier)
    }

    func testAuthorizationURLCarriesEveryParameter() throws {
        let url = GoogleOAuth.authorizationURL(clientID: "cid", redirect: URL(string: "http://127.0.0.1:5000")!, challenge: "chal", state: "st")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(components.path, "/o/oauth2/v2/auth")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "client_id": "cid", "redirect_uri": "http://127.0.0.1:5000", "response_type": "code",
            "scope": "https://www.googleapis.com/auth/drive.file", "code_challenge": "chal",
            "code_challenge_method": "S256", "state": "st", "access_type": "offline", "prompt": "consent",
        ])
    }

    func testParseRedirect() throws {
        XCTAssertEqual(try GoogleOAuth.parseRedirect("/?code=abc%2F1&state=s", expectedState: "s"), "abc/1")
        XCTAssertThrowsError(try GoogleOAuth.parseRedirect("/?code=abc&state=other", expectedState: "s")) {
            XCTAssertEqual($0 as? GoogleDriveError, .malformed)
        }
        XCTAssertThrowsError(try GoogleOAuth.parseRedirect("/?error=access_denied&state=s", expectedState: "s")) {
            XCTAssertEqual($0 as? GoogleDriveError, .cancelled)
        }
        XCTAssertThrowsError(try GoogleOAuth.parseRedirect("/?state=s", expectedState: "s")) {
            XCTAssertEqual($0 as? GoogleDriveError, .malformed)
        }
    }
}
