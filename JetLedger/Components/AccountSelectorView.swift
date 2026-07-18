//
//  AccountSelectorView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct AccountSelectorView: View {
    @Environment(AccountService.self) private var accountService
    @State private var showSwitcher = false

    var body: some View {
        // Single-account users get no control at all — a switcher with nothing
        // to switch to is a dead button. Their organization is shown in
        // Settings instead. (The toolbar renders leading items as compact
        // circular buttons, so a full name would clip anyway; for switchers we
        // lean into the circle with an initials avatar and put the full names
        // in the switcher sheet.)
        if accountService.accounts.count > 1,
           let account = accountService.selectedAccount {
            // A sheet, not a Menu: UIMenu caps its own width and wraps long
            // org names onto two lines with no API to widen it. Sheet rows
            // span the screen, so names stay on one line at any length.
            Button {
                showSwitcher = true
            } label: {
                avatarLabel(for: account.name)
            }
            .accessibilityLabel("Account: \(account.name)")
            .sheet(isPresented: $showSwitcher) {
                AccountSwitcherSheet()
            }
        }
    }

    /// Filled accent circle + chevron: the fill separates the control from the
    /// (also circular, also neutral) glass toolbar chrome, and the chevron
    /// marks it as a switcher rather than a profile view. The avatar fill is
    /// BrandPrimary (navy in both modes) so the white initials stay readable;
    /// the dark-mode accent is a bright tint blue that would fail under them.
    @ViewBuilder
    private func avatarLabel(for name: String) -> some View {
        let initials = Self.initials(for: name)
        HStack(spacing: 3) {
            if initials.isEmpty {
                // It's an organization, not a person — building beats person
                // when we can't derive initials.
                Image(systemName: "building.2.crop.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(initials)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color(.brandPrimary), in: Circle())
            }
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
    }

    /// First letter of the first two words, uppercased — "Acme Air" → "AA",
    /// "American Medical Concepts" → "AM". Two characters is the standard
    /// avatar convention and the most that fits the circle at accessibility
    /// text sizes; identically-initialed accounts are disambiguated by the
    /// full names in the menu.
    static func initials(for name: String) -> String {
        name.split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }

}

/// Compact account-switcher sheet: one row per account, checkmark on the
/// current one. Medium detent keeps it a quick switch rather than a full-screen
/// context change; the list scrolls if accounts ever outgrow it.
private struct AccountSwitcherSheet: View {
    @Environment(AccountService.self) private var accountService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(accountService.accounts, id: \.id) { account in
                let isSelected = account.id == accountService.selectedAccount?.id
                Button {
                    if !isSelected {
                        accountService.selectAccount(account)
                    }
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let role = account.accountRole {
                                Text(role.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            .navigationTitle("Switch Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
