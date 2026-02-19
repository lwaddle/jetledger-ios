//
//  ImportFlowView.swift
//  JetLedger
//

import SwiftUI

struct ImportFlowView: View {
    let accountId: UUID
    let urls: [URL]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var coordinator: ImportFlowCoordinator?

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
                if c.files.isEmpty {
                    dismiss()
                }
            }
        }
    }
}
