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

    @AppStorage("defaultEnhancementMode") private var defaultEnhancementMode = EnhancementMode.auto.rawValue

    var body: some View {
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

            // MARK: App
            Section("App") {
                NavigationLink {
                    AboutView()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("About JetLedger")
                        Text(versionString)
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
    }

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    private func signOut() async {
        accountService.clearAllData()
        await authService.signOut()
    }
}
