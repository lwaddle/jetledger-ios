//
//  ImportFlowView.swift
//  JetLedger
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportFlowView: View {
    let accountId: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var coordinator: ImportFlowCoordinator?
    @State private var showFilePicker = true

    var body: some View {
        NavigationStack {
            Group {
                if let coordinator {
                    switch coordinator.currentStep {
                    case .filePicker:
                        // File picker is presented as a sheet overlay
                        ContentUnavailableView(
                            "Select Files",
                            systemImage: "doc.badge.plus",
                            description: Text("Choose PDFs or images to import.")
                        )
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
                coordinator = ImportFlowCoordinator(
                    accountId: accountId,
                    modelContext: modelContext
                )
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf, .jpeg, .png, .heic],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                coordinator?.handleImportedURLs(urls)
                if coordinator?.files.isEmpty == true {
                    dismiss()
                }
            case .failure:
                dismiss()
            }
        }
        .onChange(of: showFilePicker) { _, isShowing in
            // If file picker was dismissed without selecting, dismiss the flow
            if !isShowing && (coordinator?.files.isEmpty ?? true) && coordinator?.currentStep == .filePicker {
                dismiss()
            }
        }
    }
}
