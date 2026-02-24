//
//  TripReferencePicker.swift
//  JetLedger
//

import SwiftUI

struct TripReferencePicker: View {
    let accountId: UUID
    @Binding var selection: CachedTripReference?
    var showChevron: Bool = false
    var userRole: AccountRole? = nil

    var body: some View {
        NavigationLink {
            TripReferenceListView(accountId: accountId, selection: $selection, userRole: userRole)
        } label: {
            HStack {
                if let ref = selection {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(ref.displayTitle)
                                .fontDesign(ref.externalId != nil ? .monospaced : .default)
                            if ref.isPendingSync {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if ref.externalId != nil, let name = ref.name {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Trip Reference List (destination)

private struct TripReferenceListView: View {
    let accountId: UUID
    @Binding var selection: CachedTripReference?
    var userRole: AccountRole?

    @Environment(TripReferenceService.self) private var tripReferenceService
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var showCreateForm = false
    @State private var shouldDismissAfterCreate = false

    private var canCreate: Bool {
        userRole?.canUpload ?? false
    }

    private var filteredReferences: [CachedTripReference] {
        tripReferenceService.search(searchText, for: accountId)
    }

    var body: some View {
        List {
            if selection != nil && searchText.isEmpty {
                Button {
                    selection = nil
                    dismiss()
                } label: {
                    Text("None")
                        .foregroundStyle(.primary)
                }
            }

            ForEach(filteredReferences, id: \.id) { ref in
                Button {
                    selection = ref
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(ref.displayTitle)
                                    .fontDesign(ref.externalId != nil ? .monospaced : .default)
                                    .foregroundStyle(.primary)
                                if ref.isPendingSync {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if ref.externalId != nil, let name = ref.name {
                                Text(name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if selection?.id == ref.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.accent)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .navigationTitle("Trip Reference")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search trips")
        .toolbar {
            if canCreate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreateForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showCreateForm) {
            CreateTripReferenceView(accountId: accountId) { newRef in
                selection = newRef
                shouldDismissAfterCreate = true
            }
        }
        .onChange(of: showCreateForm) { _, isPresented in
            if !isPresented && shouldDismissAfterCreate {
                shouldDismissAfterCreate = false
                dismiss()
            }
        }
    }
}

// MARK: - Create Trip Reference View (pushed in nav stack)

private struct CreateTripReferenceView: View {
    let accountId: UUID
    let onCreated: (CachedTripReference) -> Void

    @Environment(TripReferenceService.self) private var tripReferenceService
    @Environment(\.dismiss) private var dismiss

    @State private var externalId = ""
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case externalId, name }

    private var isValid: Bool {
        !externalId.trimmingCharacters(in: .whitespaces).isEmpty ||
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("e.g. 321004", text: $externalId)
                    .fontDesign(.monospaced)
                    .focused($focusedField, equals: .externalId)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            } header: {
                Text("Trip ID")
            } footer: {
                Text("The flight or trip number")
            }

            Section {
                TextField("e.g. NYC Meeting", text: $name)
                    .focused($focusedField, equals: .name)
            } header: {
                Text("Name (optional)")
            } footer: {
                Text("A descriptive name for this trip")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("New Trip Reference")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSaving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .fontWeight(.semibold)
                    .disabled(!isValid || isSaving)
            }
        }
        .task {
            focusedField = .externalId
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        Task {
            do {
                let ref = try await tripReferenceService.createTripReferenceLocally(
                    accountId: accountId,
                    externalId: externalId.trimmingCharacters(in: .whitespaces),
                    name: name.trimmingCharacters(in: .whitespaces)
                )
                onCreated(ref)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
