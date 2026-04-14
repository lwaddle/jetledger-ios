//
//  KeychainHelper.swift
//  JetLedger
//

import Foundation
import LocalAuthentication
import Security

enum KeychainHelper {
    private static let service = "io.jetledger.JetLedger"

    @discardableResult
    static func save(key: String, data: Data) -> Bool {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // MARK: - Biometric-Protected Keychain

    /// Save data protected by biometrics (Face ID / Touch ID).
    /// Uses `.biometryCurrentSet` — token is invalidated if biometrics change.
    @discardableResult
    static func saveBiometric(key: String, data: Data) -> Bool {
        deleteBiometric(key: key)
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Read biometric-protected data. iOS automatically shows the Face ID / Touch ID prompt.
    /// Returns nil if biometrics fail, are cancelled, or the item was invalidated.
    static func readBiometric(key: String, prompt: String) -> Data? {
        let context = LAContext()
        context.localizedReason = prompt
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Delete a biometric-protected item (does not trigger Face ID).
    @discardableResult
    static func deleteBiometric(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Check whether a biometric-protected item exists without triggering Face ID.
    static func biometricItemExists(key: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecInteractionNotAllowed means the item exists but needs auth
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private static let biometricService = "io.jetledger.JetLedger.biometric"
}
