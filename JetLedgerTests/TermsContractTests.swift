//
//  TermsContractTests.swift
//  JetLedgerTests
//
//  Pins the client half of the terms re-acceptance contract (web repo
//  docs/ios-api.md § "Terms re-acceptance (2026-07-31)"): the signal decodes
//  from session-creating responses, and the 403 backstop is recognized by
//  EXACT error-string match — a substring match here would let any future
//  error message that merely mentions terms lock the whole app.
//

import Testing
import Foundation
@testable import JetLedger

@Suite
struct TermsContractTests {

    // MARK: - Signal decoding

    @Test
    func termsSignalDecodesTheContractPayload() throws {
        let json = """
        {
            "current_version": "2026-07-31",
            "accepted_version": "2026-05-01",
            "acceptance_required": true,
            "terms_url": "https://jetledger.io/terms",
            "privacy_url": "https://jetledger.io/privacy"
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(TermsStatus.self, from: json)

        #expect(status.currentVersion == "2026-07-31")
        #expect(status.acceptedVersion == "2026-05-01")
        #expect(status.acceptanceRequired)
        #expect(status.termsUrl == "https://jetledger.io/terms")
        #expect(status.privacyUrl == "https://jetledger.io/privacy")
    }

    /// `accepted_version` is `null` for users who predate the signup clickwrap
    /// — the gate copy treats them as a first acceptance, not an update.
    @Test
    func nullAcceptedVersionDecodesAsFirstAcceptance() throws {
        let json = """
        {"current_version": "2026-07-31", "accepted_version": null,
         "acceptance_required": true,
         "terms_url": "https://jetledger.io/terms",
         "privacy_url": "https://jetledger.io/privacy"}
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(TermsStatus.self, from: json)

        #expect(status.acceptedVersion == nil)
    }

    @Test
    func loginResponseCarriesTheTermsSignal() throws {
        let json = """
        {"session_token": "abc",
         "user": {"id": "\(UUID().uuidString.lowercased())", "email": "p@x.io",
                  "first_name": "Pat", "last_name": "West"},
         "accounts": [],
         "terms": {"current_version": "2026-07-31", "accepted_version": null,
                   "acceptance_required": true,
                   "terms_url": "https://jetledger.io/terms",
                   "privacy_url": "https://jetledger.io/privacy"}}
        """.data(using: .utf8)!

        let response = try APIClient.decoder.decode(LoginResponse.self, from: json)

        #expect(response.terms?.acceptanceRequired == true)
        #expect(response.terms?.currentVersion == "2026-07-31")
    }

    /// Servers predating the contract send no `terms` object. Its absence must
    /// not fail the decode — and reads as "no gate": fail-open applies to old
    /// servers the same as to transport errors.
    @Test
    func loginResponseWithoutTermsStillDecodes() throws {
        let json = """
        {"session_token": "abc",
         "user": {"id": "\(UUID().uuidString.lowercased())", "email": "p@x.io",
                  "first_name": "Pat", "last_name": "West"},
         "accounts": []}
        """.data(using: .utf8)!

        let response = try APIClient.decoder.decode(LoginResponse.self, from: json)

        #expect(response.terms == nil)
    }

    // MARK: - 403 backstop classification

    @Test
    func backstopBodyIsRecognizedAndCarriesTheGateFields() {
        let body = """
        {"error": "terms_acceptance_required",
         "message": "The JetLedger Terms of Service have been updated and must be accepted before continuing.",
         "terms_version": "2026-07-31",
         "terms_url": "https://jetledger.io/terms"}
        """.data(using: .utf8)!

        let payload = APIClient.termsRequiredPayload(from: body)

        #expect(payload?.termsVersion == "2026-07-31")
        #expect(payload?.termsUrl == "https://jetledger.io/terms")
    }

    /// Exact match, like the drain middleware's `"maintenance"` — near misses
    /// must not flip the gate.
    @Test
    func nearMissErrorStringsDoNotMatch() {
        let nearMisses = [
            "terms_acceptance_required_v2",
            "error: terms_acceptance_required",
            "TERMS_ACCEPTANCE_REQUIRED",
            "forbidden",
        ]
        for error in nearMisses {
            let body = """
            {"error": "\(error)", "terms_version": "2026-07-31",
             "terms_url": "https://jetledger.io/terms"}
            """.data(using: .utf8)!
            #expect(APIClient.termsRequiredPayload(from: body) == nil,
                    "\"\(error)\" must not be classified as the terms gate")
        }
    }

    @Test
    func ordinaryForbiddenBodiesDoNotMatch() {
        #expect(APIClient.termsRequiredPayload(
            from: #"{"error":"insufficient permissions"}"#.data(using: .utf8)!) == nil)
        #expect(APIClient.termsRequiredPayload(from: Data()) == nil)
        #expect(APIClient.termsRequiredPayload(from: "not json".data(using: .utf8)!) == nil)
    }

    // MARK: - 403 → presentable status

    /// The backstop body carries only the version and terms URL; whatever a
    /// prior full signal knew must survive the merge, and the result must
    /// always gate.
    @Test
    func backstopMergePreservesThePriorSignal() {
        let payload = TermsRequiredPayload(
            error: "terms_acceptance_required",
            termsVersion: "2026-07-31",
            termsUrl: "https://jetledger.io/terms"
        )
        let prior = TermsStatus(
            currentVersion: "2026-05-01",
            acceptedVersion: "2026-01-01",
            acceptanceRequired: false,
            termsUrl: "https://jetledger.io/terms",
            privacyUrl: "https://jetledger.io/privacy-v1"
        )

        let merged = TermsStatus.from403(payload, merging: prior)

        #expect(merged.acceptanceRequired)
        #expect(merged.currentVersion == "2026-07-31")
        #expect(merged.acceptedVersion == "2026-01-01")
        #expect(merged.privacyUrl == "https://jetledger.io/privacy-v1")
    }

    /// A landing-time sync can trip the backstop before any signal has been
    /// fetched — the gate must still be presentable from the 403 alone.
    @Test
    func backstopWithNoPriorSignalFallsBackToTheConstants() {
        let payload = TermsRequiredPayload(
            error: "terms_acceptance_required",
            termsVersion: "2026-07-31",
            termsUrl: "https://jetledger.io/terms"
        )

        let merged = TermsStatus.from403(payload, merging: nil)

        #expect(merged.acceptanceRequired)
        #expect(merged.acceptedVersion == nil)
        #expect(merged.privacyUrl == AppConstants.Links.privacy.absoluteString)
    }
}
