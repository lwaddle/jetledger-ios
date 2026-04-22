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

@MainActor
struct APIClientRawRequestTests {
    @Test
    func performRawRequestReturns401WithoutInvokingOnUnauthorized() async throws {
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
