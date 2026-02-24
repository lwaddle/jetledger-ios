//
//  ImportPreviewView.swift
//  JetLedger
//

import SwiftUI

struct ImportPreviewView: View {
    let coordinator: ImportFlowCoordinator

    var body: some View {
        VStack(spacing: 20) {
            Text("\(coordinator.files.count) file\(coordinator.files.count == 1 ? "" : "s") selected")
                .font(.title3)
                .fontWeight(.semibold)

            // Thumbnail grid
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                    ForEach(coordinator.files) { file in
                        VStack(spacing: 6) {
                            if let thumbnail = file.thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 100, height: 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(.secondary.opacity(0.3), lineWidth: 1)
                                    )
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary)
                                    .frame(width: 100, height: 130)
                                    .overlay {
                                        Image(systemName: file.contentType == .pdf ? "doc.richtext" : "photo")
                                            .font(.title2)
                                            .foregroundStyle(.secondary)
                                    }
                            }

                            if file.contentType == .pdf {
                                Text("PDF")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.indigo.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.indigo)
                            }
                        }
                    }
                }
                .padding()
            }

            Button {
                coordinator.currentStep = .metadata
            } label: {
                Label("Continue", systemImage: "arrow.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .padding(.horizontal, 32)
            .padding(.bottom)
        }
        .navigationTitle("Import Files")
        .navigationBarTitleDisplayMode(.inline)
    }
}
