# Import: Split Bulk File Selection Into Separate Receipts

**Date:** 2026-04-22
**Status:** Design approved, ready for implementation plan

## Problem

The "Import from Files" flow lets the user pick multiple files at once, but `ImportFlowCoordinator.handleImportedURLs` always bundles every picked file into a single multi-page `LocalReceipt`. That matches one valid intent (a genuinely multi-page receipt split across files), but it silently fails the more typical case: four picked files being four separate receipts. Users have no way to express that intent today.

## Goal

Let the user choose, per import, whether multiple picked files become one multi-page receipt or N separate receipts. Keep the UI lightweight and the default aligned with the more common case.

## Non-Goals

- Per-file grouping (e.g., "files 1+2 together, 3 alone, 4 alone"). That's a power feature; YAGNI for v1.
- Per-receipt metadata entry at import time. All split receipts share the note and trip reference entered on the metadata step; users edit individually via the existing detail edit sheet.
- Changes to the camera capture flow or the share extension — scoped to the Files picker import only.

## Design

### UX

**`ImportPreviewView`:**
- Add a `Toggle("Import as separate receipts", isOn: ...)` between the file count label and the thumbnail grid.
- Toggle is hidden when `coordinator.files.count <= 1` (moot).
- Default: **on** (separate receipts). Matches the more typical case.
- When the toggle is off and `files.count >= 2`, show a caption: "Files will be combined into one multi-page receipt."

**`ImportMetadataView`:**
- When `coordinator.splitIntoSeparateReceipts && coordinator.files.count > 1`, show helper text under the form: "Applied to all N receipts — you can edit each individually later."

**Post-save dismissal:**
- Unchanged from today — `ImportMetadataView` dismisses the sheet on success. User lands on the receipt list and sees either 1 new row (combined) or N new rows (split).

### State

Add to `ImportFlowCoordinator`:

```swift
var splitIntoSeparateReceipts: Bool = true
```

### Save behavior

`ImportFlowCoordinator.saveReceipt(...)` currently returns `LocalReceipt?` where `nil` means failure. Change the return type to `Int` (count of receipts saved, `0` means total failure). Cleaner semantics for the split case where the call produces N receipts rather than one.

- **Combined** (`!splitIntoSeparateReceipts` or `files.count == 1`): existing code path — one `LocalReceipt` with N `LocalReceiptPage`s at `sortOrder: 0..<N`. Returns `1` on success.
- **Split** (`splitIntoSeparateReceipts && files.count > 1`): loop over `files`, per file:
  - Fresh `receiptId = UUID()`.
  - Save bytes to `Documents/receipts/{receiptId}/page-000.{jpg|pdf}` (single page, `sortOrder: 0`).
  - Generate thumbnail at `page-000-thumb.jpg`.
  - Build a `LocalReceipt` with the shared `note` / `tripReferenceId` / `tripReferenceExternalId` / `tripReferenceName`, `capturedAt: Date()` (current time — all effectively simultaneous is fine), `enhancementMode: .original`, `syncStatus: .queued`, single-page `pages` array.
  - Insert receipt + page into `modelContext`.
- One `modelContext.save()` at the end for the whole batch (atomic from SwiftData's view, though not strictly required — partial success is acceptable).

### Partial failure

Preserve today's semantics: skip any file that fails to produce bytes or save to disk; error only if zero receipts were saved.

### Sync

No changes needed. Each saved `LocalReceipt` enters the upload queue independently via `SyncService`; the queue already processes receipts one-by-one.

## Callers to update

- `ImportMetadataView.save()` — replace the `receipt != nil` check with `savedCount > 0`; no navigation branching needed since the view already always dismisses on success.

## Testing

- Single-file import → toggle hidden, one receipt (combined path).
- Multi-file import, default toggle on → N separate receipts, each with one page, all with the same note/trip reference.
- Multi-file import, toggle off → one receipt with N pages (current behavior preserved).
- Multi-file import with mid-batch disk failure → remaining receipts saved, error not shown.
- Multi-file import where every file fails → error shown, no receipts created.
- Split mode: verify each receipt gets its own `Documents/receipts/{uuid}/` directory and the thumbnails resolve correctly in the list.
- Post-save navigation: split → list; combined → detail.
