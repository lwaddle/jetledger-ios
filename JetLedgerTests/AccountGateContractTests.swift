//
//  AccountGateContractTests.swift
//  JetLedgerTests
//
//  Pins the client half of the deferred-provisioning and plan gates (web repo
//  docs/ios-api.md § "Deferred provisioning & plan gates (2026-08-03)").
//
//  Before this existed, both typed 403s collapsed into APIError.forbidden and
//  surfaced as "You don't have permission to perform this action." A user who
//  signed up from inside the app and never finished setup on the web — which
//  is every self-service signup, including an App Store reviewer's — hit that
//  dead end on the receipt list with nothing actionable to do.
//
//  Matching is on `error` EXACTLY, never on `message`: the message is
//  server-owned display copy and free to change, and a substring match would
//  let an unrelated error containing the phrase trip a gate.
//

import Testing
import Foundation
@testable import JetLedger

@Suite
@MainActor
struct AccountGateContractTests {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Recognition

    @Test
    func recognizesWorkspaceNotProvisioned() {
        let gate = APIClient.accountGateError(from: body("""
        {"error": "workspace_not_provisioned",
         "message": "Finish setting up your organization on the web at jetledger.io, then try again."}
        """))
        #expect(gate == .workspaceNotProvisioned())
    }

    @Test
    func recognizesPlanExpired() {
        let gate = APIClient.accountGateError(from: body("""
        {"error": "plan_expired",
         "message": "Your trial has ended. Subscribe on the web to keep editing."}
        """))
        #expect(gate == .planExpired())
    }

    /// The server's copy is the authoritative wording — the web side vetted it
    /// against App Store 3.1.1. Surfacing our own would risk drifting from it.
    @Test
    func surfacesTheServerMessage() {
        let gate = APIClient.accountGateError(from: body("""
        {"error": "workspace_not_provisioned", "message": "Server copy wins."}
        """))
        #expect(gate?.localizedDescription == "Server copy wins.")
    }

    /// The gates are documented with a `message`, but a body without one must
    /// still be recognized and must still say something useful.
    @Test
    func fallsBackToContractCopyWhenMessageIsAbsent() {
        let gate = APIClient.accountGateError(from: body(#"{"error": "plan_expired"}"#))
        #expect(gate == .planExpired())
        #expect(gate?.localizedDescription.isEmpty == false)
    }

    // MARK: - Non-recognition

    @Test
    func ignoresUnrelated403Bodies() {
        for json in [
            #"{"error": "insufficient permissions"}"#,
            #"{"error": "access denied"}"#,
            #"{"error": "terms_acceptance_required"}"#,
            #"{"not_an_error": "x"}"#,
        ] {
            #expect(APIClient.accountGateError(from: body(json)) == nil,
                    "must not treat \(json) as an account gate")
        }
    }

    /// Exact match, not substring — the same rule the terms backstop follows.
    @Test
    func doesNotMatchOnSubstrings() {
        #expect(APIClient.accountGateError(from: body(
            #"{"error": "plan_expired_soon"}"#)) == nil)
        #expect(APIClient.accountGateError(from: body(
            #"{"error": "workspace_not_provisioned_yet"}"#)) == nil)
    }

    @Test
    func unparseableBodyIsNotAGate() {
        #expect(APIClient.accountGateError(from: body("<html>503</html>")) == nil)
    }

    // MARK: - Distinctness

    /// These must not be interchangeable with each other or with a plain
    /// permission failure: the queue parks on the gates and fails on
    /// .forbidden, so conflating them either strands work or discards it.
    @Test
    func gatesAreDistinctFromEachOtherAndFromForbidden() {
        #expect(APIError.workspaceNotProvisioned() != APIError.planExpired())
        #expect(APIError.workspaceNotProvisioned() != APIError.forbidden)
        #expect(APIError.planExpired() != APIError.forbidden)
        #expect(APIError.planExpired() != APIError.termsAcceptanceRequired)
    }

    /// Equality is by case, so callers can match a gate without knowing which
    /// display copy the server happened to send.
    @Test
    func equalityIgnoresTheServerMessage() {
        #expect(APIError.planExpired(serverMessage: "a") == APIError.planExpired(serverMessage: "b"))
    }
}
