//
//  ShareView.swift
//  JetLedgerShare
//

import SwiftUI
import UniformTypeIdentifiers

struct ShareView: View {
    let extensionContext: NSExtensionContext

    @State private var status: ShareStatus = .processing
    @State private var fileCount = 0

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            switch status {
            case .processing:
                ProgressView("Processing files...")
                    .controlSize(.large)

            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s") saved")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Open JetLedger to add details and upload.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Done") {
                    extensionContext.completeRequest(returningItems: nil)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)

            case .noFiles:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("No supported files found")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("JetLedger accepts PDFs, JPEGs, PNGs, and HEIC images.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Done") {
                    extensionContext.completeRequest(returningItems: nil)
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)

            case .error(let message):
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                Text("Import Failed")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Done") {
                    extensionContext.completeRequest(returningItems: nil)
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding(32)
        .task {
            await processAttachments()
        }
    }

    private func processAttachments() async {
        let supportedTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .image]

        var importedFiles: [PendingImportFile] = []
        let importId = UUID()

        guard let items = extensionContext.inputItems as? [NSExtensionItem] else {
            status = .noFiles
            return
        }

        for item in items {
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                // Find a supported type
                var matchedType: UTType?
                for type in supportedTypes {
                    if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                        matchedType = type
                        break
                    }
                }
                guard let type = matchedType else { continue }

                do {
                    let item = try await provider.loadItem(
                        forTypeIdentifier: type.identifier
                    )

                    var data: Data?
                    var fileName: String?

                    if let url = item as? URL {
                        data = try Data(contentsOf: url)
                        fileName = url.lastPathComponent
                    } else if let fileData = item as? Data {
                        data = fileData
                        fileName = "file.\(type.preferredFilenameExtension ?? "bin")"
                    }

                    guard let fileData = data, let name = fileName else { continue }

                    let contentType: String
                    if type.conforms(to: .pdf) {
                        contentType = PageContentType.pdf.rawValue
                    } else {
                        contentType = PageContentType.jpeg.rawValue
                    }

                    // Save to shared container
                    guard let relativePath = SharedContainerHelper.saveFile(
                        data: fileData,
                        fileName: name,
                        importId: importId
                    ) else { continue }

                    importedFiles.append(PendingImportFile(
                        relativePath: relativePath,
                        originalFileName: name,
                        contentType: contentType,
                        fileSize: fileData.count
                    ))
                } catch {
                    continue
                }
            }
        }

        if importedFiles.isEmpty {
            status = .noFiles
        } else {
            let pendingImport = PendingImport(id: importId, files: importedFiles)
            SharedContainerHelper.appendImport(pendingImport)
            fileCount = importedFiles.count
            status = .success
        }
    }
}

private enum ShareStatus {
    case processing
    case success
    case noFiles
    case error(String)
}
