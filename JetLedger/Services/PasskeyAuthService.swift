//
//  PasskeyAuthService.swift
//  JetLedger
//

import AuthenticationServices
import Foundation
import UIKit

enum PasskeyError: Error, LocalizedError, Equatable {
    case cancelled
    case invalidOptions(String)
    case ceremonyFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Passkey sign-in was cancelled."
        case .invalidOptions(let msg): "Could not read passkey challenge (\(msg))."
        case .ceremonyFailed(let msg): "Passkey sign-in failed: \(msg)"
        }
    }
}

/// Wraps `ASAuthorizationController` with a one-shot async API for assertion ceremonies.
/// Credentials live server-side (registered on the web app). Only authentication is in scope here.
@Observable
final class PasskeyAuthService: NSObject {
    /// Holds the delegate + controller for the in-flight request. `ASAuthorizationController.delegate`
    /// is weak, so without this the delegate would deallocate as soon as `performAssertion` suspends.
    private var activeRequest: ActiveRequest?

    private final class ActiveRequest {
        let delegate: PasskeyAssertionDelegate
        let controller: ASAuthorizationController
        init(delegate: PasskeyAssertionDelegate, controller: ASAuthorizationController) {
            self.delegate = delegate
            self.controller = controller
        }
    }

    /// Runs a passwordless (discoverable) passkey assertion using options returned from
    /// `POST /api/auth/passkey/begin`. The server sends an empty `allowCredentials` list
    /// so the OS shows every passkey scoped to the RP and lets the user pick one.
    func performDiscoverableAssertion(options: PublicKeyCredentialRequestOptions) async throws -> PasskeyAssertion {
        try await performAssertion(options: options)
    }

    /// Runs a platform passkey assertion using options returned from `POST /api/auth/webauthn/begin`.
    func performAssertion(options: PublicKeyCredentialRequestOptions) async throws -> PasskeyAssertion {
        let pk = options.publicKey

        guard let challengeData = Data(base64URLEncoded: pk.challenge) else {
            throw PasskeyError.invalidOptions("challenge is not valid base64url")
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: pk.rpId
        )
        let request = provider.createCredentialAssertionRequest(challenge: challengeData)

        if let allowed = pk.allowCredentials, !allowed.isEmpty {
            request.allowedCredentials = try allowed.map { desc in
                guard let idData = Data(base64URLEncoded: desc.id) else {
                    throw PasskeyError.invalidOptions("credential id is not valid base64url")
                }
                return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: idData)
            }
        }

        switch pk.userVerification {
        case "required": request.userVerificationPreference = .required
        case "preferred": request.userVerificationPreference = .preferred
        case "discouraged": request.userVerificationPreference = .discouraged
        default: break
        }

        let delegate = PasskeyAssertionDelegate()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = delegate
        controller.presentationContextProvider = delegate
        activeRequest = ActiveRequest(delegate: delegate, controller: controller)

        defer { activeRequest = nil }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            controller.performRequests()
        }
    }
}

// MARK: - Delegate

private final class PasskeyAssertionDelegate: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    var continuation: CheckedContinuation<PasskeyAssertion, Error>?

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        defer { continuation = nil }
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            continuation?.resume(throwing: PasskeyError.ceremonyFailed("unexpected credential type"))
            return
        }
        let assertion = PasskeyAssertion(
            credentialID: credential.credentialID,
            authenticatorData: credential.rawAuthenticatorData,
            clientDataJSON: credential.rawClientDataJSON,
            signature: credential.signature,
            userHandle: credential.userID
        )
        continuation?.resume(returning: assertion)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        defer { continuation = nil }
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            continuation?.resume(throwing: PasskeyError.cancelled)
        } else {
            continuation?.resume(throwing: PasskeyError.ceremonyFailed(error.localizedDescription))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

// MARK: - DTOs

/// Top-level shape the server returns from `POST /api/auth/webauthn/begin`.
/// The Go side wraps go-webauthn's `protocol.CredentialAssertion` in `{ "options": { "publicKey": {...} } }`.
struct PublicKeyCredentialRequestOptions: Decodable, Sendable {
    let publicKey: PublicKey

    struct PublicKey: Decodable, Sendable {
        let challenge: String
        let rpId: String
        let allowCredentials: [CredentialDescriptor]?
        let userVerification: String?
        let timeout: Int?
    }

    struct CredentialDescriptor: Decodable, Sendable {
        let type: String
        let id: String
        let transports: [String]?
    }
}

/// Raw bytes returned by the platform authenticator. Converted to JSON for the server below.
struct PasskeyAssertion: Sendable {
    let credentialID: Data
    let authenticatorData: Data
    let clientDataJSON: Data
    let signature: Data
    let userHandle: Data?

    var jsonEnvelope: PasskeyAssertionEnvelope {
        PasskeyAssertionEnvelope(
            id: credentialID.base64URLEncoded,
            rawId: credentialID.base64URLEncoded,
            type: "public-key",
            response: .init(
                authenticatorData: authenticatorData.base64URLEncoded,
                clientDataJSON: clientDataJSON.base64URLEncoded,
                signature: signature.base64URLEncoded,
                userHandle: userHandle?.base64URLEncoded
            )
        )
    }
}

/// Matches the WebAuthn JSON shape the Go server's `protocol.ParseCredentialRequestResponseBytes` consumes.
struct PasskeyAssertionEnvelope: Encodable, Sendable {
    let id: String
    let rawId: String
    let type: String
    let response: AssertionResponse

    struct AssertionResponse: Encodable, Sendable {
        let authenticatorData: String
        let clientDataJSON: String
        let signature: String
        let userHandle: String?
    }
}

// MARK: - Base64URL

extension Data {
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }

    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
