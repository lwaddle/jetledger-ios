//
//  SharedContainerHelper.swift
//  JetLedger
//

import Foundation

enum SharedContainerHelper {
    private static let manifestFileName = "pending-imports.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.SharedContainer.appGroupIdentifier
        )
    }

    private static var importsDirectory: URL? {
        containerURL?.appendingPathComponent(AppConstants.SharedContainer.pendingImportsDirectory)
    }

    private static var manifestURL: URL? {
        containerURL?.appendingPathComponent(manifestFileName)
    }

    // MARK: - File I/O

    static func saveFile(data: Data, fileName: String, importId: UUID) -> String? {
        guard let dir = importsDirectory?.appendingPathComponent(importId.uuidString) else { return nil }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: .completeFileProtectionUnlessOpen)
            return "\(importId.uuidString)/\(fileName)"
        } catch {
            return nil
        }
    }

    static func loadFileData(relativePath: String) -> Data? {
        guard let url = importsDirectory?.appendingPathComponent(relativePath) else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Manifest

    static func loadManifest() -> [PendingImport] {
        guard let url = manifestURL,
              let data = try? Data(contentsOf: url)
        else { return [] }

        return (try? JSONDecoder().decode([PendingImport].self, from: data)) ?? []
    }

    static func saveManifest(_ imports: [PendingImport]) {
        guard let url = manifestURL else { return }
        guard let data = try? JSONEncoder().encode(imports) else { return }
        try? data.write(to: url)
    }

    static func appendImport(_ pendingImport: PendingImport) {
        var manifest = loadManifest()
        manifest.append(pendingImport)
        saveManifest(manifest)
    }

    // MARK: - Cleanup

    static func removeImport(id: UUID) {
        var manifest = loadManifest()
        manifest.removeAll { $0.id == id }
        saveManifest(manifest)

        // Remove files
        if let dir = importsDirectory?.appendingPathComponent(id.uuidString) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func clearManifest() {
        if let url = manifestURL {
            try? FileManager.default.removeItem(at: url)
        }
        if let dir = importsDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
