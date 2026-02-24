//
//  TripReferencePicker.swift
//  JetLedger
//

import SwiftUI

struct TripReferencePicker: View {
    let accountId: UUID
    @Binding var selection: CachedTripReference?
    var onActivate: (() -> Void)? = nil

    /// When provided, the picker calls this instead of presenting its own create sheet.
    /// Use this when the picker is inside a Form or other lazy container where
    /// .sheet modifiers may not present reliably (e.g. on iPad).
    var onCreateRequest: ((_ searchText: String) -> Void)? = nil

    /// When provided, the picker calls this instead of presenting its own edit sheet.
    var onEditRequest: ((_ tripReference: CachedTripReference) -> Void)? = nil

    @Environment(TripReferenceService.self) private var tripReferenceService
    @State private var searchText = ""
    @State private var isExpanded = false
    @State private var showCreateSheet = false
    @State private var showEditSheet = false
    @State private var editingTripReference: CachedTripReference?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded {
                // Expanded: search field + dropdown
                HStack {
                    TextField("Search or create new...", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($isFieldFocused)
                    Image(systemName: "chevron.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    onActivate?()
                    isFieldFocused = true
                })
                .onChange(of: isFieldFocused) { _, focused in
                    if !focused {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            if !isFieldFocused {
                                isExpanded = false
                            }
                        }
                    }
                }

                resultsView
            } else if let selected = selection {
                // Collapsed selected state — tappable row to reopen
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
                    Button {
                        triggerEdit(selected)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                .contentShape(Rectangle())
                .onTapGesture {
                    onActivate?()
                    isExpanded = true
                    isFieldFocused = true
                }
            } else {
                // Collapsed empty state — tappable placeholder
                HStack {
                    Text("Search or create new...")
                        .foregroundStyle(.placeholder)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                .contentShape(Rectangle())
                .onTapGesture {
                    onActivate?()
                    isExpanded = true
                    isFieldFocused = true
                }
            }
        }
        .sheet(isPresented: onCreateRequest == nil ? $showCreateSheet : .constant(false)) {
            TripReferenceSheet(
                accountId: accountId,
                initialText: searchText
            ) { created in
                selection = created
                searchText = ""
                isExpanded = false
            }
        }
        .sheet(isPresented: onEditRequest == nil ? $showEditSheet : .constant(false)) {
            if let ref = editingTripReference {
                TripReferenceSheet(
                    accountId: accountId,
                    editing: ref
                ) { updated in
                    if selection?.id == updated.id {
                        selection = updated
                    }
                    editingTripReference = nil
                }
            }
        }
    }

    // MARK: - Actions

    private func triggerCreate() {
        if let onCreateRequest {
            onCreateRequest(searchText)
        } else {
            showCreateSheet = true
        }
    }

    private func triggerEdit(_ ref: CachedTripReference) {
        if let onEditRequest {
            onEditRequest(ref)
        } else {
            editingTripReference = ref
            showEditSheet = true
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
                        .padding(.vertical, 12)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            } else if results.isEmpty {
                Button {
                    triggerCreate()
                } label: {
                    Label("Create new trip reference", systemImage: "plus.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // "None" option when a trip is currently selected
                        if selection != nil {
                            HStack {
                                Text("None")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = nil
                                searchText = ""
                                isExpanded = false
                                isFieldFocused = false
                            }

                            Divider()
                        }

                        if isShowingRecent {
                            Text("Recent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                        }

                        ForEach(results, id: \.id) { ref in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ref.displayTitle)
                                        .fontDesign(ref.externalId != nil ? .monospaced : .default)
                                    if ref.externalId != nil, let name = ref.name {
                                        Text(name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    triggerEdit(ref)
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = ref
                                searchText = ""
                                isExpanded = false
                                isFieldFocused = false
                            }
                            .contextMenu {
                                Button {
                                    triggerEdit(ref)
                                } label: {
                                    Label("Edit Trip Reference", systemImage: "pencil")
                                }
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
                                .padding(.vertical, 12)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Create Form (reusable content)

struct CreateTripReferenceForm: View {
    let accountId: UUID
    var initialText: String = ""
    var editing: CachedTripReference? = nil
    let onSaved: (CachedTripReference) -> Void

    private var isEditMode: Bool { editing != nil }

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
            Section {
                TextField("e.g. 321004", text: $externalId)
                    .fontDesign(.monospaced)
            } header: {
                Text("Trip ID (optional)")
            } footer: {
                if !externalId.isEmpty || !name.isEmpty {
                    Button {
                        let temp = externalId
                        externalId = name
                        name = temp
                    } label: {
                        Label("Swap Trip ID and Name", systemImage: "arrow.up.arrow.down")
                    }
                    .font(.caption)
                }
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
        .navigationTitle(isEditMode ? "Edit Trip Reference" : "New Trip Reference")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditMode ? "Save" : "Create") { save() }
                    .disabled(!canSave || isSaving)
            }
        }
        .onAppear {
            if let editing {
                externalId = editing.externalId ?? ""
                name = editing.name ?? ""
            } else {
                let text = initialText.trimmingCharacters(in: .whitespaces)
                if looksLikeId(text) {
                    externalId = text
                } else {
                    name = text
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    /// Numeric-only text (with optional dashes/dots) looks like a trip ID; anything with letters is a name.
    private func looksLikeId(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isNumber || $0 == "-" || $0 == "." }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil

        let trimmedId = externalId.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        Task {
            do {
                let ref: CachedTripReference
                if let editing {
                    ref = try await tripReferenceService.updateTripReference(
                        id: editing.id,
                        externalId: trimmedId.isEmpty ? nil : trimmedId,
                        name: trimmedName.isEmpty ? nil : trimmedName
                    )
                    tripReferenceService.propagateTripReferenceUpdate(
                        id: editing.id,
                        externalId: ref.externalId,
                        name: ref.name
                    )
                } else {
                    ref = try await tripReferenceService.createTripReference(
                        accountId: accountId,
                        externalId: trimmedId.isEmpty ? nil : trimmedId,
                        name: trimmedName.isEmpty ? nil : trimmedName
                    )
                }
                onSaved(ref)
                dismiss()
            } catch {
                errorMessage = isEditMode
                    ? "Failed to update trip reference. Check your connection and try again."
                    : "Failed to create trip reference. Check your connection and try again."
                isSaving = false
            }
        }
    }
}

// MARK: - Sheet wrapper (thin wrapper for sheet presentation)

private struct TripReferenceSheet: View {
    let accountId: UUID
    var initialText: String = ""
    var editing: CachedTripReference? = nil
    let onSaved: (CachedTripReference) -> Void

    var body: some View {
        NavigationStack {
            CreateTripReferenceForm(
                accountId: accountId,
                initialText: initialText,
                editing: editing,
                onSaved: onSaved
            )
        }
        .presentationDetents([.medium])
    }
}
