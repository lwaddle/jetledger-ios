//
//  TripReferencePicker.swift
//  JetLedger
//

import SwiftUI

struct TripReferencePicker: View {
    let accountId: UUID
    @Binding var selection: CachedTripReference?

    @Environment(TripReferenceService.self) private var tripReferenceService
    @State private var searchText = ""
    @State private var isExpanded = false
    @State private var showCreateSheet = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selected = selection {
                // Selected state
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
                    Button("Clear") {
                        selection = nil
                        searchText = ""
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                // Search field
                TextField("Search or create new...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFieldFocused)
                    .onChange(of: searchText) { _, _ in
                        isExpanded = isFieldFocused || !searchText.isEmpty
                    }
                    .onChange(of: isFieldFocused) { _, focused in
                        if focused {
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
        .sheet(isPresented: $showCreateSheet) {
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

    private var resultsView: some View {
        let allResults = tripReferenceService.search(searchText, for: accountId)
        let isShowingRecent = searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let results = isShowingRecent ? Array(allResults.prefix(8)) : allResults

        return VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty && !isShowingRecent {
                Button {
                    showCreateSheet = true
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
                    showCreateSheet = true
                } label: {
                    Label("Create new trip reference", systemImage: "plus.circle")
                        .font(.subheadline)
                        .foregroundStyle(AppConstants.Colors.primaryAccent)
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
                            Button {
                                selection = ref
                                searchText = ""
                                isExpanded = false
                                isFieldFocused = false
                            } label: {
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
                            }
                            .buttonStyle(.plain)

                            Divider()
                        }

                        // Always show create option at bottom
                        Button {
                            showCreateSheet = true
                        } label: {
                            Label("Create new trip reference", systemImage: "plus.circle")
                                .font(.subheadline)
                                .foregroundStyle(AppConstants.Colors.primaryAccent)
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

// MARK: - Create Sheet

private struct CreateTripReferenceSheet: View {
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
        NavigationStack {
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
        .presentationDetents([.medium])
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
