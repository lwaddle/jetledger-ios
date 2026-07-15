//
//  ImportFlowView.swift
//  JetLedger
//

import SwiftData
import SwiftUI

struct ImportFlowView: View {
    let accountId: UUID
    let urls: [URL]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var coordinator: ImportFlowCoordinator?
    @State private var showSkippedAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if let coordinator {
                    switch coordinator.currentStep {
                    case .preview:
                        ImportPreviewView(coordinator: coordinator)
                    case .metadata:
                        ImportMetadataView(coordinator: coordinator) {
                            dismiss()
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                if coordinator?.currentStep != .metadata {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .onAppear {
            if coordinator == nil {
                let c = ImportFlowCoordinator(
                    accountId: accountId,
                    modelContext: modelContext
                )
                c.handleImportedURLs(urls)
                coordinator = c
                // Some or all picked files may have been dropped (oversized,
                // unreadable, unsupported). Tell the user which and why —
                // silently dismissing looked like a successful import.
                if c.skippedFilesMessage != nil {
                    showSkippedAlert = true
                }
            }
        }
        .alert(
            coordinator?.files.isEmpty == true ? "Nothing Imported" : "Some Files Skipped",
            isPresented: $showSkippedAlert
        ) {
            Button("OK") {
                if coordinator?.files.isEmpty == true {
                    dismiss()
                }
            }
        } message: {
            Text(coordinator?.skippedFilesMessage ?? "")
        }
    }
}
