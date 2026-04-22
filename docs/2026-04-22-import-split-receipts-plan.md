# Import: Split Bulk File Selection Into Separate Receipts — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let the user choose, per import, whether multiple picked files become one multi-page receipt or N separate receipts.

**Architecture:** Add a `splitIntoSeparateReceipts` toggle (default `true`) to `ImportFlowCoordinator`. A toggle in `ImportPreviewView` surfaces it when `files.count > 1`. `saveReceipt(...)` branches: combined path saves today's single multi-page receipt; split path loops and saves one single-page receipt per file, all sharing the note + trip reference. Return type changes from `LocalReceipt?` to `Int` (saved count).

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, iOS 17.6 target. Test framework: Swift Testing. In-memory `ModelContainer` for unit tests (pattern already used in `JetLedgerTests.swift`).

**Design doc:** `docs/2026-04-22-import-split-receipts-design.md`

---

### Task 1: Add unit test scaffolding for `ImportFlowCoordinator`

**Files:**
- Create: `JetLedgerTests/ImportFlowCoordinatorTests.swift`

**Step 1: Write the skeleton with one smoke test**

```swift
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
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JetLedgerTests/ImportFlowCoordinatorTests/coordinatorInitializesWithSplitEnabledByDefault`

Expected: FAIL — `splitIntoSeparateReceipts` is not a member of `ImportFlowCoordinator`.

**Step 3: Add the property**

Modify `JetLedger/Views/Import/ImportFlowCoordinator.swift:19-23`:

```swift
@Observable
class ImportFlowCoordinator {
    var currentStep: ImportStep = .preview
    var files: [ImportedFile] = []
    var splitIntoSeparateReceipts: Bool = true
    var isSaving = false
    var error: String?
```

**Step 4: Run test to verify it passes**

Run same command as Step 2. Expected: PASS.

**Step 5: Commit**

```bash
git add JetLedger/Views/Import/ImportFlowCoordinator.swift JetLedgerTests/ImportFlowCoordinatorTests.swift
git commit -m "test(import): scaffold ImportFlowCoordinator tests and add split toggle state"
```

---

### Task 2: Change `saveReceipt` return type from `LocalReceipt?` to `Int`

This is a pure refactor to clean up the return signature before adding the split branch. No behavior change.

**Files:**
- Modify: `JetLedger/Views/Import/ImportFlowCoordinator.swift:91-184`
- Modify: `JetLedger/Views/Import/ImportMetadataView.swift:133-150`
- Modify: `JetLedgerTests/ImportFlowCoordinatorTests.swift`

**Step 1: Write the failing test for the combined path**

Append to `ImportFlowCoordinatorTests.swift`:

```swift
    @Test
    func saveReceiptReturnsOneWhenSingleFileIsSaved() async throws {
        let (coordinator, context) = try makeCoordinator()
        coordinator.files = [
            ImportedFile(
                data: makeJPEGData(),
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
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JetLedgerTests/ImportFlowCoordinatorTests/saveReceiptReturnsOneWhenSingleFileIsSaved`

Expected: FAIL — `saveReceipt` returns `LocalReceipt?`, not `Int`, so `savedCount == 1` won't type-check.

**Step 3: Change the signature**

In `ImportFlowCoordinator.swift`, change the `saveReceipt` declaration:

```swift
func saveReceipt(
    note: String?,
    tripReferenceId: UUID?,
    tripReferenceExternalId: String?,
    tripReferenceName: String?
) async -> Int {
    guard !files.isEmpty else { return 0 }
    isSaving = true
    defer { isSaving = false }
```

And its return statements:

- Replace the early `guard !receiptPages.isEmpty else { ... return nil }` with `return 0` after setting `error`.
- Replace the `catch { ... return nil }` after `modelContext.save()` with `return 0` after setting `error`.
- Replace the final `return receipt` with `return 1`.

**Step 4: Update the sole caller**

In `ImportMetadataView.swift:137-148`, replace:

