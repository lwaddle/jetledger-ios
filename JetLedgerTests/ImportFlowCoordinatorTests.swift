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

    private func makeCoordinator() throws -> (ImportFlowCoordinator, ModelContext) {
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext
        let coordinator = ImportFlowCoordinator(accountId: UUID(), modelContext: context)
        return (coordinator, context)
    }

    // Builds a minimal 4x4 JPEG payload for fixture files.
    private func makeJPEGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let image = renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    @Test
    func coordinatorInitializesWithSplitEnabledByDefault() throws {
        let (coordinator, _) = try makeCoordinator()
        #expect(coordinator.splitIntoSeparateReceipts == true)
    }
}
