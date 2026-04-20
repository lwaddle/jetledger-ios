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

            // Clear existing cache for this account, preserving pending sync refs
            let existing = try modelContext.fetch(FetchDescriptor<CachedTripReference>())
            var pendingRefs: [CachedTripReference] = []
            for ref in existing where ref.accountId == accountId {
                if ref.isPendingSync {
                    pendingRefs.append(ref)
                } else {
                    modelContext.delete(ref)
                }
            }

            var cached: [CachedTripReference] = []
            let serverIds = Set(response.tripReferences.map(\.id))
            for item in response.tripReferences {
                if let pendingIdx = pendingRefs.firstIndex(where: { $0.id == item.id }) {
                    modelContext.delete(pendingRefs[pendingIdx])
                    pendingRefs.remove(at: pendingIdx)
                }

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

            for pending in pendingRefs where !serverIds.contains(pending.id) {
                cached.append(pending)
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

    // MARK: - Create (offline-capable)

    func createTripReferenceLocally(
        accountId: UUID,
        externalId: String?,
        name: String?
    ) async throws -> CachedTripReference {
        let trimmedExtId = externalId?.trimmingCharacters(in: .whitespaces).strippingHTMLTags
        let trimmedName = name?.trimmingCharacters(in: .whitespaces).strippingHTMLTags

        guard !(trimmedExtId ?? "").isEmpty || !(trimmedName ?? "").isEmpty else {
            throw TripReferenceError.validationFailed("Trip ID or name is required.")
        }

        // Check for local duplicates
        let accountRefs = tripReferences.filter { $0.accountId == accountId }
        if let extId = trimmedExtId, !extId.isEmpty,
           accountRefs.contains(where: { $0.externalId?.lowercased() == extId.lowercased() }) {
            throw TripReferenceError.duplicate("A trip reference with ID \"\(extId)\" already exists.")
        }
        if let n = trimmedName, !n.isEmpty, (trimmedExtId ?? "").isEmpty,
           accountRefs.contains(where: { $0.name?.lowercased() == n.lowercased() }) {
            throw TripReferenceError.duplicate("A trip reference with name \"\(n)\" already exists.")
        }

        // If online, try to create directly on the server
        if networkMonitor.isConnected {
            do {
                let request = TripReferenceBody(
                    externalId: trimmedExtId?.isEmpty == true ? nil : trimmedExtId,
                    name: trimmedName?.isEmpty == true ? nil : trimmedName
                )

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
                throw TripReferenceError.duplicate("This trip reference already exists on the server.")
            } catch {
                Self.logger.warning("Online create failed, falling back to offline: \(error.localizedDescription)")
            }
        }

        // Offline: create locally with pending flag
        let localRef = CachedTripReference(
            id: UUID(),
            accountId: accountId,
            externalId: trimmedExtId?.isEmpty == true ? nil : trimmedExtId,
            name: trimmedName?.isEmpty == true ? nil : trimmedName,
            createdAt: Date()
        )
        localRef.isPendingSync = true
        modelContext.insert(localRef)
        try? modelContext.save()
        tripReferences.insert(localRef, at: 0)
        return localRef
    }

    // MARK: - Sync Pending Trip References

    func syncPendingTripReferences() async {
        guard networkMonitor.isConnected else { return }

        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
        let pending = allCached.filter { $0.isPendingSync }
        guard !pending.isEmpty else { return }

        for ref in pending {
            await syncSingleTripReference(ref)
        }
    }

    private func syncSingleTripReference(_ ref: CachedTripReference) async {
        let request = TripReferenceBody(
            externalId: ref.externalId,
            name: ref.name
        )

        do {
            let response: TripReferenceDTO = try await apiClient.request(
                .post, AppConstants.WebAPI.tripReferences,
                body: request
            )

            if response.id != ref.id {
                relinkReceipts(from: ref.id, to: response.id, externalId: response.externalId, name: response.name)
                modelContext.delete(ref)
                let serverRef = CachedTripReference(
                    id: response.id,
                    accountId: ref.accountId,
                    externalId: response.externalId,
                    name: response.name,
                    createdAt: response.createdAt
                )
                modelContext.insert(serverRef)
                if let idx = tripReferences.firstIndex(where: { $0.id == ref.id }) {
                    tripReferences[idx] = serverRef
                }
            } else {
                ref.isPendingSync = false
            }

            try? modelContext.save()
            Self.logger.info("Synced trip reference: \(ref.externalId ?? ref.name ?? "unknown")")
        } catch let error as APIError where error == .conflict {
            Self.logger.info("Unique conflict for trip reference: \(ref.externalId ?? ref.name ?? "unknown")")
            await handleUniqueConflict(localRef: ref)
        } catch {
            Self.logger.warning("Failed to sync trip reference \(ref.id): \(error.localizedDescription)")
        }
    }

    private func handleUniqueConflict(localRef: CachedTripReference) async {
        do {
            // Search in-memory first before making a network call
            let inMemoryMatch: CachedTripReference?
            if let extId = localRef.externalId, !extId.isEmpty {
                inMemoryMatch = tripReferences.first {
                    $0.id != localRef.id && $0.externalId?.lowercased() == extId.lowercased()
                }
            } else if let name = localRef.name {
                inMemoryMatch = tripReferences.first {
                    $0.id != localRef.id && $0.name?.lowercased() == name.lowercased()
                }
            } else {
                inMemoryMatch = nil
            }

            if let cached = inMemoryMatch {
                relinkReceipts(from: localRef.id, to: cached.id, externalId: cached.externalId, name: cached.name)
                modelContext.delete(localRef)
                tripReferences.removeAll { $0.id == localRef.id }
                try? modelContext.save()
                Self.logger.info("Resolved conflict from cache: local \(localRef.id) → \(cached.id)")
                return
            }

            // Fall back to network fetch if not found in memory
            let response: TripReferencesResponse = try await apiClient.get(
                AppConstants.WebAPI.tripReferences
            )

            let serverRecord: TripReferenceDTO?
            if let extId = localRef.externalId, !extId.isEmpty {
                serverRecord = response.tripReferences.first {
                    $0.externalId?.lowercased() == extId.lowercased()
                }
            } else if let name = localRef.name {
                serverRecord = response.tripReferences.first {
                    $0.name?.lowercased() == name.lowercased()
                }
            } else {
                serverRecord = nil
            }

            guard let match = serverRecord else {
                Self.logger.warning("Conflict detected but server record not found — deleting local ref \(localRef.id)")
                modelContext.delete(localRef)
                tripReferences.removeAll { $0.id == localRef.id }
                try? modelContext.save()
                return
            }

            relinkReceipts(from: localRef.id, to: match.id, externalId: match.externalId, name: match.name)
            modelContext.delete(localRef)

            let accountId = localRef.accountId
            let serverRef = CachedTripReference(
                id: match.id,
                accountId: accountId,
                externalId: match.externalId,
                name: match.name,
                createdAt: match.createdAt
            )
            modelContext.insert(serverRef)
            if let idx = tripReferences.firstIndex(where: { $0.id == localRef.id }) {
                tripReferences[idx] = serverRef
            }

            try? modelContext.save()
            Self.logger.info("Resolved conflict: local \(localRef.id) → server \(match.id)")
        } catch {
            Self.logger.warning("Failed to resolve conflict for \(localRef.id): \(error.localizedDescription)")
        }
    }

    private func relinkReceipts(from localId: UUID, to serverId: UUID, externalId: String?, name: String?) {
        guard let allReceipts = try? modelContext.fetch(FetchDescriptor<LocalReceipt>()) else { return }
        for receipt in allReceipts where receipt.tripReferenceId == localId {
            receipt.tripReferenceId = serverId
            receipt.tripReferenceExternalId = externalId
            receipt.tripReferenceName = name
        }
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

        let pendingIds = Set(allCached.filter(\.isPendingSync).map(\.id))
        if !pendingIds.isEmpty {
            let allReceipts = (try? modelContext.fetch(FetchDescriptor<LocalReceipt>())) ?? []
            for receipt in allReceipts {
                if let tripId = receipt.tripReferenceId, pendingIds.contains(tripId) {
                    receipt.tripReferenceId = nil
                    receipt.tripReferenceExternalId = nil
                    receipt.tripReferenceName = nil
                }
            }
        }

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

// MARK: - Errors

enum TripReferenceError: LocalizedError {
    case validationFailed(String)
    case duplicate(String)
    case offline
    case conflictWithExisting(CachedTripReference)

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
