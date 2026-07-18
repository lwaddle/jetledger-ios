//
//  MetadataView.swift
//  JetLedger
//

import SwiftUI

struct MetadataView: View {
    let coordinator: CaptureFlowCoordinator
    let onDone: () -> Void

    @Environment(AccountService.self) private var accountService
    @State private var note: String
    @State private var selectedTripReference: CachedTripReference?
    @State private var errorMessage: String?
    @State private var showDiscardAlert = false
    @FocusState private var noteIsFocused: Bool

    init(coordinator: CaptureFlowCoordinator, onDone: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onDone = onDone
        self._note = State(initialValue: coordinator.draftNote)
        self._selectedTripReference = State(initialValue: coordinator.draftTripReference)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    pageThumbnails
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }

                Section("Note") {
                    TextField("e.g. Fuel stop KPDX", text: $note)
                        .focused($noteIsFocused)
                }

                Section("Trip Reference (optional)") {
                    TripReferencePicker(
                        accountId: coordinator.accountId,
                        selection: $selectedTripReference,
                        userRole: accountService.selectedAccount?.accountRole
                    )
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(Color(.statusError))
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Receipt Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        showDiscardAlert = true
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
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                noteIsFocused = true
            }
            .alert("Discard Receipt?", isPresented: $showDiscardAlert) {
                Button("Discard", role: .destructive) {
                    onDone()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All \(coordinator.pages.count) captured page\(coordinator.pages.count == 1 ? "" : "s") will be discarded.")
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

                Button {
                    coordinator.draftNote = note
                    coordinator.draftTripReference = selectedTripReference
                    coordinator.addAnotherPage()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.title3)
                        Text("Add Page")
                            .font(.caption2)
                    }
                    .frame(width: 60, height: 80)
                    .foregroundStyle(Color.accentColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                Color.accentColor.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add another page")
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
