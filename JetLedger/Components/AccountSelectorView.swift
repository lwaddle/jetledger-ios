//
//  AccountSelectorView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct AccountSelectorView: View {
    @Environment(AccountService.self) private var accountService

    var body: some View {
        if accountService.accounts.count <= 1 {
            // Single account — static label
            if let account = accountService.selectedAccount {
                Text(account.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        } else {
            // Multiple accounts — system Picker uses native UIMenu under the
            // hood and avoids the per-item UIHostingController reparenting
            // warnings emitted by SwiftUI Menu with custom Button labels.
            Picker(selection: selectionBinding) {
                ForEach(accountService.accounts, id: \.id) { account in
                    Text(account.name).tag(Optional(account.id))
                }
            } label: {
                Text(accountService.selectedAccount?.name ?? "Select Account")
            }
            .pickerStyle(.menu)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
        }
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { accountService.selectedAccount?.id },
            set: { newId in
                guard let newId,
                      let account = accountService.accounts.first(where: { $0.id == newId })
                else { return }
                accountService.selectAccount(account)
            }
        )
    }
}
