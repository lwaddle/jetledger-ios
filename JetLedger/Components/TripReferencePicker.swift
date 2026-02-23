//
//  TripReferencePicker.swift
//  JetLedger
//

import SwiftUI

struct TripReferencePicker: View {
    let accountId: UUID
    @Binding var selection: CachedTripReference?
    var onActivate: (() -> Void)? = nil
    var presentAsSheet: Bool = true
    var onRequestEdit: (() -> Void)? = nil
    var onRequestCreate: ((_ searchText: String) -> Void)? = nil

    @Environment(TripReferenceService.self) private var tripReferenceService
    @State private var searchText = ""
    @State private var isExpanded = false
    @State private var showCreateSheet = false
    @State private var showEditSheet = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selected = selection {
                // Selected state
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.displayTitle)
                                .fontDesign(selected.externalId != nil ? .monospaced : .default)
                            if selected.externalId != nil, let name = selected.name {
                                Text(name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))

                    HStack(spacing: 16) {
                        Button {
                            triggerEdit()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                                .font(.subheadline)
                        }
                        Button {
                            selection = nil
                            searchText = ""
                        } label: {
                            Label("Clear", systemImage: "xmark.circle")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.leading, 4)
                }
            } else {
                // Search field
                HStack {
                    TextField("Search or create new...", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($isFieldFocused)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    onActivate?()
                    isFieldFocused = true
                })
                .onChange(of: searchText) { _, _ in
                    isExpanded = isFieldFocused || !searchText.isEmpty
                }
                .onChange(of: isFieldFocused) { _, focused in
                    if focused {
                        onActivate?()
                        isExpanded = true
                    } else {
                        // Slight delay so taps on dropdown items register before collapse
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            if !isFieldFocused {
                                isExpanded = false
                            }
                        }
                    }
                }

                // Results dropdown
                if isExpanded {
                    resultsView
                }
            }
        }
        .sheet(isPresented: presentAsSheet ? $showCreateSheet : .constant(false)) {
            CreateTripReferenceSheet(
                accountId: accountId,
                initialText: searchText
            ) { created in
                selection = created
                searchText = ""
                isExpanded = false
            }
        }
        .sheet(isPresented: presentAsSheet ? $showEditSheet : .constant(false)) {
            if let selected = selection {
                EditTripReferenceSheet(tripReference: selected)
            }
        }
    }

    // MARK: - Actions

    private func triggerCreate() {
        if presentAsSheet {
            showCreateSheet = true
        } else {
            onRequestCreate?(searchText)
        }
    }

    private func triggerEdit() {
        if presentAsSheet {
            showEditSheet = true
        } else {
            onRequestEdit?()
        }
    }

    // MARK: - Results View

    private var resultsView: some View {
        let allResults = tripReferenceService.search(searchText, for: accountId)
        let isShowingRecent = searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let results = isShowingRecent ? Array(allResults.prefix(8)) : allResults

        return VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty && !isShowingRecent {
                Button {
                    triggerCreate()
                } label: {
                    Label("Create \"\(searchText)\"", systemImage: "plus.circle")
                        .font(.subheadline)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if results.isEmpty {
                // Empty state — no trips exist yet
                Button {
                    triggerCreate()
                } label: {
                    Label("Create new trip reference", systemImage: "plus.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isShowingRecent {
                            Text("Recent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                        }

                        ForEach(results, id: \.id) { ref in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ref.displayTitle)
                                    .fontDesign(ref.externalId != nil ? .monospaced : .default)
                                if ref.externalId != nil, let name = ref.name {
                                    Text(name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = ref
                                searchText = ""
                                isExpanded = false
                                isFieldFocused = false
                            }

                            Divider()
                        }

                        // Always show create option at bottom
                        Button {
                            triggerCreate()
                        } label: {
                            Label("Create new trip reference", systemImage: "plus.circle")
                                .font(.subheadline)
                                .foregroundStyle(Color.accentColor)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Create Form (reusable content)

struct CreateTripReferenceForm: View {
    let accountId: UUID
    let initialText: String
    let onCreated: (CachedTripReference) -> Void

    @Environment(TripReferenceService.self) private var tripReferenceService
    @Environment(\.dismiss) private var dismiss

    @State private var externalId = ""
    @State private var name = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var canCreate: Bool {
        !externalId.trimmingCharacters(in: .whitespaces).isEmpty ||
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section("Trip ID (optional)") {
                TextField("e.g. 321004", text: $externalId)
                    .fontDesign(.monospaced)
            }

            Section("Name") {
                TextField("e.g. NYC Meeting", text: $name)
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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { create() }
                    .disabled(!canCreate || isCreating)
            }
        }
        .onAppear {
            let text = initialText.trimmingCharacters(in: .whitespaces)
            if looksLikeId(text) {
                externalId = text
            } else {
                name = text
            }
        }
        .interactiveDismissDisabled(isCreating)
    }

    /// Short text without spaces looks like a trip ID; longer or spaced text looks like a name.
    private func looksLikeId(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 12 && !text.contains(" ")
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil

        let trimmedId = externalId.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        Task {
            do {
                let ref = try await tripReferenceService.createTripReference(
                    accountId: accountId,
                    externalId: trimmedId.isEmpty ? nil : trimmedId,
                    name: trimmedName.isEmpty ? nil : trimmedName
                )
                onCreated(ref)
                dismiss()
            } catch {
                errorMessage = "Failed to create trip reference. Check your connection and try again."
                isCreating = false
            }
        }
    }
}

// MARK: - Create Sheet (thin wrapper for sheet presentation)

private struct CreateTripReferenceSheet: View {
    let accountId: UUID
    let initialText: String
    let onCreated: (CachedTripReference) -> Void

    var body: some View {
        NavigationStack {
            CreateTripReferenceForm(
                accountId: accountId,
                initialText: initialText,
                onCreated: onCreated
            )
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Edit Form (reusable content)

struct EditTripReferenceForm: View {
    let tripReference: CachedTripReference

    @Environment(TripReferenceService.self) private var tripReferenceService
    @Environment(\.dismiss) private var dismiss

    @State private var externalId = ""
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !externalId.trimmingCharacters(in: .whitespaces).isEmpty ||
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section("Trip ID (optional)") {
                TextField("e.g. 321004", text: $externalId)
                    .fontDesign(.monospaced)
            }

            Section("Name") {
                TextField("e.g. NYC Meeting", text: $name)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Edit Trip Reference")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave || isSaving)
            }
        }
        .onAppear {
            externalId = tripReference.externalId ?? ""
            name = tripReference.name ?? ""
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil

        let trimmedId = externalId.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let finalId = trimmedId.isEmpty ? nil : trimmedId
        let finalName = trimmedName.isEmpty ? nil : trimmedName

        Task {
            do {
                _ = try await tripReferenceService.updateTripReference(
                    id: tripReference.id,
                    externalId: finalId,
                    name: finalName
                )
                tripReferenceService.propagateTripReferenceUpdate(
                    id: tripReference.id,
                    externalId: finalId,
                    name: finalName
                )
                dismiss()
            } catch {
                errorMessage = "Failed to update trip reference. Check your connection and try again."
                isSaving = false
            }
        }
    }
}

// MARK: - Edit Sheet (thin wrapper for sheet presentation)

private struct EditTripReferenceSheet: View {
    let tripReference: CachedTripReference

    var body: some View {
        NavigationStack {
            EditTripReferenceForm(tripReference: tripReference)
        }
        .presentationDetents([.medium])
    }
}