```swift
let receipt = await coordinator.saveReceipt(...)
if receipt != nil {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    onDone()
} else {
    errorMessage = coordinator.error ?? "Failed to save receipt. Please try again."
}
```

with:

```swift
let savedCount = await coordinator.saveReceipt(...)
if savedCount > 0 {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    onDone()
} else {
    errorMessage = coordinator.error ?? "Failed to save receipt. Please try again."
}
```

**Step 5: Run tests and build**

```
xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JetLedgerTests/ImportFlowCoordinatorTests
```

Expected: both tests PASS.

Then full build check:

```
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```

Expected: BUILD SUCCEEDED.

**Step 6: Commit**

```bash
git add JetLedger/Views/Import/ImportFlowCoordinator.swift JetLedger/Views/Import/ImportMetadataView.swift JetLedgerTests/ImportFlowCoordinatorTests.swift
git commit -m "refactor(import): return saved-count Int from saveReceipt"
```

---

### Task 3: Add the split-save branch in `saveReceipt`

**Files:**
- Modify: `JetLedger/Views/Import/ImportFlowCoordinator.swift`
- Modify: `JetLedgerTests/ImportFlowCoordinatorTests.swift`

**Step 1: Write the failing test**

Append to `ImportFlowCoordinatorTests.swift`:

```swift
    @Test
    func splitModeProducesOneReceiptPerFileWithSharedMetadata() async throws {
        let (coordinator, context) = try makeCoordinator()
        coordinator.splitIntoSeparateReceipts = true
        coordinator.files = (0..<3).map { i in
            ImportedFile(
                data: makeJPEGData(),
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
        // Each receipt has its own UUID-scoped directory
        let uniqueIds = Set(receipts.map(\.id))
        #expect(uniqueIds.count == 3)
    }

    @Test
    func combinedModeProducesOneMultiPageReceipt() async throws {
        let (coordinator, context) = try makeCoordinator()
        coordinator.splitIntoSeparateReceipts = false
        coordinator.files = (0..<3).map { i in
            ImportedFile(
                data: makeJPEGData(),
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
                data: makeJPEGData(),
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
```

**Step 2: Run tests to verify two of the three fail**

Run: `xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JetLedgerTests/ImportFlowCoordinatorTests`

Expected:
- `combinedModeProducesOneMultiPageReceipt` PASSES (current behavior is always-combine).
- `splitModeProducesOneReceiptPerFileWithSharedMetadata` FAILS — only one receipt with 3 pages exists.
- `splitModeWithSingleFileSavesOneReceiptWithOnePage` PASSES (one file is one receipt either way).

**Step 3: Implement the split branch**

Replace the body of `saveReceipt` in `ImportFlowCoordinator.swift:91-184` with:

