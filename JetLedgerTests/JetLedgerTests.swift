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
}
