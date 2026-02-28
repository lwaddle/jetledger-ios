//
//  SettingsView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct SettingsView: View {
    var isOfflineMode: Bool = false

    @Environment(AuthService.self) private var authService
    @Environment(AccountService.self) private var accountService
    @Environment(\.dismiss) private var dismiss

    @AppStorage("defaultEnhancementMode") private var defaultEnhancementMode = EnhancementMode.auto.rawValue
    @AppStorage(AppConstants.Cleanup.imageRetentionKey) private var imageRetentionDays = AppConstants.Cleanup.defaultImageRetentionDays

    @State private var showClearDataConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: Account
                Section("Account") {
                    if let profile = accountService.userProfile {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.displayName)
                                .font(.body)
                            Text(profile.email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    } else {
                        Text("Profile unavailable")
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: Capture
                Section("Capture") {
                    Picker("Default Enhancement", selection: $defaultEnhancementMode) {
                        ForEach(EnhancementMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                }

                // MARK: Storage
                Section("Storage") {
                    Picker("Keep Completed Images", selection: $imageRetentionDays) {
                        Text("1 week").tag(7)
                        Text("2 weeks").tag(14)
                        Text("1 month").tag(30)
                        Text("3 months").tag(90)
                    }
                }

                // MARK: App
                Section("App") {
                    NavigationLink {
                        AboutView()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("About JetLedger")
                            Text(Bundle.main.versionString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: Sign Out / Sign In
                Section {
                    if isOfflineMode {
                        Button("Sign In") {
                            authService.authState = .unauthenticated
                            dismiss()
                        }
                    } else {
                        Button("Sign Out", role: .destructive) {
                            Task { await signOut() }
                        }
                    }
                }

                // MARK: Clear Device Data
                Section {
                    Button("Clear Device Data", role: .destructive) {
                        showClearDataConfirmation = true
                    }
                } footer: {
                    Text("Removes all receipts, cached data, and your offline identity from this device.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Clear Device Data?", isPresented: $showClearDataConfirmation) {
                Button("Clear All Data", role: .destructive) {
                    clearDeviceData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all receipts, cached data, and your offline identity from this device. This cannot be undone.")
            }
        }
    }

    private func signOut() async {
        // Save offline identity before clearing session
        if let account = accountService.selectedAccount,
           let userId = authService.currentUserId {
            let identity = OfflineIdentity(
                userId: userId,
                email: accountService.userProfile?.email ?? "",
                accountId: account.id,
                accountName: account.name,
                role: account.role
            )
            OfflineIdentity.save(identity)
        }
        await authService.signOutRetainingIdentity()
    }

    private func clearDeviceData() {
        OfflineIdentity.clear()
        accountService.clearAllData()
        Task { await authService.signOut() }
        dismiss()
    }
}
