//
//  AccountService.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Foundation
import Observation
import SwiftData

@Observable
class AccountService {
    var accounts: [CachedAccount] = []
    var selectedAccount: CachedAccount?
    var userProfile: UserProfile?
    var isLoading = false
    var loadError: String?

    private let apiClient: APIClient
    private let modelContext: ModelContext

    private static let selectedAccountKey = "selectedAccountId"

    init(apiClient: APIClient, modelContext: ModelContext) {
        self.apiClient = apiClient
        self.modelContext = modelContext
    }

    // MARK: - Seed from Login Response

    func seedAccounts(_ loginAccounts: [LoginAccount], profile: LoginUser?) {
        replaceAccounts(loginAccounts)

        if let profile, let userId = UUID(uuidString: profile.id) {
            userProfile = UserProfile(
                id: userId,
                firstName: profile.firstName,
                lastName: profile.lastName,
                email: profile.email
            )
        }

        restoreSelectedAccount()
    }

    // MARK: - Load Accounts (refresh)

    func loadAccounts() async {
        loadError = nil

        // Skip network fetch if accounts were just seeded from login response
        guard accounts.isEmpty else {
            restoreSelectedAccount()
            return
        }

        let cached = (try? modelContext.fetch(FetchDescriptor<CachedAccount>())) ?? []
        if !cached.isEmpty {
            accounts = cached
            restoreSelectedAccount()
        }

        if cached.isEmpty { isLoading = true }
        defer { isLoading = false }

        do {
            let response: AccountsResponse = try await withTimeout(
                seconds: AppConstants.Sync.networkQueryTimeoutSeconds
            ) { [apiClient] in
                try await apiClient.get(AppConstants.WebAPI.accounts)
            }
            replaceAccounts(response.accounts)
        } catch {
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

    /// Refresh accounts from network (for pull-to-refresh after initial load)
    func refreshAccounts() async {
        loadError = nil
        do {
            let response: AccountsResponse = try await withTimeout(
                seconds: AppConstants.Sync.networkQueryTimeoutSeconds
            ) { [apiClient] in
                try await apiClient.get(AppConstants.WebAPI.accounts)
            }
            replaceAccounts(response.accounts)
        } catch {
            // Silently ignore — we already have accounts
        }
        restoreSelectedAccount()
    }

    private func replaceAccounts(_ loginAccounts: [LoginAccount]) {
        let existing = (try? modelContext.fetch(FetchDescriptor<CachedAccount>())) ?? []
        for account in existing { modelContext.delete(account) }

        var newAccounts: [CachedAccount] = []
        for item in loginAccounts {
            guard let id = UUID(uuidString: item.id) else { continue }
            let cached = CachedAccount(
                id: id,
                name: item.name,
                role: item.role,
                isDefault: item.isDefault
            )
            modelContext.insert(cached)
            newAccounts.append(cached)
        }
        try? modelContext.save()
        accounts = newAccounts
    }

    // MARK: - Account Selection

    func selectAccount(_ account: CachedAccount) {
        selectedAccount = account
        apiClient.accountId = account.id
        UserDefaults.standard.set(account.id.uuidString, forKey: Self.selectedAccountKey)
    }

    private func restoreSelectedAccount() {
        if let savedId = UserDefaults.standard.string(forKey: Self.selectedAccountKey),
           let uuid = UUID(uuidString: savedId),
           let match = accounts.first(where: { $0.id == uuid }) {
            selectAccount(match)
            return
        }
        if let defaultAccount = accounts.first(where: { $0.isDefault }) {
            selectAccount(defaultAccount)
            return
        }
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
        apiClient.accountId = nil
        UserDefaults.standard.removeObject(forKey: Self.selectedAccountKey)
    }
}

// MARK: - DTOs

private struct AccountsResponse: Decodable {
    let accounts: [LoginAccount]
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
