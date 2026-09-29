import Foundation
import LocalAuthentication

struct BiometricAuthenticationSession: @unchecked Sendable {
    let context: LAContext
}

struct BiometricCapability: Equatable, Sendable {
    let isAvailable: Bool
    let name: String
    let systemImage: String

    /// Main-actor isolated so it can name the fallback in the student's own
    /// language. "Face ID", "Touch ID" and "Optic ID" are Apple's product names
    /// and are spelled the same in French, so only the generic case translates.
    @MainActor
    static var current: BiometricCapability {
        let context = LAContext()
        var biometricError: NSError?
        _ = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &biometricError
        )
        var deviceAuthenticationError: NSError?
        let available = context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &deviceAuthenticationError
        )

        switch context.biometryType {
        case .faceID:
            return BiometricCapability(
                isAvailable: available,
                name: "Face ID",
                systemImage: "faceid"
            )
        case .touchID:
            return BiometricCapability(
                isAvailable: available,
                name: "Touch ID",
                systemImage: "touchid"
            )
        case .opticID:
            return BiometricCapability(
                isAvailable: available,
                name: "Optic ID",
                systemImage: "opticid"
            )
        case .none:
            return BiometricCapability(
                isAvailable: available,
                name: Loc.text("device authentication"),
                systemImage: "lock.shield.fill"
            )
        @unknown default:
            return BiometricCapability(
                isAvailable: available,
                name: Loc.text("device authentication"),
                systemImage: "lock.shield.fill"
            )
        }
    }
}

enum BiometricAuthenticator {
    static func authenticate(reason: String) async -> Bool {
        await authenticateSession(reason: reason) != nil
    }

    static func authenticateSession(reason: String) async -> BiometricAuthenticationSession? {
        let cancelTitle = await MainActor.run { Loc.text("Use OmniVox password") }
        let context = LAContext()
        context.localizedCancelTitle = cancelTitle

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(
                    returning: success ? BiometricAuthenticationSession(context: context) : nil
                )
            }
        }
    }
}
