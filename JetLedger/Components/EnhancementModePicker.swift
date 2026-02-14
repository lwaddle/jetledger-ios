//
//  EnhancementModePicker.swift
//  JetLedger
//

import SwiftUI

struct EnhancementModePicker: View {
    @Binding var selectedMode: EnhancementMode

    var body: some View {
        HStack(spacing: 12) {
            ForEach(EnhancementMode.allCases, id: \.self) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: icon(for: mode))
                            .font(.title3)
                        Text(mode.displayName)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(selectedMode == mode ? .white : .secondary)
                    .background(
                        selectedMode == mode
                            ? Color.accentColor
                            : Color(.systemGray5),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(for mode: EnhancementMode) -> String {
        switch mode {
        case .original: "photo"
        case .auto: "wand.and.stars"
        case .blackAndWhite: "circle.lefthalf.filled"
        }
    }
}
