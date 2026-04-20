//
//  TripReferenceService.swift
//  JetLedger
//

import Foundation
import Observation
import OSLog
import SwiftData

@Observable
class TripReferenceService {
    var tripReferences: [CachedTripReference] = []
    var isLoading = false

    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "TripReferenceService")
    private let apiClient: APIClient
    private let modelContext: ModelContext
    private let networkMonitor: NetworkMonitor

    init(apiClient: APIClient, modelContext: ModelContext, networkMonitor: NetworkMonitor) {
        self.apiClient = apiClient
        self.modelContext = modelContext
        self.networkMonitor = networkMonitor
    }

    // MARK: - Load

    func loadTripReferences(for accountId: UUID) async {
        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
        let cachedForAccount = allCached.filter { $0.accountId == accountId }
        if !cachedForAccount.isEmpty {
            tripReferences = cachedForAccount
        }

        if cachedForAccount.isEmpty { isLoading = true }
        defer { isLoading = false }

        do {
            let response: TripReferencesResponse = try await withTimeout(
                seconds: AppConstants.Sync.networkQueryTimeoutSeconds
            ) { [apiClient] in
                try await apiClient.get(AppConstants.WebAPI.tripReferences)
            }

            // One-time migration: unlink and delete orphaned legacy pending refs
            let serverIds = Set(response.tripReferences.map(\.id))
            let existing = try modelContext.fetch(FetchDescriptor<CachedTripReference>())
            for ref in existing where ref.accountId == accountId {
                if ref.isPendingSync && !serverIds.contains(ref.id) {
                    unlinkReceiptsFromTripReference(ref.id)
                }
                modelContext.delete(ref)
            }

            var cached: [CachedTripReference] = []
            for item in response.tripReferences {
                let ref = CachedTripReference(
                    id: item.id,
                    accountId: accountId,
                    externalId: item.externalId,
                    name: item.name,
                    createdAt: item.createdAt
                )
                modelContext.insert(ref)
                cached.append(ref)
            }

            try modelContext.save()
            tripReferences = cached
        } catch {
            if tripReferences.isEmpty {
                let fallback = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
                tripReferences = fallback.filter { $0.accountId == accountId }
            }
        }
    }

    private func unlinkReceiptsFromTripReference(_ tripRefId: UUID) {
        guard let allReceipts = try? modelContext.fetch(FetchDescriptor<LocalReceipt>()) else { return }
        for receipt in allReceipts where receipt.tripReferenceId == tripRefId {
            receipt.tripReferenceId = nil
            receipt.tripReferenceExternalId = nil
            receipt.tripReferenceName = nil
        }
    }

    // MARK: - Search (in-memory, works offline)

    func search(_ query: String, for accountId: UUID) -> [CachedTripReference] {
        guard !query.isEmpty else {
            return tripReferences.filter { $0.accountId == accountId }
        }
        let lowered = query.lowercased()
        return tripReferences.filter { ref in
            ref.accountId == accountId
                && ((ref.externalId?.lowercased().contains(lowered) ?? false)
                    || (ref.name?.lowercased().contains(lowered) ?? false))
        }
    }

    // MARK: - Create (online-only)

    func createTripReference(
        accountId: UUID,
        externalId: String?,
        name: String?
    ) async throws -> CachedTripReference {
        let trimmedExtId = externalId?.trimmingCharacters(in: .whitespaces).strippingHTMLTags
        let trimmedName = name?.trimmingCharacters(in: .whitespaces).strippingHTMLTags

        guard !(trimmedExtId ?? "").isEmpty || !(trimmedName ?? "").isEmpty else {
            throw TripReferenceError.validationFailed("Trip ID or name is required.")
        }

        guard networkMonitor.isConnected else {
            throw TripReferenceError.offline
        }

        let accountRefs = tripReferences.filter { $0.accountId == accountId }
        if let extId = trimmedExtId, !extId.isEmpty,
           let existing = accountRefs.first(where: { $0.externalId?.lowercased() == extId.lowercased() }) {
            throw TripReferenceError.conflictWithExisting(TripReferenceSummary(from: existing))
        }
        if let n = trimmedName, !n.isEmpty, (trimmedExtId ?? "").isEmpty,
           let existing = accountRefs.first(where: { $0.name?.lowercased() == n.lowercased() }) {
            throw TripReferenceError.conflictWithExisting(TripReferenceSummary(from: existing))
        }

        let request = TripReferenceBody(
            externalId: trimmedExtId?.isEmpty == true ? nil : trimmedExtId,
            name: trimmedName?.isEmpty == true ? nil : trimmedName
        )

        do {
            let response: TripReferenceDTO = try await withTimeout(seconds: 5) { [apiClient] in
                try await apiClient.request(
                    .post, AppConstants.WebAPI.tripReferences,
                    body: request
                )
            }

            let cached = CachedTripReference(
                id: response.id,
                accountId: accountId,
                externalId: response.externalId,
                name: response.name,
                createdAt: response.createdAt
            )
            modelContext.insert(cached)
            try? modelContext.save()
            tripReferences.insert(cached, at: 0)
            return cached
        } catch let error as APIError where error == .conflict {
            let existing = await findExistingConflict(
                accountId: accountId,
                externalId: trimmedExtId,
                name: trimmedName
            )
            if let existing {
                throw TripReferenceError.conflictWithExisting(TripReferenceSummary(from: existing))
            }
            throw TripReferenceError.duplicate("This trip reference already exists but could not be loaded. Try again.")
        }
    }

    private func findExistingConflict(
        accountId: UUID,
        externalId: String?,
        name: String?
    ) async -> CachedTripReference? {
        await loadTripReferences(for: accountId)
        let accountRefs = tripReferences.filter { $0.accountId == accountId }

        if let extId = externalId, !extId.isEmpty {
            return accountRefs.first { $0.externalId?.lowercased() == extId.lowercased() }
        }
        if let n = name, !n.isEmpty {
            return accountRefs.first { $0.name?.lowercased() == n.lowercased() }
        }
        return nil
    }

    // MARK: - Update

    func updateTripReference(
        id: UUID,
        externalId: String?,
        name: String?
    ) async throws -> CachedTripReference {
        let request = TripReferenceBody(externalId: externalId, name: name)

        let response: TripReferenceDTO = try await apiClient.request(
            .put, "\(AppConstants.WebAPI.tripReferences)/\(id.uuidString)",
            body: request
        )

        if let existing = tripReferences.first(where: { $0.id == id }) {
            existing.externalId = response.externalId
            existing.name = response.name
            try? modelContext.save()
            return existing
        }

        let accountId = tripReferences.first?.accountId ?? UUID()
        let cached = CachedTripReference(
            id: response.id,
            accountId: accountId,
            externalId: response.externalId,
            name: response.name,
            createdAt: response.createdAt
        )
        modelContext.insert(cached)
        try? modelContext.save()
        tripReferences.insert(cached, at: 0)
        return cached
    }

    func propagateTripReferenceUpdate(id: UUID, externalId: String?, name: String?) {
        guard let allReceipts = try? modelContext.fetch(FetchDescriptor<LocalReceipt>()) else { return }
        for receipt in allReceipts where receipt.tripReferenceId == id {
            receipt.tripReferenceExternalId = externalId
            receipt.tripReferenceName = name
        }
        try? modelContext.save()
    }

    // MARK: - Cleanup

    func clearCache() {
        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
        for ref in allCached { modelContext.delete(ref) }
        try? modelContext.save()
        tripReferences = []
    }
}