```swift
func saveReceipt(
    note: String?,
    tripReferenceId: UUID?,
    tripReferenceExternalId: String?,
    tripReferenceName: String?
) async -> Int {
    guard !files.isEmpty else { return 0 }
    isSaving = true
    defer { isSaving = false }

    let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    let finalNote = (trimmedNote?.isEmpty == false) ? trimmedNote : nil

    if splitIntoSeparateReceipts && files.count > 1 {
        var savedCount = 0
        for file in files {
            if saveOneSingleFileReceipt(
                file: file,
                note: finalNote,
                tripReferenceId: tripReferenceId,
                tripReferenceExternalId: tripReferenceExternalId,
                tripReferenceName: tripReferenceName
            ) {
                savedCount += 1
            }
        }

        if savedCount == 0 {
            error = "Failed to save imported files."
            return 0
        }

        do {
            try modelContext.save()
            return savedCount
        } catch {
            self.error = "Failed to save receipts: \(error.localizedDescription)"
            return 0
        }
    }

    // Combined path (today's behavior): one receipt with N pages.
    let receiptId = UUID()
    var receiptPages: [LocalReceiptPage] = []

    for (index, file) in files.enumerated() {
        if let page = persistPage(file: file, receiptId: receiptId, pageIndex: index) {
            receiptPages.append(page)
        }
    }

    guard !receiptPages.isEmpty else {
        error = "Failed to save imported files."
        return 0
    }

    let receipt = LocalReceipt(
        id: receiptId,
        accountId: accountId,
        note: finalNote,
        tripReferenceId: tripReferenceId,
        tripReferenceExternalId: tripReferenceExternalId,
        tripReferenceName: tripReferenceName,
        capturedAt: Date(),
        enhancementMode: .original,
        syncStatus: .queued,
        pages: receiptPages
    )

    modelContext.insert(receipt)
    for page in receiptPages {
        page.receipt = receipt
        modelContext.insert(page)
    }

    do {
        try modelContext.save()
        return 1
    } catch {
        self.error = "Failed to save receipt: \(error.localizedDescription)"
        return 0
    }
}

// MARK: - Persistence helpers (private)

private func saveOneSingleFileReceipt(
    file: ImportedFile,
    note: String?,
    tripReferenceId: UUID?,
    tripReferenceExternalId: String?,
    tripReferenceName: String?
) -> Bool {
    let receiptId = UUID()
    guard let page = persistPage(file: file, receiptId: receiptId, pageIndex: 0) else {
        return false
    }

    let receipt = LocalReceipt(
        id: receiptId,
        accountId: accountId,
        note: note,
        tripReferenceId: tripReferenceId,
        tripReferenceExternalId: tripReferenceExternalId,
        tripReferenceName: tripReferenceName,
        capturedAt: Date(),
        enhancementMode: .original,
        syncStatus: .queued,
        pages: [page]
    )

    modelContext.insert(receipt)
    page.receipt = receipt
    modelContext.insert(page)
    return true
}

private func persistPage(
    file: ImportedFile,
    receiptId: UUID,
    pageIndex: Int
) -> LocalReceiptPage? {
    switch file.contentType {
    case .pdf:
        guard let relativePath = ImageUtils.saveReceiptPDF(
            data: file.data,
            receiptId: receiptId,
            pageIndex: pageIndex
        ) else { return nil }

        _ = ImageUtils.savePDFThumbnail(
            pdfData: file.data,
            receiptId: receiptId,
            pageIndex: pageIndex
        )

        return LocalReceiptPage(
            sortOrder: pageIndex,
            localImagePath: relativePath,
            contentType: .pdf
        )

    case .jpeg:
        guard let image = UIImage(data: file.data) else { return nil }
        let resized = ImageUtils.resizeIfNeeded(image)
        guard let jpegData = ImageUtils.compressToJPEG(resized) else { return nil }

        guard let relativePath = ImageUtils.saveReceiptImage(
            data: jpegData,
            receiptId: receiptId,
            pageIndex: pageIndex
        ) else { return nil }

        _ = ImageUtils.saveThumbnail(
            from: resized,
            receiptId: receiptId,
            pageIndex: pageIndex
        )

        return LocalReceiptPage(
            sortOrder: pageIndex,
            localImagePath: relativePath,
            contentType: .jpeg
        )
    }
}
```

Also remove the now-duplicated inline `trimmedNote` handling and the old `persistPage`-equivalent code that was inlined in the old `saveReceipt`.

**Step 4: Run tests**

Run: `xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JetLedgerTests/ImportFlowCoordinatorTests`

Expected: all 5 tests PASS.

**Step 5: Full build**

```
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```

Expected: BUILD SUCCEEDED.

**Step 6: Commit**

```bash
git add JetLedger/Views/Import/ImportFlowCoordinator.swift JetLedgerTests/ImportFlowCoordinatorTests.swift
git commit -m "feat(import): save picked files as separate receipts when split toggle is on"
```

---

### Task 4: Surface the toggle in `ImportPreviewView`

**Files:**
- Modify: `JetLedger/Views/Import/ImportPreviewView.swift`

