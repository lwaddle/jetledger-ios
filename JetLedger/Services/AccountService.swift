//
//  AccountService.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Foundation
import Observation
import Supabase
import SwiftData

@Observable
class AccountService {
    var accounts: [CachedAccount] = []
    var selectedAccount: CachedAccount?
    var userProfile: UserProfile?
    var isLoading = false
    var loadError: String?

    private let supabase: SupabaseClient
    private let modelContext: ModelContext

    private static let selectedAccountKey = "selectedAccountId"

    init(supabase: SupabaseClient, modelContext: ModelContext) {
        self.supabase = supabase
        self.modelContext = modelContext
    }

    // MARK: - Load Accounts

    func loadAccounts() async {
        guard let userId = supabase.auth.currentSession?.user.id else { return }
        loadError = nil

        // 1. Load from SwiftData cache first (instant)
        let cached = (try? modelContext.fetch(FetchDescriptor<CachedAccount>())) ?? []
        if !cached.isEmpty {
            accounts = cached
            restoreSelectedAccount()
        }

        // 2. Show loading spinner only if no cache exists
        if cached.isEmpty {
            isLoading = true
        }
        defer { isLoading = false }

        // 3. Refresh from network (with timeout)
        do {
            let response: [UserAccountResponse] = try await withTimeout(
                seconds: AppConstants.Sync.networkQueryTimeoutSeconds
            ) { [supabase] in
                try await supabase
                    .from("user_accounts")
                    .select("id, role, is_default, account:accounts(id, name)")
                    .eq("user_id", value: userId.uuidString)
                    .execute()
                    .value
            }

            // Clear existing cached accounts
            let existing = try modelContext.fetch(FetchDescriptor<CachedAccount>())
            for account in existing {
                modelContext.delete(account)
            }

            // Cache new accounts
            var newAccounts: [CachedAccount] = []
            for item in response {
                let cachedAccount = CachedAccount(
                    id: item.account.id,
                    name: item.account.name,
                    role: item.role,
                    isDefault: item.isDefault
                )
                modelContext.insert(cachedAccount)
                newAccounts.append(cachedAccount)
            }

            try modelContext.save()
            accounts = newAccounts
        } catch {
            // If we already have cached accounts, silently ignore the error
            if accounts.isEmpty {
                let fallback = (try? modelContext.fetch(FetchDescriptor<CachedAccount>())) ?? []
                accounts = fallback
                if fallback.isEmpty {
                    loadError = "Failed to load accounts. Check your connection and try again."
                }
            }
        }

        restoreSelectedAccount()
    }

    // MARK: - Load Profile

    func loadProfile() async {
        guard let userId = supabase.auth.currentSession?.user.id else { return }

        do {
            let profile: UserProfile = try await withTimeout(
                seconds: AppConstants.Sync.networkQueryTimeoutSeconds
            ) { [supabase] in
                try await supabase
                    .from("profiles")
                    .select("id, first_name, last_name, email")
                    .eq("id", value: userId.uuidString)
                    .single()
                    .execute()
                    .value
            }

            userProfile = profile
        } catch {
            // Profile is non-critical; leave nil
        }
    }

    // MARK: - Account Selection

    func selectAccount(_ account: CachedAccount) {
        selectedAccount = account
        UserDefaults.standard.set(account.id.uuidString, forKey: Self.selectedAccountKey)
    }

    private func restoreSelectedAccount() {
        // Try to restore previously selected account
        if let savedId = UserDefaults.standard.string(forKey: Self.selectedAccountKey),
           let uuid = UUID(uuidString: savedId),
           let match = accounts.first(where: { $0.id == uuid }) {
            selectedAccount = match
            return
        }

        // Fall back to default account
        if let defaultAccount = accounts.first(where: { $0.isDefault }) {
            selectAccount(defaultAccount)
            return
        }

        // Fall back to first account
        if let first = accounts.first {
            selectAccount(first)
        }
    }

    // MARK: - Offline / Cache-Only Loading

    func loadAccountsFromCache() {
        let cached = (try? modelContext.fetch(FetchDescriptor<CachedAccount>())) ?? []
        accounts = cached
        restoreSelectedAccount()
    }

    func loadOfflineProfile(from identity: OfflineIdentity) {
        userProfile = UserProfile(
            id: identity.userId,
            firstName: nil,
            lastName: nil,
            email: identity.email
        )
    }

    // MARK: - Cleanup

    func clearAllData() {
        let accountFetch = FetchDescriptor<CachedAccount>()
        let tripFetch = FetchDescriptor<CachedTripReference>()
        let receiptFetch = FetchDescriptor<LocalReceipt>()

        if let items = try? modelContext.fetch(accountFetch) {
            for item in items { modelContext.delete(item) }
        }
        if let items = try? modelContext.fetch(tripFetch) {
            for item in items { modelContext.delete(item) }
        }
        if let receipts = try? modelContext.fetch(receiptFetch) {
            for receipt in receipts {
                ImageUtils.deleteReceiptImages(receiptId: receipt.id)
                modelContext.delete(receipt)
            }
        }

        try? modelContext.save()

        accounts = []
        selectedAccount = nil
        userProfile = nil
        UserDefaults.standard.removeObject(forKey: Self.selectedAccountKey)
    }
}

// MARK: - DTOs

struct UserAccountResponse: Decodable {
    let id: UUID
    let role: String
    let isDefault: Bool
    let account: AccountInfo

    enum CodingKeys: String, CodingKey {
        case id, role, account
        case isDefault = "is_default"
    }

    struct AccountInfo: Decodable {
        let id: UUID
        let name: String
    }
}

struct UserProfile: Decodable {
    let id: UUID
    let firstName: String?
    let lastName: String?
    let email: String

    enum CodingKeys: String, CodingKey {
        case id, email
        case firstName = "first_name"
        case lastName = "last_name"
    }

    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0 }
        return parts.isEmpty ? email : parts.joined(separator: " ")
    }
}
