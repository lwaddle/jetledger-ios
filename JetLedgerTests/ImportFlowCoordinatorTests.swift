//
//  ImportFlowCoordinatorTests.swift
//  JetLedgerTests
//

import Testing
import Foundation
import SwiftData
import UIKit
@testable import JetLedger

@MainActor
struct ImportFlowCoordinatorTests {

    // SwiftData doesn't like re-creating in-memory ModelContainers with the same
    // schema multiple times in a single process, so the suite shares one container
    // across tests. Each test gets a fresh ModelContext so inserted records don't
    // leak between cases.
    private static let sharedContainer: ModelContainer = {
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [config])
    }()

    private func makeCoordinator() throws -> (ImportFlowCoordinator, ModelContext) {
        let context = ModelContext(Self.sharedContainer)
        // Reset store between tests — the container is shared, the context is not.
        try context.delete(model: LocalReceipt.self)
        try context.delete(model: LocalReceiptPage.self)
        try context.save()
        let coordinator = ImportFlowCoordinator(accountId: UUID(), modelContext: context)
        return (coordinator, context)
    }

    // Builds a minimal 4x4 JPEG payload for fixture files.
    private func makeJPEGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let image = renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }

    @Test
    func coordinatorInitializesWithSplitEnabledByDefault() throws {
        let (coordinator, _) = try makeCoordinator()
        #expect(coordinator.splitIntoSeparateReceipts)
    }

    @Test
    func saveReceiptReturnsOneWhenSingleFileIsSaved() async throws {
        let (coordinator, context) = try makeCoordinator()
        coordinator.files = [
            ImportedFile(
                data: try makeJPEGData(),
                contentType: .jpeg,
                originalFileName: "receipt.jpg",
                thumbnail: nil
            )
        ]

        let savedCount = await coordinator.saveReceipt(
            note: nil,
            tripReferenceId: nil,
            tripReferenceExternalId: nil,
            tripReferenceName: nil
        )

        #expect(savedCount == 1)

        let descriptor = FetchDescriptor<LocalReceipt>()
        let receipts = try context.fetch(descriptor)
        #expect(receipts.count == 1)
        #expect(receipts.first?.pages.count == 1)
    }

    @Test
    func splitModeProducesOneReceiptPerFileWithSharedMetadata() async throws {
        let (coordinator, context) = try makeCoordinator()
        coordinator.splitIntoSeparateReceipts = true
        coordinator.files = try (0..<3).map { i in
            ImportedFile(
                data: try makeJPEGData(),
                contentType: .jpeg,
                originalFileName: "file-\(i).jpg",
                thumbnail: nil
            )
        }

        let tripId = UUID()
        let savedCount = await coordinator.saveReceipt(
            note: "shared note",
            tripReferenceId: tripId,
            tripReferenceExternalId: "TRIP-9",
            tripReferenceName: "Trip 9"
        )

        #expect(savedCount == 3)

        let receipts = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(receipts.count == 3)
        for receipt in receipts {
            #expect(receipt.pages.count == 1)
            #expect(receipt.pages.first?.sortOrder == 0)
            #expect(receipt.note == "shared note")
            #expect(receipt.tripReferenceId == tripId)
            #expect(receipt.tripReferenceExternalId == "TRIP-9")
            #expect(receipt.tripReferenceName == "Trip 9")
        }
        let uniqueIds = Set(receipts.map(\.id))
        #expect(uniqueIds.count == 3)
    }

    @Test
    func combinedModeProducesOneMultiPageReceipt() async throws {
        let (coordinator, context) = try makeCoordinator()
        coordinator.splitIntoSeparateReceipts = false
        coordinator.files = try (0..<3).map { i in
            ImportedFile(
                data: try makeJPEGData(),
                contentType: .jpeg,
                originalFileName: "file-\(i).jpg",
                thumbnail: nil
            )
        }

        let savedCount = await coordinator.saveReceipt(
            note: nil,
            tripReferenceId: nil,
            tripReferenceExternalId: nil,
            tripReferenceName: nil
        )

        #expect(savedCount == 1)
        let receipts = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(receipts.count == 1)
        #expect(receipts.first?.pages.count == 3)
    }

    @Test
    func splitModeWithSingleFileSavesOneReceiptWithOnePage() async throws {
        let (coordinator, context) = try makeCoordinator()
        coordinator.splitIntoSeparateReceipts = true
        coordinator.files = [
            ImportedFile(
                data: try makeJPEGData(),
                contentType: .jpeg,
                originalFileName: "solo.jpg",
                thumbnail: nil
            )
        ]

        let savedCount = await coordinator.saveReceipt(
            note: nil,
            tripReferenceId: nil,
            tripReferenceExternalId: nil,
            tripReferenceName: nil
        )

        #expect(savedCount == 1)
        let receipts = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(receipts.count == 1)
        #expect(receipts.first?.pages.count == 1)
    }
}
