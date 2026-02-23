//
//  ImportMetadataView.swift
//  JetLedger
//

import SwiftUI

struct ImportMetadataView: View {
    let coordinator: ImportFlowCoordinator
    let onDone: () -> Void

    @State private var note = ""
    @State private var selectedTripReference: CachedTripReference?
    @FocusState private var noteIsFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // File thumbnails
                fileThumbnails

                // Note field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Note")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    TextField("e.g. Fuel stop KPDX", text: $note)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                        .focused($noteIsFocused)
                }

                // Trip reference picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trip Reference (optional)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    TripReferencePicker(
                        accountId: coordinator.accountId,
                        selection: $selectedTripReference,
                        onActivate: { noteIsFocused = false },
                        presentAsSheet: false
                    )
                }

                Spacer(minLength: 40)
            }
            .padding()
        }
        .navigationTitle("Receipt Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") {
                    coordinator.currentStep = .preview
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    save()
                }
                .fontWeight(.semibold)
                .disabled(coordinator.isSaving)
            }
        }
        .overlay {
            if coordinator.isSaving {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                ProgressView("Saving...")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear {
            noteIsFocused = true
        }
    }

    // MARK: - Subviews

    private var fileThumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(coordinator.files) { file in
                    if let thumbnail = file.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.secondary.opacity(0.3), lineWidth: 1)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                            .frame(width: 60, height: 80)
                            .overlay {
                                Image(systemName: file.contentType == .pdf ? "doc.richtext" : "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
            }
        }
        .frame(height: 80)
    }

    // MARK: - Actions

    private func save() {
        noteIsFocused = false

        Task {
            let receipt = await coordinator.saveReceipt(
                note: note.strippingHTMLTags,
                tripReferenceId: selectedTripReference?.id,
                tripReferenceExternalId: selectedTripReference?.externalId,
                tripReferenceName: selectedTripReference?.name
            )
            if receipt != nil {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onDone()
            }
        }
    }
}
