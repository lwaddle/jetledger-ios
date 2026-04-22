//
//  JetLedgerTests.swift
//  JetLedgerTests
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

@MainActor
struct TripReferenceServiceTests {

    private func makeService(isConnected: Bool) throws -> (TripReferenceService, ModelContext) {
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext
        let monitor = NetworkMonitor()
        monitor.setConnectedForTesting(isConnected)
        let apiClient = APIClient(baseURL: URL(string: "https://example.invalid")!)
        let service = TripReferenceService(
            apiClient: apiClient,
            modelContext: context,
            networkMonitor: monitor
        )
        return (service, context)
    }

    @Test
    func createTripReferenceRejectsWhenOffline() async throws {
        let (service, _) = try makeService(isConnected: false)

        await #expect(throws: TripReferenceError.self) {
            try await service.createTripReference(
                accountId: UUID(),
                externalId: "TRIP-1",
                name: nil
            )
        }
    }

    @Test
    func tripReferenceDTODecodesSQLiteDatetimeString() throws {
        // Server emits SQLite datetime format (space separator, no timezone):
        // `datetime('now')` → "YYYY-MM-DD HH:MM:SS"
        let json = """
        {
            "id": "550E8400-E29B-41D4-A716-446655440000",
            "external_id": "TRIP-42",
            "name": "Test Trip",
            "created_at": "2026-04-20 15:30:00"
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(TripReferenceDTO.self, from: json)

        #expect(dto.id.uuidString == "550E8400-E29B-41D4-A716-446655440000")
        #expect(dto.externalId == "TRIP-42")
        #expect(dto.name == "Test Trip")
        #expect(dto.createdAt == "2026-04-20 15:30:00")
    }

    @Test
    func createReceiptRequestEncodesLowercaseTripReferenceId() throws {
        // Server stores UUIDs lowercase (Go's uuid.New()); SQLite FK comparison is
        // case-sensitive. iOS must send lowercase or the CreateStagedReceipt INSERT
        // fails with FOREIGN KEY constraint failed.
        let uuid = UUID()
        let request = CreateReceiptRequest(
            accountId: UUID(),
            note: nil,
            tripReferenceId: uuid.uuidString.lowercased(),
            images: []
        )

        let data = try JSONEncoder().encode(request)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let tripRefId = try #require(json["trip_reference_id"] as? String)
        #expect(tripRefId == uuid.uuidString.lowercased())
        #expect(tripRefId == tripRefId.lowercased())
    }
}

/// MockURLProtocol uses process-wide static state, so all suites that touch it
/// must run serially — not just the tests within each suite. This umbrella suite
/// serializes cross-suite execution for its nested suites.
@MainActor
@Suite(.serialized)
struct MockURLProtocolSuites {

@MainActor
@Suite(.serialized)
struct APIClientRawRequestTests {
    @Test
    func performRawRequestReturns401WithoutInvokingOnUnauthorized() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = #"{"error":"incorrect password"}"#.data(using: .utf8)!
            return (response, body)
        }

        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: MockURLProtocol.makeSession()
        )
        var unauthorizedCalled = false
        client.onUnauthorized = { unauthorizedCalled = true }

        let (data, status) = try await client.performRawRequest(
            .post, "/api/user/delete-account",
            bodyData: Data("{}".utf8)
        )

        #expect(status == 401)
        #expect(String(data: data, encoding: .utf8) == #"{"error":"incorrect password"}"#)
        #expect(unauthorizedCalled == false)
    }
}

@MainActor
@Suite(.serialized)
struct AuthServiceDeleteAccountTests {

    init() {
        MockURLProtocol.reset()
    }

    private func makeService() -> AuthService {
        let service = AuthService()
        // Swap in a mocked URLSession. Preserve any token if one were cached.
        let mockClient = APIClient(
            baseURL: service.apiClient.baseURL,
            session: MockURLProtocol.makeSession()
        )
        if let token = service.apiClient.sessionToken {
            mockClient.setSessionToken(token)
        }
        service.apiClient = mockClient
        return service
    }

    @Test
    func deleteAccountReturnsScheduledDateOn200() async throws {
        let service = makeService()
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test/api/user/delete-account")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let body = #"{"message":"account scheduled for deletion","deletion_scheduled_for":"2026-05-21T12:00:00Z"}"#.data(using: .utf8)!
            return (response, body)
        }

        let date = try await service.deleteAccount(
            password: "hunter2",
            confirmEmail: "user@example.com"
        )
        #expect(date.timeIntervalSince1970 > 0)
    }

    @Test
    func deleteAccountMapsIncorrectPasswordTo401Case() async throws {
        let service = makeService()
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test/api/user/delete-account")!,
                statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            let body = #"{"error":"incorrect password"}"#.data(using: .utf8)!
            return (response, body)
        }

        do {
            _ = try await service.deleteAccount(password: "wrong", confirmEmail: "user@example.com")
            Issue.record("expected throw")
        } catch let e as DeleteAccountError {
            if case .invalidPassword = e { /* ok */ }
            else { Issue.record("unexpected case: \(e)") }
        }
    }

    @Test
    func deleteAccountMapsEmailMismatchTo422Case() async throws {
        let service = makeService()
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test/api/user/delete-account")!,
                statusCode: 422, httpVersion: nil, headerFields: nil
            )!
            let body = #"{"error":"email does not match"}"#.data(using: .utf8)!
            return (response, body)
        }

        do {
            _ = try await service.deleteAccount(password: "x", confirmEmail: "wrong@example.com")
            Issue.record("expected throw")
        } catch let e as DeleteAccountError {
            if case .emailMismatch = e { /* ok */ }
            else { Issue.record("unexpected case: \(e)") }
        }
    }

    @Test
    func deleteAccountMapsLastAdmin409ToLastAdminCase() async throws {
        let service = makeService()
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test/api/user/delete-account")!,
                statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            let msg = "you are the only admin on \"Acme Air\" — transfer admin role or remove other members before deleting your account"
            let body = try! JSONSerialization.data(withJSONObject: ["error": msg])
            return (response, body)
        }

        do {
            _ = try await service.deleteAccount(password: "x", confirmEmail: "user@example.com")
            Issue.record("expected throw")
        } catch let e as DeleteAccountError {
            if case .lastAdmin(let message) = e {
                #expect(message.contains("only admin"))
            } else {
                Issue.record("unexpected case: \(e)")
            }
        }
    }

    @Test
    func deleteAccountMapsAlreadyScheduled409ToAlreadyScheduledCase() async throws {
        let service = makeService()
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test/api/user/delete-account")!,
                statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            let body = #"{"error":"account is already scheduled for deletion"}"#.data(using: .utf8)!
            return (response, body)
        }

        do {
            _ = try await service.deleteAccount(password: "x", confirmEmail: "user@example.com")
            Issue.record("expected throw")
        } catch let e as DeleteAccountError {
            if case .alreadyScheduled = e { /* ok */ }
            else { Issue.record("unexpected case: \(e)") }
        }
    }
}

} // MockURLProtocolSuites

@MainActor
struct AuthServiceFullWipeTests {
    @Test
    func performFullAccountWipeClearsUserDefaultsAndSetsUnauthenticated() async throws {
        let service = AuthService()
        service.authState = .authenticated
        UserDefaults.standard.set("test-user", forKey: "hasPromptedBiometricLogin")
        UserDefaults.standard.set(30, forKey: AppConstants.Cleanup.imageRetentionKey)

        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let accountService = AccountService(
            apiClient: service.apiClient,
            modelContext: container.mainContext
        )

        service.performFullAccountWipe(accountService: accountService)

        #expect(service.authState == .unauthenticated)
        #expect(UserDefaults.standard.object(forKey: "hasPromptedBiometricLogin") == nil)
        #expect(UserDefaults.standard.object(forKey: AppConstants.Cleanup.imageRetentionKey) == nil)
    }
}
