import Foundation
import LocalAuthentication
import Security

struct PortalCredential: Codable, Sendable {
    let studentID: String
    let password: String
}

/// Stores only the reusable account credential. Session tokens are never kept
/// here and the item requires a previously authenticated device-owner context.
@MainActor
struct PortalCredentialVault {
    let profileID: UUID

    func load(using authentication: BiometricAuthenticationSession) -> PortalCredential? {
        authentication.context.interactionNotAllowed = true

        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authentication.context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let credential = try? JSONDecoder().decode(PortalCredential.self, from: data)
        else {
            return nil
        }
        return credential
    }

    func save(_ credential: PortalCredential, using authentication: BiometricAuthenticationSession) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else {
            print("🔐 Vault: Failed to encode credential")
            return false
        }

        // Create access control that requires biometry
        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        )

        guard let accessControl else {
            print("🔐 Vault: Failed to create access control")
            return false
        }

        // First, try to delete any existing item (without auth required for delete)
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        print("🔐 Vault: Delete existing item status: \(deleteStatus)")

        // Now add the new item with authentication context
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessControl as String] = accessControl
        query[kSecAttrLabel as String] = "OmniVox Neo Face ID sign-in"
        query[kSecUseAuthenticationContext as String] = authentication.context

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        print("🔐 Vault: Add new item status: \(addStatus)")

        if addStatus != errSecSuccess {
            print("🔐 Vault: Error code \(addStatus)")
        }

        return addStatus == errSecSuccess
    }

    /// Update credentials without requiring new authentication (for password changes during active session)
    func update(_ credential: PortalCredential) async -> Bool {
        // First authenticate to update
        guard let authentication = await BiometricAuthenticator.authenticateSession(
            reason: await MainActor.run { Loc.text("Update your saved OmniVox password") }
        ) else {
            print("🔐 Vault: Authentication failed for update")
            return false
        }

        // Use the authenticated save method
        return save(credential, using: authentication)
    }

    @discardableResult
    func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tjokas.OmnivoxNeo.portal-credential",
            kSecAttrAccount as String: profileID.uuidString,
            kSecAttrSynchronizable as String: false
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}
