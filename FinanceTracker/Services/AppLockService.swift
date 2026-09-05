import Foundation
import LocalAuthentication
import CryptoKit
import Security

/// Backs the app's optional PIN/Face ID lock. The PIN is stored (hashed) in the Keychain, never
/// UserDefaults — the lock-enabled/use-biometrics flags themselves are non-sensitive and live in
/// @AppStorage on the views that own them.
enum AppLockService {
    enum BiometricType {
        case none
        case touchID
        case faceID
    }

    private static let pinAccount = "com.andreacorzo.FinanceTracker.pin"

    // MARK: - PIN

    static var isPINSet: Bool {
        keychainRead(account: pinAccount) != nil
    }

    static func setPIN(_ pin: String) {
        keychainWrite(account: pinAccount, value: hash(pin))
    }

    static func clearPIN() {
        keychainDelete(account: pinAccount)
    }

    static func verifyPIN(_ pin: String) -> Bool {
        guard let stored = keychainRead(account: pinAccount) else { return false }
        return stored == hash(pin)
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Biometrics

    static var biometricType: BiometricType {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    static var biometricsAvailable: Bool { biometricType != .none }

    static func authenticateWithBiometrics() async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock Clarity"
            )
        } catch {
            return false
        }
    }

    // MARK: - Keychain (generic password, this-device-only, unlocked-only)

    private static func keychainWrite(account: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FinanceTracker",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func keychainRead(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FinanceTracker",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FinanceTracker",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
