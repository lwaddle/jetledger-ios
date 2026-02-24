//
//  ExposureLevelPicker.swift
//  JetLedger
//

import SwiftUI

struct ExposureLevelPicker: View {
    @Binding var selectedLevel: ExposureLevel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(ExposureLevel.allCases, id: \.self) { level in
                Button {
                    selectedLevel = level
                } label: {
                    Text(level.displayLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(width: 36, height: 28)
                        .foregroundStyle(selectedLevel == level ? .white : .primary)
                        .background(
                            selectedLevel == level
                                ? Color.accentColor
                                : Color(.systemGray5),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
            }

            Image(systemName: "sun.max")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
