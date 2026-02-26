//
//  SettingsView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AuthService.self) private var authService
    @Environment(AccountService.self) private var accountService
    @Environment(\.dismiss) private var dismiss

    @AppStorage("defaultEnhancementMode") private var defaultEnhancementMode = EnhancementMode.auto.rawValue
    @AppStorage(AppConstants.Cleanup.imageRetentionKey) private var imageRetentionDays = AppConstants.Cleanup.defaultImageRetentionDays

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

                // MARK: Sign Out
                Section {
                    Button("Sign Out", role: .destructive) {
                        Task { await signOut() }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func signOut() async {
        accountService.clearAllData()
        await authService.signOut()
    }
}