// MARK: - DTOs

nonisolated struct TripReferencesResponse: Decodable {
    let tripReferences: [TripReferenceDTO]

    enum CodingKeys: String, CodingKey {
        case tripReferences = "trip_references"
    }
}

nonisolated struct TripReferenceDTO: Decodable {
    let id: UUID
    let externalId: String?
    let name: String?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case externalId = "external_id"
        case createdAt = "created_at"
    }
}

private struct TripReferenceBody: Encodable {
    let externalId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case name
        case externalId = "external_id"
    }
}

// MARK: - Error Payloads

nonisolated struct TripReferenceSummary: Sendable, Equatable {
    let id: UUID
    let displayTitle: String
    let externalId: String?
    let name: String?

    init(from ref: CachedTripReference) {
        self.id = ref.id
        self.displayTitle = ref.displayTitle
        self.externalId = ref.externalId
        self.name = ref.name
    }
}

// MARK: - Errors

enum TripReferenceError: LocalizedError {
    case validationFailed(String)
    case duplicate(String)
    case offline
    case conflictWithExisting(TripReferenceSummary)

    var errorDescription: String? {
        switch self {
        case .validationFailed(let message), .duplicate(let message):
            message
        case .offline:
            "Connect to the internet to create a new trip reference."
        case .conflictWithExisting(let ref):
            "A trip reference with this ID or name already exists: \(ref.displayTitle)."
        }
    }
}
