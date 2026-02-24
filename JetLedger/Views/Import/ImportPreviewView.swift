//
//  ImportPreviewView.swift
//  JetLedger
//

import PDFKit
import SwiftUI

struct ImportPreviewView: View {
    let coordinator: ImportFlowCoordinator
    @State private var selectedFile: ImportedFile?

    var body: some View {
        VStack(spacing: 20) {
            Text("\(coordinator.files.count) file\(coordinator.files.count == 1 ? "" : "s") selected")
                .font(.title3)
                .fontWeight(.semibold)

            // Thumbnail grid
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                    ForEach(coordinator.files) { file in
                        Button {
                            selectedFile = file
                        } label: {
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
                        .buttonStyle(.plain)
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
        .sheet(item: $selectedFile) { file in
            FilePreviewSheet(file: file)
        }
    }
}

// MARK: - File Preview Sheet

private struct FilePreviewSheet: View {
    let file: ImportedFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch file.contentType {
                case .pdf:
                    PDFPreviewView(data: file.data)
                case .jpeg:
                    if let image = UIImage(data: file.data) {
                        ZoomableImageView(image: image)
                    } else {
                        ContentUnavailableView("Unable to Load Image", systemImage: "photo.badge.exclamationmark")
                    }
                }
            }
            .navigationTitle(file.originalFileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct PDFPreviewView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFKit.PDFView {
        let pdfView = PDFKit.PDFView()
        pdfView.autoScales = true
        pdfView.document = PDFDocument(data: data)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFKit.PDFView, context: Context) {}
}
