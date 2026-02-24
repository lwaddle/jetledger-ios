//
//  TripReferenceService.swift
//  JetLedger
//

import Foundation
import Observation
import OSLog
import PostgREST
import Supabase
import SwiftData

@Observable
class TripReferenceService {
    var tripReferences: [CachedTripReference] = []
    var isLoading = false

    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "TripReferenceService")
    private let supabase: SupabaseClient
    private let modelContext: ModelContext
    private let networkMonitor: NetworkMonitor

    init(supabase: SupabaseClient, modelContext: ModelContext, networkMonitor: NetworkMonitor) {
        self.supabase = supabase
        self.modelContext = modelContext
        self.networkMonitor = networkMonitor
    }

    // MARK: - Load

    func loadTripReferences(for accountId: UUID) async {
        // 1. Load from SwiftData cache first (instant)
        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
        let cachedForAccount = allCached.filter { $0.accountId == accountId }
        if !cachedForAccount.isEmpty {
            tripReferences = cachedForAccount
        }

        if cachedForAccount.isEmpty {
            isLoading = true
        }
        defer { isLoading = false }

        // 2. Refresh from network (with timeout)
        do {
            let response: [TripReferenceResponse] = try await withTimeout(
                seconds: AppConstants.Sync.networkQueryTimeoutSeconds
            ) { [supabase] in
                try await supabase
                    .from("trip_references")
                    .select("id, account_id, external_id, name, created_at")
                    .eq("account_id", value: accountId.uuidString)
                    .order("created_at", ascending: false)
                    .limit(500)
                    .execute()
                    .value
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

            // Cache new references
            var cached: [CachedTripReference] = []
            let serverIds = Set(response.map(\.id))
            for item in response {
                // If a pending ref was synced server-side (e.g. conflict resolved), remove the local pending copy
                if let pendingIdx = pendingRefs.firstIndex(where: { $0.id == item.id }) {
                    modelContext.delete(pendingRefs[pendingIdx])
                    pendingRefs.remove(at: pendingIdx)
                }

                let ref = CachedTripReference(
                    id: item.id,
                    accountId: item.accountId,
                    externalId: item.externalId,
                    name: item.name,
                    createdAt: item.createdAt
                )
                modelContext.insert(ref)
                cached.append(ref)
            }

            // Append remaining pending refs that aren't on the server yet
            for pending in pendingRefs where !serverIds.contains(pending.id) {
                cached.append(pending)
            }

            try modelContext.save()
            tripReferences = cached
        } catch {
            // If we already have cached data, silently ignore the error
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
            ref.accountId == accountId &&
            ((ref.externalId?.lowercased().contains(lowered) ?? false) ||
             (ref.name?.lowercased().contains(lowered) ?? false))
        }
    }

    // MARK: - Create (offline-capable)

    func createTripReferenceLocally(
        accountId: UUID,
        externalId: String?,
        name: String?
    ) async throws -> CachedTripReference {
        let trimmedExtId = externalId?.trimmingCharacters(in: .whitespaces)
        let trimmedName = name?.trimmingCharacters(in: .whitespaces)

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
                let request = CreateTripReferenceRequest(
                    accountId: accountId,
                    externalId: trimmedExtId?.isEmpty == true ? nil : trimmedExtId,
                    name: trimmedName?.isEmpty == true ? nil : trimmedName
                )

                let response: TripReferenceResponse = try await withTimeout(seconds: 5) { [supabase] in
                    try await supabase
                        .from("trip_references")
                        .insert(request)
                        .select("id, account_id, external_id, name, created_at")
                        .single()
                        .execute()
                        .value
                }

                let cached = CachedTripReference(
                    id: response.id,
                    accountId: response.accountId,
                    externalId: response.externalId,
                    name: response.name,
                    createdAt: response.createdAt
                )
                modelContext.insert(cached)
                try? modelContext.save()
                tripReferences.insert(cached, at: 0)
                return cached
            } catch let error as PostgrestError where error.code == "23505" {
                throw TripReferenceError.duplicate("This trip reference already exists on the server.")
            } catch {
                Self.logger.warning("Online create failed, falling back to offline: \(error.localizedDescription)")
                // Fall through to offline creation below
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
        let request = CreateTripReferenceRequest(
            accountId: ref.accountId,
            externalId: ref.externalId,
            name: ref.name
        )

        do {
            let response: TripReferenceResponse = try await supabase
                .from("trip_references")
                .insert(request)
                .select("id, account_id, external_id, name, created_at")
                .single()
                .execute()
                .value

            // Server assigned the same ID (unlikely) or a new one — either way, update
            if response.id != ref.id {
                // Re-link receipts from local UUID to server UUID
                relinkReceipts(from: ref.id, to: response.id, externalId: response.externalId, name: response.name)

                // Replace local ref with server version
                modelContext.delete(ref)
                let serverRef = CachedTripReference(
                    id: response.id,
                    accountId: response.accountId,
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
        } catch let error as PostgrestError where error.code == "23505" {
            Self.logger.info("Unique conflict for trip reference: \(ref.externalId ?? ref.name ?? "unknown")")
            await handleUniqueConflict(localRef: ref)
        } catch {
            Self.logger.warning("Failed to sync trip reference \(ref.id): \(error.localizedDescription)")
            // Leave pending for next retry
        }
    }

    private func handleUniqueConflict(localRef: CachedTripReference) async {
        do {
            // Find the existing server record
            var query = supabase
                .from("trip_references")
                .select("id, account_id, external_id, name, created_at")
                .eq("account_id", value: localRef.accountId.uuidString)

            if let extId = localRef.externalId, !extId.isEmpty {
                query = query.eq("external_id", value: extId)
            } else if let name = localRef.name {
                query = query.ilike("name", pattern: name)
            }

            let matches: [TripReferenceResponse] = try await query
                .limit(1)
                .execute()
                .value

            guard let serverRecord = matches.first else {
                Self.logger.warning("Conflict detected but server record not found — deleting local ref \(localRef.id)")
                modelContext.delete(localRef)
                tripReferences.removeAll { $0.id == localRef.id }
                try? modelContext.save()
                return
            }

            // Re-link receipts from local UUID to server UUID
            relinkReceipts(from: localRef.id, to: serverRecord.id, externalId: serverRecord.externalId, name: serverRecord.name)

            // Replace local ref with server version
            modelContext.delete(localRef)
            let serverRef = CachedTripReference(
                id: serverRecord.id,
                accountId: serverRecord.accountId,
                externalId: serverRecord.externalId,
                name: serverRecord.name,
                createdAt: serverRecord.createdAt
            )
            modelContext.insert(serverRef)

            if let idx = tripReferences.firstIndex(where: { $0.id == localRef.id }) {
                tripReferences[idx] = serverRef
            }

            try? modelContext.save()
            Self.logger.info("Resolved conflict: local \(localRef.id) → server \(serverRecord.id)")
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
        let request = UpdateTripReferenceRequest(
            externalId: externalId,
            name: name
        )

        let response: TripReferenceResponse = try await supabase
            .from("trip_references")
            .update(request)
            .eq("id", value: id.uuidString)
            .select("id, account_id, external_id, name, created_at")
            .single()
            .execute()
            .value

        // Update in-memory cache
        if let existing = tripReferences.first(where: { $0.id == id }) {
            existing.externalId = response.externalId
            existing.name = response.name
            try? modelContext.save()
            return existing
        }

        // Shouldn't happen, but handle gracefully
        let cached = CachedTripReference(
            id: response.id,
            accountId: response.accountId,
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

        // Clear receipt references to pending trip refs (avoid dangling UUIDs after sign-out)
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

        for ref in allCached {
            modelContext.delete(ref)
        }
        try? modelContext.save()
        tripReferences = []
    }
}

// MARK: - DTOs

private nonisolated struct TripReferenceResponse: Decodable, Sendable {
    let id: UUID
    let accountId: UUID
    let externalId: String?
    let name: String?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case accountId = "account_id"
        case externalId = "external_id"
        case createdAt = "created_at"
    }
}

private struct UpdateTripReferenceRequest: Encodable {
    let externalId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case name
        case externalId = "external_id"
    }
}

private nonisolated struct CreateTripReferenceRequest: Encodable, Sendable {
    let accountId: UUID
    let externalId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case name
        case accountId = "account_id"
        case externalId = "external_id"
    }
}

// MARK: - Errors

enum TripReferenceError: LocalizedError {
    case validationFailed(String)
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .validationFailed(let message), .duplicate(let message):
            message
        }
    }
}
