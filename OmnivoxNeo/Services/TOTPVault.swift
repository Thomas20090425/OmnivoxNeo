//
//  TOTPVault.swift
//  OmnivoxNeo
//
//  Secure storage for TOTP secrets in Keychain, scoped per profile
//

import Foundation
import Security

@MainActor
struct TOTPVault {
    private let profileID: UUID

    init(profileID: UUID) {
        self.profileID = profileID
    }

    /// Load TOTP secret for this profile
    func load() -> TOTPSecret? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let secret = try? JSONDecoder().decode(TOTPSecret.self, from: data)
        else {
            return nil
        }

        // Verify it matches the profile
        guard secret.profileID == profileID else {
            return nil
        }

        return secret
    }

    /// Save TOTP secret for this profile
    @discardableResult
    func save(_ secret: TOTPSecret) -> Bool {
        guard secret.profileID == profileID else { return false }

        guard let data = try? JSONEncoder().encode(secret) else {
            return false
        }

        // Try update first
        var query = baseQuery
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }

        // If update failed, try insert
        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }

        return false
    }

    /// Delete TOTP secret for this profile
    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if TOTP is configured for this profile
    func exists() -> Bool {
        return load() != nil
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tjokas.OmnivoxNeo.totp",
            kSecAttrAccount as String: profileID.uuidString,
            kSecAttrSynchronizable as String: false
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}
