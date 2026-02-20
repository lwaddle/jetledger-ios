//
//  MetadataView.swift
//  JetLedger
//

import SwiftUI

struct MetadataView: View {
    let coordinator: CaptureFlowCoordinator
    let onDone: () -> Void

    @State private var note = ""
    @State private var selectedTripReference: CachedTripReference?
    @State private var errorMessage: String?
    @FocusState private var noteIsFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Page thumbnails
                    pageThumbnails

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
                            onActivate: { noteIsFocused = false }
                        )
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
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
                        coordinator.returnToMultiPagePrompt()
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
    }

    // MARK: - Subviews

    private var pageThumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(coordinator.pages) { page in
                    if let image = page.processedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
            }
        }
        .frame(height: 80)
    }

    // MARK: - Actions

    private func save() {
        noteIsFocused = false
        errorMessage = nil

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
            } else {
                errorMessage = coordinator.error ?? "Failed to save receipt. Please try again."
            }
        }
    }
}
