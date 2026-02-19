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
            }

            Spacer()
        }
        .padding(32)
        .task {
            await processAttachments()
        }
    }

    private func processAttachments() async {
        let specificTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .image]

        var importedFiles: [PendingImportFile] = []
        let importId = UUID()

        guard let items = extensionContext.inputItems as? [NSExtensionItem] else {
            status = .noFiles
            return
        }

        for item in items {
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                var data: Data?
                var fileName: String?
                var contentType: PageContentType?

                // Phase 1: Try specific UTType matching (well-behaved apps like Files, Photos)
                for type in specificTypes {
                    guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }
                    do {
                        let result = try await loadFileData(from: provider, typeIdentifier: type.identifier)
                        data = result.data
                        fileName = result.fileName
                        contentType = type.conforms(to: .pdf) ? .pdf : .jpeg
                        break
                    } catch {
                        continue
                    }
                }

                // Phase 2: Iterate actual registered types (Outlook, Gmail, etc.)
                if data == nil {
                    for registeredId in provider.registeredTypeIdentifiers {
                        do {
                            let result = try await loadFileData(from: provider, typeIdentifier: registeredId)
                            data = result.data
                            fileName = result.fileName

                            // Resolve content type from filename extension
                            let ext = (result.fileName as NSString).pathExtension.lowercased()
                            if !ext.isEmpty {
                                contentType = self.contentType(forExtension: ext)
                            }
                            // Fallback: try suggestedName extension
                            if contentType == nil, let suggested = provider.suggestedName {
                                let suggestedExt = (suggested as NSString).pathExtension.lowercased()
                                if !suggestedExt.isEmpty {
                                    contentType = self.contentType(forExtension: suggestedExt)
                                }
                            }
                            // Fallback: check the registered UTType itself
                            if contentType == nil, let utType = UTType(registeredId) {
                                if utType.conforms(to: .pdf) { contentType = .pdf }
                                else if utType.conforms(to: .image) { contentType = .jpeg }
                            }

                            if contentType != nil { break }
                            data = nil
                            fileName = nil
                        } catch {
                            continue
                        }
                    }
                }

                guard let fileData = data, let pageContentType = contentType else { continue }

                let name = fileName
                    ?? provider.suggestedName
                    ?? "file.\(pageContentType == .pdf ? "pdf" : "jpg")"

                // Save to shared container
                guard let relativePath = SharedContainerHelper.saveFile(
                    data: fileData,
                    fileName: name,
                    importId: importId
                ) else { continue }

                importedFiles.append(PendingImportFile(
                    relativePath: relativePath,
                    originalFileName: name,
                    contentType: pageContentType.rawValue,
                    fileSize: fileData.count
                ))
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

    /// Loads file data from a provider, trying loadFileRepresentation first (copies to a readable
    /// temp location), then falling back to loadDataRepresentation (raw bytes).
    private func loadFileData(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> (data: Data, fileName: String) {
        // Try loadFileRepresentation first — copies to temp location, avoids sandbox issues
        do {
            return try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let url else {
                        continuation.resume(throwing: CocoaError(.fileReadNoSuchFile))
                        return
                    }
                    do {
                        let data = try Data(contentsOf: url)
                        continuation.resume(returning: (data, url.lastPathComponent))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            // Fallback: loadDataRepresentation returns raw bytes (no file URL needed)
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: CocoaError(.fileReadNoSuchFile))
                    }
                }
            }
            let fileName = provider.suggestedName ?? "file"
            return (data, fileName)
        }
    }

    private func contentType(forExtension ext: String) -> PageContentType? {
        guard let utType = UTType(filenameExtension: ext) else { return nil }
        if utType.conforms(to: .pdf) { return .pdf }
        if utType.conforms(to: .image) { return .jpeg }
        return nil
    }
}

private enum ShareStatus {
    case processing
    case success
    case noFiles
}
