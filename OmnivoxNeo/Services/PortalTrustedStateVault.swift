import Foundation
import Security

/// A device-only backup of long-lived OmniVox browser cookies. Short-lived
/// login/session cookies are intentionally excluded so each reauthentication
/// still receives a fresh server session.
@MainActor
struct PortalTrustedStateVault {
    private struct Archive: Codable {
        static let currentVersion = 1

        let version: Int
        let savedAt: Date
        let cookies: [CookieRecord]
    }

    private struct CookieRecord: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let isSecure: Bool
        let isHTTPOnly: Bool
        let sameSitePolicy: String?
        let expiresAt: Date

        init(_ cookie: HTTPCookie, expiresAt: Date) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            isSecure = cookie.isSecure
            isHTTPOnly = cookie.isHTTPOnly
            sameSitePolicy = cookie.sameSitePolicy?.rawValue
            self.expiresAt = expiresAt
        }

        var cookie: HTTPCookie? {
            guard !name.isEmpty, !value.isEmpty, !domain.isEmpty else { return nil }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path.isEmpty ? "/" : path,
                .expires: expiresAt
            ]
            if isSecure {
                properties[.secure] = "TRUE"
            }
            if isHTTPOnly {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            if let sameSitePolicy, !sameSitePolicy.isEmpty {
                properties[.sameSitePolicy] = sameSitePolicy
            }
            return HTTPCookie(properties: properties)
        }
    }

    private struct LegacyArchive: Codable {
        let version: Int
        let savedAt: Date
        let cookies: [LegacyCookieRecord]
    }

    private struct LegacyCookieRecord: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let isSecure: Bool
        let isHTTPOnly: Bool
        let sameSitePolicy: String?
        let expiresAt: Date?

        var cookie: HTTPCookie? {
            guard let expiresAt else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path.isEmpty ? "/" : path,
                .expires: expiresAt
            ]
            if isSecure {
                properties[.secure] = "TRUE"
            }
            if isHTTPOnly {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            if let sameSitePolicy, !sameSitePolicy.isEmpty {
                properties[.sameSitePolicy] = sameSitePolicy
            }
            return HTTPCookie(properties: properties)
        }
    }

    let profileID: UUID
    let institutionHost: String
    /// The family domain a school's OmniVox belongs to.
    ///
    /// Trusted-device cookies are set on this apex rather than on the school's
    /// own subdomain, so it has to be accepted — but it is the school's own
    /// convention, not a constant, because the next portal family will differ.
    var portalDomainSuffix: String = PortalConventions.omnivoxStock.portalDomainSuffix
    var sessionOnlyCookieNames: Set<String> = PortalConventions.omnivoxStock.sessionOnlyCookieNames
    var sessionOnlyCookiePrefixes: [String] = PortalConventions.omnivoxStock.sessionOnlyCookiePrefixes

    /// Imports only durable cookies from the earlier archive format, then
    /// removes that archive so old session cookies can never be replayed.
    func migrateLegacyArchiveIfNeeded() {
        if !load().isEmpty {
            SecItemDelete(legacyQuery as CFDictionary)
            return
        }

        var query = legacyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let archive = try? JSONDecoder().decode(LegacyArchive.self, from: data)
        {
            let durableCookies = archive.cookies
                .compactMap(\.cookie)
                .filter(isDurablePortalCookie)
            if !durableCookies.isEmpty {
                _ = save(durableCookies)
            }
        }
        SecItemDelete(legacyQuery as CFDictionary)
    }

    func load() -> [HTTPCookie] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return []
        }

        guard let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == Archive.currentVersion
        else {
            clear()
            return []
        }

        let cookies = archive.cookies
            .compactMap(\.cookie)
            .filter(isDurablePortalCookie)
        if cookies.isEmpty {
            clear()
        } else if cookies.count != archive.cookies.count {
            _ = save(cookies)
        }
        return cookies
    }

    /// Writes the durable portal cookies, and *only* ever writes.
    ///
    /// A save is not a delete. This used to clear the archive when the snapshot
    /// it was handed contained nothing durable, which made the vault mirror the
    /// cookie jar instead of backing it up — and the jar is legitimately empty
    /// of trust cookies for the whole of a re-login, exactly when the backup is
    /// the only copy left. One unvalidated save during that window destroyed
    /// the trusted-device state whose entire purpose is to prevent the next
    /// re-login, so every launch afterwards burned a fresh verification code.
    ///
    /// Erasure stays deliberate: `clearPortalData` and `ProfileEraser` call
    /// `clear()` directly when the student actually signs out.
    @discardableResult
    func save(_ cookies: [HTTPCookie]) -> Bool {
        let durableCookies = cookies.filter(isDurablePortalCookie)
        guard !durableCookies.isEmpty else {
            return false
        }

        let records = durableCookies.compactMap { cookie -> CookieRecord? in
            guard let expiresAt = cookie.expiresDate else { return nil }
            return CookieRecord(cookie, expiresAt: expiresAt)
        }
        guard !records.isEmpty,
              let data = try? JSONEncoder().encode(
                Archive(
                    version: Archive.currentVersion,
                    savedAt: Date(),
                    cookies: records
                )
              )
        else {
            return false
        }

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }

        var query = baseQuery
        query[kSecValueData as String] = data
        #if os(iOS)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func isDurablePortalCookie(_ cookie: HTTPCookie) -> Bool {
        let normalizedName = cookie.name.lowercased()

        // Reject session-only cookies
        guard !cookie.isSessionOnly else {
            return false
        }

        // Must have expiration date in the future
        guard let expiration = cookie.expiresDate,
              expiration > Date()
        else {
            return false
        }

        // Must be secure and have content
        guard cookie.isSecure,
              !cookie.name.isEmpty,
              !cookie.value.isEmpty
        else {
            return false
        }

        // Reject known session cookie names, and the per-school families the
        // list cannot enumerate. Both come from the school's own conventions.
        guard !sessionOnlyCookieNames.contains(normalizedName),
              !sessionOnlyCookiePrefixes.contains(where: { normalizedName.hasPrefix($0) })
        else {
            return false
        }

        // Verify domain matches our institution
        let host = institutionHost.lowercased()
        let domain = cookie.domain
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        let domainMatches = domain == host
            || host.hasSuffix(".\(domain)")
            || domain == portalDomainSuffix.lowercased()

        #if DEBUG
        if domainMatches {
            print("✅ Preserving trusted cookie: \(cookie.name) (domain: \(cookie.domain), expires: \(expiration))")
        }
        #endif

        return domainMatches
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tjokas.OmnivoxNeo.portal-trusted-state",
            kSecAttrAccount as String: profileID.uuidString,
            kSecAttrSynchronizable as String: false
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private var legacyQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tjokas.OmnivoxNeo.portal-session",
            kSecAttrAccount as String: profileID.uuidString
        ]
    }
}
