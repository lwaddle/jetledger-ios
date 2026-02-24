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

    @Environment(TripReferenceService.self) private var tripReferenceService
    @State private var searchText = ""
    @State private var isExpanded = false
    @State private var showCreateSheet = false
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
            CreateTripReferenceSheet(
                accountId: accountId,
                initialText: searchText
            ) { created in
                selection = created
                searchText = ""
                isExpanded = false
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ref.displayTitle)
                                    .fontDesign(ref.externalId != nil ? .monospaced : .default)
                                if ref.externalId != nil, let name = ref.name {
                                    Text(name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
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

            if !externalId.isEmpty || !name.isEmpty {
                Section {
                    Button {
                        let temp = externalId
                        externalId = name
                        name = temp
                    } label: {
                        Label("Swap Trip ID and Name", systemImage: "arrow.up.arrow.down")
                            .font(.subheadline)
                    }
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

    /// Numeric-only text (with optional dashes/dots) looks like a trip ID; anything with letters is a name.
    private func looksLikeId(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isNumber || $0 == "-" || $0 == "." }
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
