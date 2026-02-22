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
            }
        } else {
            // Multiple accounts — dropdown menu
            Menu {
                ForEach(accountService.accounts, id: \.id) { account in
                    Button {
                        accountService.selectAccount(account)
                    } label: {
                        HStack {
                            Text(account.name)
                            if account.id == accountService.selectedAccount?.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(accountService.selectedAccount?.name ?? "Select Account")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.primary)
            }
        }
    }
}
