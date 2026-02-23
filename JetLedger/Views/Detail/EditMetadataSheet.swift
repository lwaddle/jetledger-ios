//
//  EditMetadataSheet.swift
//  JetLedger
//

import SwiftData
import SwiftUI

struct EditMetadataSheet: View {
    let receipt: LocalReceipt

    @Environment(SyncService.self) private var syncService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var note: String
    @State private var selectedTripReference: CachedTripReference?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showCreateTrip = false
    @State private var createTripSearchText = ""
    @State private var didLoadInitialTrip = false

    init(receipt: LocalReceipt) {
        self.receipt = receipt
        _note = State(initialValue: receipt.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextField("e.g. Fuel stop KPDX", text: $note)
                }

                Section("Trip Reference") {
                    TripReferencePicker(
                        accountId: receipt.accountId,
                        selection: $selectedTripReference,
                        onCreateRequest: { text in
                            createTripSearchText = text
                            showCreateTrip = true
                        }
                    )
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Edit Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                loadTripReference()
            }
            .navigationDestination(isPresented: $showCreateTrip) {
                CreateTripReferenceForm(
                    accountId: receipt.accountId,
                    initialText: createTripSearchText
                ) { created in
                    selectedTripReference = created
                }
            }
        }
        .presentationDetents([.large])
    }

    private func loadTripReference() {
        guard !didLoadInitialTrip else { return }
        didLoadInitialTrip = true
        guard let tripId = receipt.tripReferenceId else { return }
        let descriptor = FetchDescriptor<CachedTripReference>(
            predicate: #Predicate<CachedTripReference> { ref in
                ref.id == tripId
            }
        )
        selectedTripReference = try? modelContext.fetch(descriptor).first
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        let trimmedNote = note.strippingHTMLTags.trimmingCharacters(in: .whitespaces)

        Task {
            do {
                try await syncService.updateReceiptMetadata(
                    receipt,
                    note: trimmedNote.isEmpty ? nil : trimmedNote,
                    tripReferenceId: selectedTripReference?.id,
                    tripReferenceExternalId: selectedTripReference?.externalId,
                    tripReferenceName: selectedTripReference?.name
                )
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch let error as APIError where error == .conflict {
                errorMessage = error.errorDescription
                isSaving = false
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
