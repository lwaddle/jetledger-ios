//
//  TripReferencePicker.swift
//  JetLedger
//

import SwiftUI

struct TripReferencePicker: View {
    let accountId: UUID
    @Binding var selection: CachedTripReference?

    @Environment(TripReferenceService.self) private var tripReferenceService

    private var chips: [CachedTripReference] {
        var recent = tripReferenceService.recentTripReferences(for: accountId)
        // Always include the current selection even if it's older than 30 days
        if let selected = selection, !recent.contains(where: { $0.id == selected.id }) {
            recent.append(selected)
        }
        return recent
    }

    var body: some View {
        if chips.isEmpty {
            Text("No recent trips")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.id) { ref in
                        chipButton(for: ref)
                    }
                }
            }
        }
    }

    private func chipButton(for ref: CachedTripReference) -> some View {
        let isSelected = selection?.id == ref.id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = isSelected ? nil : ref
            }
        } label: {
            VStack(spacing: 1) {
                Text(ref.displayTitle)
                    .fontDesign(ref.externalId != nil ? .monospaced : .default)
                    .font(.subheadline)
                if ref.externalId != nil, let name = ref.name {
                    Text(name)
                        .font(.caption2)
                        .opacity(isSelected ? 0.85 : 0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(isSelected ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
