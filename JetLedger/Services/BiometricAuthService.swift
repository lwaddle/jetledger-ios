//
//  BiometricAuthService.swift
//  JetLedger
//

import Foundation
import LocalAuthentication
import Observation
import UIKit

@Observable
class BiometricAuthService {

    private(set) var isBiometricsAvailable = false
    private(set) var biometryType: LABiometryType = .none

    /// Key for the biometric-protected device token (triggers Face ID on read).
    private static let deviceTokenKey = "device_token"
    /// Key for a non-biometric copy used only for server revocation on sign-out.
    private static let revocationTokenKey = "device_token_revocation"
    private static let hasPromptedKey = "hasPromptedBiometricLogin"

    var isBiometricLoginEnabled: Bool {
        KeychainHelper.biometricItemExists(key: Self.deviceTokenKey)
    }

    var hasPromptedUser: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasPromptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasPromptedKey) }
    }

    var biometricLabel: String {
        switch biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .none: "Biometrics"
        @unknown default: "Biometrics"
        }
    }

    init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        let context = LAContext()
        var error: NSError?
        isBiometricsAvailable = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error
        )
        biometryType = context.biometryType
    }

    // MARK: - Enable / Disable

    /// Register this device as trusted and store the device token behind biometrics.
    func enableBiometricLogin(apiClient: APIClient) async throws {
        let deviceName = UIDevice.current.name
        let response: TrustDeviceResponse = try await apiClient.request(
            .post, AppConstants.WebAPI.authTrustDevice,
            body: TrustDeviceRequest(deviceName: deviceName)
        )
        guard let data = response.deviceToken.data(using: .utf8) else {
            throw BiometricError.tokenStorageFailed
        }
        // Store biometric-protected copy (triggers Face ID on read).
        guard KeychainHelper.saveBiometric(key: Self.deviceTokenKey, data: data) else {
            throw BiometricError.tokenStorageFailed
        }
        // Store non-biometric copy for revocation on sign-out (readable without Face ID).
        KeychainHelper.save(key: Self.revocationTokenKey, data: data)
    }

    /// Remove biometric login — revoke on server via dedicated endpoint, delete locally.
    func disableBiometricLogin(apiClient: APIClient) async {
        if let token = storedDeviceToken() {
            try? await apiClient.requestVoid(
                .post, AppConstants.WebAPI.authRevokeDevice,
                body: DeviceLoginRequest(deviceToken: token)
            )
        }
        deleteLocalTokens()
    }

    // MARK: - Re-Authentication

    /// Attempt biometric re-authentication using stored device token.
    /// Returns the login response on success, nil if user cancels or token is invalid.
    func attemptBiometricLogin(apiClient: APIClient) async -> LoginResponse? {
        guard let tokenData = KeychainHelper.readBiometric(
            key: Self.deviceTokenKey,
            prompt: "Sign in to JetLedger"
        ) else {
            return nil // User cancelled or biometrics changed
        }
        guard let token = String(data: tokenData, encoding: .utf8) else { return nil }

        do {
            let response: LoginResponse = try await apiClient.request(
                .post, AppConstants.WebAPI.authDeviceLogin,
                body: DeviceLoginRequest(deviceToken: token)
            )
            return response
        } catch {
            // Token invalid or expired — clean up local state
            deleteLocalTokens()
            return nil
        }
    }

    // MARK: - Sign Out Support

    /// Get the stored device token without triggering Face ID (for passing to logout).
    func storedDeviceToken() -> String? {
        guard let data = KeychainHelper.read(key: Self.revocationTokenKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete all local token copies (biometric + revocation).
    func deleteLocalTokens() {
        KeychainHelper.deleteBiometric(key: Self.deviceTokenKey)
        KeychainHelper.delete(key: Self.revocationTokenKey)
    }

    func resetPromptFlag() {
        hasPromptedUser = false
    }
}

// MARK: - DTOs

struct TrustDeviceRequest: Encodable {
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
    }
}

struct TrustDeviceResponse: Decodable {
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
    }
}

struct DeviceLoginRequest: Encodable {
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
    }
}

struct LogoutRequestBody: Encodable {
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
    }
}

enum BiometricError: LocalizedError {
    case tokenStorageFailed

    var errorDescription: String? {
        switch self {
        case .tokenStorageFailed: "Failed to save biometric credentials."
        }
    }
}
