//
//  TripReferencePicker.swift
//  JetLedger
//

import SwiftUI

struct TripReferencePicker: View {
    let accountId: UUID
    @Binding var selection: CachedTripReference?

    var body: some View {
        NavigationLink {
            TripReferenceListView(accountId: accountId, selection: $selection)
        } label: {
            HStack {
                if let ref = selection {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ref.displayTitle)
                            .fontDesign(ref.externalId != nil ? .monospaced : .default)
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
            }
        }
    }
}

// MARK: - Trip Reference List (destination)

private struct TripReferenceListView: View {
    let accountId: UUID
    @Binding var selection: CachedTripReference?

    @Environment(TripReferenceService.self) private var tripReferenceService
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

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
                            Text(ref.displayTitle)
                                .fontDesign(ref.externalId != nil ? .monospaced : .default)
                                .foregroundStyle(.primary)
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
        .buttonStyle(.plain)
        .navigationTitle("Trip Reference")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search trips")
    }
}