**Step 1: Add the toggle**

Insert between the file count `Text` (line 15–17) and the `ScrollView` (line 20):

```swift
if coordinator.files.count > 1 {
    Toggle(isOn: Bindable(coordinator).splitIntoSeparateReceipts) {
        Text("Import as separate receipts")
            .font(.subheadline)
    }
    .padding(.horizontal, 32)

    if !coordinator.splitIntoSeparateReceipts {
        Text("Files will be combined into one multi-page receipt.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 32)
    }
}
```

Note: `Bindable(coordinator).splitIntoSeparateReceipts` produces the binding needed for `Toggle` because `ImportFlowCoordinator` is `@Observable`. If Swift complains about missing `@Bindable`, add `@Bindable var coordinator = coordinator` at the top of `body` instead, or change the property to `let coordinator: ImportFlowCoordinator` → `@Bindable var coordinator: ImportFlowCoordinator` (compare with how `@Observable` coordinators are bound elsewhere in the codebase — check `CaptureFlowView` for the established pattern).

**Step 2: Build and run in simulator**

```
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```

Expected: BUILD SUCCEEDED.

Manual verification — launch in the simulator and:
1. Open the Files importer, pick a single file → toggle is hidden (count ≤ 1), import proceeds as today (1 receipt).
2. Pick 3 files with the toggle ON (default) → after save, 3 new rows appear in the receipt list, each with single-page thumbnail.
3. Pick 3 files, flip the toggle OFF → caption "Files will be combined into one multi-page receipt." appears → after save, 1 new row appears with 3-page gallery.
4. Open each of the 3 split receipts → confirm note and trip reference (if you set them) match across all three.

**Step 3: Commit**

```bash
git add JetLedger/Views/Import/ImportPreviewView.swift
git commit -m "feat(import): add toggle to import picked files as separate receipts"
```

---

### Task 5: Add shared-metadata helper text in `ImportMetadataView`

**Files:**
- Modify: `JetLedger/Views/Import/ImportMetadataView.swift`

**Step 1: Add helper text under the form**

After the `TripReferencePicker` VStack (around line 55) and before `Spacer(minLength: 40)`, insert:

```swift
if coordinator.splitIntoSeparateReceipts && coordinator.files.count > 1 {
    Text("Applied to all \(coordinator.files.count) receipts — you can edit each individually later.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

**Step 2: Build**

```
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```

Expected: BUILD SUCCEEDED.

**Step 3: Manual verification**

- Pick 3 files, toggle ON → metadata screen shows "Applied to all 3 receipts — …".
- Pick 3 files, toggle OFF → helper text is hidden.
- Pick 1 file → helper text is hidden.

**Step 4: Commit**

```bash
git add JetLedger/Views/Import/ImportMetadataView.swift
git commit -m "feat(import): show shared-metadata notice when splitting into multiple receipts"
```

---

### Task 6: End-to-end smoke on device/simulator

Not a code task — a verification checklist before calling this done.

- [ ] iPhone simulator: single-file import → 1 receipt, no toggle visible.
- [ ] iPhone simulator: 4-file import, default (split ON) → 4 receipts in list, each with its own thumbnail and single page in detail view.
- [ ] iPhone simulator: 4-file import, split OFF → 1 receipt with 4 pages, gallery scrolls between them.
- [ ] iPhone simulator: 4-file import mixing JPEG and PDF, split ON → 4 receipts, PDF ones show PDF-style thumbnail and render in detail view.
- [ ] Sync: after each split-mode import, confirm all receipts reach `.processed` (or `.uploaded`) status — `SyncService` should queue each independently with no regressions.
- [ ] iPad simulator: same checks run in `NavigationSplitView` layout.
- [ ] Edit metadata on one split receipt → other split siblings remain unchanged (they were saved as independent rows, so this should just work).

If any step fails, capture the console log and file a follow-up task — do not attempt to fix in-line.
