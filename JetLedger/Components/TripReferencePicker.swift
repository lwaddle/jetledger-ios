//
//  TripReferencePicker.swift
//  JetLedger
//

import SwiftUI

struct TripReferencePicker: View {
    let accountId: UUID
    @Binding var selection: CachedTripReference?
    var onActivate: (() -> Void)? = nil

    @Environment(TripReferenceService.self) private var tripReferenceService
    @State private var searchText = ""
    @State private var isExpanded = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded {
                // Expanded: search field + dropdown
                HStack {
                    TextField("Search trips...", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($isFieldFocused)
                    Button {
                        searchText = ""
                        isExpanded = false
                        isFieldFocused = false
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                            .padding(.leading, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                    Text("Select a trip...")
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
    }

    // MARK: - Results View

    private var resultsView: some View {
        let allResults = tripReferenceService.search(searchText, for: accountId)
        let isShowingRecent = searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let results = isShowingRecent ? Array(allResults.prefix(8)) : allResults

        return VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty && !isShowingRecent {
                Text("No matching trips")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 10)
            } else if results.isEmpty {
                Text("No trips yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 10)
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
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
