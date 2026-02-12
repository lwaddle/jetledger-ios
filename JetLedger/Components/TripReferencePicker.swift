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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selected = selection {
                // Selected state
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.externalId)
                            .fontDesign(.monospaced)
                        if let name = selected.name {
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
                    .onChange(of: searchText) { _, _ in
                        isExpanded = !searchText.isEmpty
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
                initialExternalId: searchText
            ) { created in
                selection = created
                searchText = ""
                isExpanded = false
            }
        }
    }

    private var resultsView: some View {
        let results = tripReferenceService.search(searchText, for: accountId)

        return VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Create \"\(searchText)\"", systemImage: "plus.circle")
                        .font(.subheadline)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results, id: \.id) { ref in
                            Button {
                                selection = ref
                                searchText = ""
                                isExpanded = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ref.externalId)
                                        .fontDesign(.monospaced)
                                    if let name = ref.name {
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
    let initialExternalId: String
    let onCreated: (CachedTripReference) -> Void

    @Environment(TripReferenceService.self) private var tripReferenceService
    @Environment(\.dismiss) private var dismiss

    @State private var externalId = ""
    @State private var name = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip Reference ID") {
                    TextField("e.g. 321004", text: $externalId)
                        .fontDesign(.monospaced)
                }

                Section("Name (optional)") {
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
                        .disabled(externalId.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
            .onAppear {
                externalId = initialExternalId
            }
            .interactiveDismissDisabled(isCreating)
        }
        .presentationDetents([.medium])
    }

    private func create() {
        let trimmedId = externalId.trimmingCharacters(in: .whitespaces)
        guard !trimmedId.isEmpty else { return }
        isCreating = true
        errorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        Task {
            do {
                let ref = try await tripReferenceService.createTripReference(
                    accountId: accountId,
                    externalId: trimmedId,
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
