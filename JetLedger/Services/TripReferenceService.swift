//
//  TripReferenceService.swift
//  JetLedger
//

import Foundation
import Observation
import Supabase
import SwiftData

@Observable
class TripReferenceService {
    var tripReferences: [CachedTripReference] = []
    var isLoading = false

    private let supabase: SupabaseClient
    private let modelContext: ModelContext

    init(supabase: SupabaseClient, modelContext: ModelContext) {
        self.supabase = supabase
        self.modelContext = modelContext
    }

    // MARK: - Load

    func loadTripReferences(for accountId: UUID) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let response: [TripReferenceResponse] = try await supabase
                .from("trip_references")
                .select("id, account_id, external_id, name")
                .eq("account_id", value: accountId.uuidString)
                .order("external_id", ascending: false)
                .execute()
                .value

            // Clear existing cache for this account
            let existing = try modelContext.fetch(FetchDescriptor<CachedTripReference>())
            for ref in existing where ref.accountId == accountId {
                modelContext.delete(ref)
            }

            // Cache new references
            var cached: [CachedTripReference] = []
            for item in response {
                let ref = CachedTripReference(
                    id: item.id,
                    accountId: item.accountId,
                    externalId: item.externalId,
                    name: item.name
                )
                modelContext.insert(ref)
                cached.append(ref)
            }

            try modelContext.save()
            tripReferences = cached
        } catch {
            // Fall back to cached data
            let allCached = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
            tripReferences = allCached.filter { $0.accountId == accountId }
        }
    }

    // MARK: - Search (in-memory, works offline)

    func search(_ query: String, for accountId: UUID) -> [CachedTripReference] {
        guard !query.isEmpty else {
            return tripReferences.filter { $0.accountId == accountId }
        }
        let lowered = query.lowercased()
        return tripReferences.filter { ref in
            ref.accountId == accountId &&
            (ref.externalId.lowercased().contains(lowered) ||
             (ref.name?.lowercased().contains(lowered) ?? false))
        }
    }

    // MARK: - Create

    func createTripReference(
        accountId: UUID,
        externalId: String,
        name: String?
    ) async throws -> CachedTripReference {
        let request = CreateTripReferenceRequest(
            accountId: accountId,
            externalId: externalId,
            name: name
        )

        let response: TripReferenceResponse = try await supabase
            .from("trip_references")
            .insert(request)
            .select("id, account_id, external_id, name")
            .single()
            .execute()
            .value

        let cached = CachedTripReference(
            id: response.id,
            accountId: response.accountId,
            externalId: response.externalId,
            name: response.name
        )
        modelContext.insert(cached)
        try? modelContext.save()
        tripReferences.append(cached)

        return cached
    }

    // MARK: - Cleanup

    func clearCache() {
        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
        for ref in allCached {
            modelContext.delete(ref)
        }
        try? modelContext.save()
        tripReferences = []
    }
}

// MARK: - DTOs

private struct TripReferenceResponse: Decodable {
    let id: UUID
    let accountId: UUID
    let externalId: String
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case accountId = "account_id"
        case externalId = "external_id"
    }
}

private struct CreateTripReferenceRequest: Encodable {
    let accountId: UUID
    let externalId: String
    let name: String?

    enum CodingKeys: String, CodingKey {
        case name
        case accountId = "account_id"
        case externalId = "external_id"
    }
}
