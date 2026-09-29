import XCTest
@testable import OmnivoxNeo
import WebKit

/// Test that trusted device cookies are properly saved and restored
@MainActor
final class CookiePersistenceTest: XCTestCase {

    func testTrustedDeviceCookieIdentification() {
        let vault = PortalTrustedStateVault(
            institutionID: "DAWP",
            institutionHost: "dawsoncollege.omnivox.ca"
        )

        // These are the actual cookies that persist after logout on web
        let trustedCookies = [
            // ParametresModule
            makeTestCookie(
                name: "ParametresModule",
                value: "H4sIAD755Z8A...",
                domain: "dawsoncollege.omnivox.ca",
                expires: Date().addingTimeInterval(86400 * 30)
            ),
            // tkdzfxGtdu_dsUwGHCOya24lA (random name pattern)
            makeTestCookie(
                name: "tkdzfxGtdu_dsUwGHCOya24lA",
                value: "Sk44UJqvCmUZMk2rRq7RWUn30GQLI7X8YgwNo9fN2os.nc0zzcW_35ZDBslkwoI8UDSikNWiGG-luUwvuCd5tC4",
                domain: ".omnivox.ca",
                expires: Date().addingTimeInterval(86400 * 365)
            ),
            // DTKS
            makeTestCookie(
                name: "DTKS",
                value: "dlFzbXNpTFdFTWVMUW85WVZCd2tVdDRWK2pvU3Q4c21qcllYcXdNcVNLSTJ0MkdYMkdnNEZYNDhJdkFweG9IWA__",
                domain: ".omnivox.ca",
                expires: Date().addingTimeInterval(86400 * 365)
            ),
            // ckxiRRu9QiLyyMsKcb5DuPKQ (another random name pattern)
            makeTestCookie(
                name: "ckxiRRu9QiLyyMsKcb5DuPKQ",
                value: "rmOS3H6PlvaTM/1A5xncJC3lsHf0g6MvFVHrR85ZV6E=",
                domain: "dawsoncollege.omnivox.ca",
                expires: Date().addingTimeInterval(86400 * 365)
            )
        ]

        // Session cookies that should NOT be preserved
        let sessionCookies = [
            makeTestCookie(
                name: "TKINTR",
                value: "D2ED8C93FA85B90E...",
                domain: "dawsoncollege.omnivox.ca",
                expires: nil // session only
            ),
            makeTestCookie(
                name: "k",
                value: "VEFJZElyc1pUTnhxRFhjTElpTTRiZEtGbUpXWEVNL05kNmNlM2lGUXNvdGxaQ0tIU1JmdkxyNzM3OS85U25xRw__",
                domain: ".omnivox.ca",
                expires: nil // session only
            )
        ]

        // Verify trusted cookies are identified as durable
        for cookie in trustedCookies {
            XCTAssertTrue(
                vault.isDurablePortalCookie(cookie),
                "\(cookie.name) should be identified as a durable trusted device cookie"
            )
        }

        // Verify session cookies are NOT identified as durable
        for cookie in sessionCookies {
            XCTAssertFalse(
                vault.isDurablePortalCookie(cookie),
                "\(cookie.name) should NOT be identified as a durable cookie"
            )
        }
    }

    func testCookieSaveAndRestore() {
        let vault = PortalTrustedStateVault(
            institutionID: "DAWP-test-\(UUID().uuidString)",
            institutionHost: "dawsoncollege.omnivox.ca"
        )

        let testCookies = [
            makeTestCookie(
                name: "DTKS",
                value: "testvalue123",
                domain: ".omnivox.ca",
                expires: Date().addingTimeInterval(86400)
            ),
            makeTestCookie(
                name: "ParametresModule",
                value: "testmodule",
                domain: "dawsoncollege.omnivox.ca",
                expires: Date().addingTimeInterval(86400)
            )
        ]

        // Save cookies
        let saved = vault.save(testCookies)
        XCTAssertTrue(saved, "Cookies should be saved successfully")

        // Load cookies
        let loaded = vault.load()
        XCTAssertEqual(loaded.count, testCookies.count, "Should load same number of cookies")

        for cookie in testCookies {
            let found = loaded.first { $0.name == cookie.name }
            XCTAssertNotNil(found, "Cookie \(cookie.name) should be loaded")
            XCTAssertEqual(found?.value, cookie.value, "Cookie \(cookie.name) value should match")
        }

        // Cleanup
        vault.clear()
    }

    private func makeTestCookie(
        name: String,
        value: String,
        domain: String,
        expires: Date?
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
            .secure: "TRUE"
        ]

        if let expires = expires {
            properties[.expires] = expires
        }

        return HTTPCookie(properties: properties)!
    }
}
