# Receipt Row Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace note-titled receipt rows (which mostly render "No note") with date-led rows: smart capture-date title, optional note/trip lines, portrait thumbnail with corner badges, and a quiet processed status.

**Architecture:** Display-only change. A new nonisolated `ReceiptDateFormatter` enum produces the smart title (unit-tested). `ReceiptRowView` is restructured around it; `SyncStatusBadge` gains an opt-in compact mode used only by the row. Stored thumbnails are already 96×128 portrait — no pipeline changes.

**Tech Stack:** SwiftUI, Swift Testing (`import Testing`), Xcode 26.2 / Swift 6.2 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

**Design doc:** `docs/plans/2026-07-20-receipt-row-redesign-design.md`

**Build command** (used throughout):

```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```

**Test command:**

```sh
xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet -only-testing:JetLedgerTests/ReceiptDateFormatterTests
```

Note: this repo uses `PBXFileSystemSynchronizedRootGroup` — new files are picked up automatically, no pbxproj edits.

---

### Task 1: `ReceiptDateFormatter` (TDD)

**Files:**
- Create: `JetLedgerTests/ReceiptDateFormatterTests.swift`
- Create: `JetLedger/Utilities/ReceiptDateFormatter.swift`

**Step 1: Write the failing tests**

`JetLedgerTests/ReceiptDateFormatterTests.swift`:

```swift
//
//  ReceiptDateFormatterTests.swift
//  JetLedgerTests
//

import Foundation
import Testing
@testable import JetLedger

struct ReceiptDateFormatterTests {

    // Fixed reference point: Mon Jul 20, 2026, 14:00 local time.
    private let calendar = Calendar.current
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 14))!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9, minute: Int = 5) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func sameDayIsTodayWithTime() {
        let title = ReceiptDateFormatter.rowTitle(for: date(2026, 7, 20), now: now, calendar: calendar)
        #expect(title.hasPrefix("Today, "))
        #expect(title.contains("9"))  // time component present
    }

    @Test func previousDayIsYesterdayWithTime() {
        let title = ReceiptDateFormatter.rowTitle(for: date(2026, 7, 19), now: now, calendar: calendar)
        #expect(title.hasPrefix("Yesterday, "))
    }

    @Test func sameYearShowsMonthDayAndTimeButNoYear() {
        let title = ReceiptDateFormatter.rowTitle(for: date(2026, 7, 12), now: now, calendar: calendar)
        #expect(title.contains("12"))
        #expect(!title.contains("2026"))
        #expect(!title.hasPrefix("Today"))
        #expect(!title.hasPrefix("Yesterday"))
    }

    @Test func priorYearShowsYearWithoutTime() {
        let title = ReceiptDateFormatter.rowTitle(for: date(2025, 12, 3), now: now, calendar: calendar)
        #expect(title.contains("2025"))
        #expect(!title.contains(":"))  // no time on prior-year dates
    }

    /// Year boundary: Dec 31 vs Jan 1 are different years but only a day apart —
    /// Dec 31 captured yesterday must still say "Yesterday", not "Dec 31, 2025".
    @Test func yesterdayWinsAcrossYearBoundary() {
        let jan1 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10))!
        let dec31 = date(2025, 12, 31)
        let title = ReceiptDateFormatter.rowTitle(for: dec31, now: jan1, calendar: calendar)
        #expect(title.hasPrefix("Yesterday, "))
    }
}
```

**Step 2: Run tests to verify they fail**

Run the test command above.
Expected: FAIL — `cannot find 'ReceiptDateFormatter' in scope` (compile error in test target).

**Step 3: Write the implementation**

`JetLedger/Utilities/ReceiptDateFormatter.swift`:

```swift
//
//  ReceiptDateFormatter.swift
//  JetLedger
//

import Foundation

/// Formats a receipt's capture date as a row title. A receipt has no merchant
/// or amount in v1, so the capture date is the row's primary identity.
nonisolated enum ReceiptDateFormatter {

    static func rowTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)

        if calendar.isDate(date, inSameDayAs: now) {
            return "Today, \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            let monthDay = date.formatted(.dateTime.month(.abbreviated).day())
            return "\(monthDay), \(time)"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
```

Notes for the implementer:
- `nonisolated` matters — the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the formatter is pure and the tests are not `@MainActor`.
- Hardcoded "Today"/"Yesterday" matches the app's existing hardcoded-English strings ("No note", "Waiting to upload"). Do not introduce a localization system.

**Step 4: Run tests to verify they pass**

Run the test command.
Expected: `Test Suite 'ReceiptDateFormatterTests' passed` — 5 tests pass.

**Step 5: Commit**

```bash
git add JetLedger/Utilities/ReceiptDateFormatter.swift JetLedgerTests/ReceiptDateFormatterTests.swift
git commit -m "feat(list): add ReceiptDateFormatter for date-led row titles"
```

---

### Task 2: Quiet processed state in `SyncStatusBadge`

**Files:**
- Modify: `JetLedger/Components/SyncStatusBadge.swift`

No unit test — pure SwiftUI presentation; covered by the build and Task 4's visual check.

**Step 1: Add the compact mode**

`SyncStatusBadge` is also used by `ReceiptDetailView`, which must keep full labels — so the new behavior is opt-in with a default that preserves existing call sites.

Replace the property list and `body` (lines 10–18) with:

```swift
struct SyncStatusBadge: View {
    let syncStatus: SyncStatus
    let serverStatus: ServerStatus?
    /// List rows pass true: a processed receipt in the Completed section needs
    /// only a quiet checkmark, not a labeled badge. Detail view keeps the label.
    var compactWhenProcessed: Bool = false

    var body: some View {
        if compactWhenProcessed && serverStatus == .processed {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .accessibilityLabel(label)
        } else {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
        }
    }
```

Leave `icon`, `label`, and `color` computed properties untouched.

**Step 2: Build**

Run the build command.
Expected: succeeds; `ReceiptDetailView` and `ReceiptRowView` call sites compile unchanged (new property has a default).

**Step 3: Commit**

```bash
git add JetLedger/Components/SyncStatusBadge.swift
git commit -m "feat(list): quiet icon-only processed state for SyncStatusBadge"
```

---

### Task 3: Restructure `ReceiptRowView`

**Files:**
- Modify: `JetLedger/Views/Main/ReceiptRowView.swift` (full-file rewrite below)

**Step 1: Rewrite the view**

Replace the entire contents of `ReceiptRowView.swift` with:

```swift
//
//  ReceiptRowView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct ReceiptRowView: View {
    let receipt: LocalReceipt

    var body: some View {
        HStack(spacing: 12) {
            ReceiptThumbnail(receipt: receipt)

            VStack(alignment: .leading, spacing: 3) {
                Text(ReceiptDateFormatter.rowTitle(for: receipt.capturedAt))
                    .font(.headline)
                    .lineLimit(1)

                if let note = receipt.note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let tripLabel {
                    Text(tripLabel)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                SyncStatusBadge(
                    syncStatus: receipt.syncStatus,
                    serverStatus: receipt.serverStatus,
                    compactWhenProcessed: true
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var tripLabel: String? {
        if let tripId = receipt.tripReferenceExternalId {
            return "Trip \(tripId)"
        }
        return receipt.tripReferenceName
    }
}

// MARK: - Thumbnail

private struct ReceiptThumbnail: View {
    let receipt: LocalReceipt

    private static let size = CGSize(width: 45, height: 60)

    var body: some View {
        Group {
            if let firstPage = sortedPages.first,
               let image = ImageUtils.loadReceiptImage(relativePath: ImageUtils.thumbnailPath(for: firstPage.localImagePath)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .overlay {
                        Image(systemName: placeholderIcon)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(2)
            }
        }
    }

    private var sortedPages: [LocalReceiptPage] {
        receipt.pages.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Page count wins over the PDF tag on multi-page receipts — "how much is
    /// here" matters more in the list than the file format.
    private var badge: String? {
        if receipt.pages.count > 1 {
            return "\(receipt.pages.count)"
        }
        if receipt.pages.contains(where: { $0.contentType == .pdf }) {
            return "PDF"
        }
        return nil
    }

    private var placeholderIcon: String {
        receipt.imagesCleanedUp ? "clock.badge.checkmark" : "doc.fill"
    }
}
```

What changed vs. the old file, for review purposes:
- Title is the smart date (always present) — `"No note"` placeholder is gone.
- Note and trip reference are independent optional lines (a note no longer hides the trip).
- Thumbnail is 45×60 portrait (stored thumbs are 96×128, so no new cropping), radius 8, border applied once via a shared `.overlay`.
- Trailing "PDF"/"N pages" capsules removed; replaced by a single corner badge on the thumbnail.
- `SyncStatusBadge` gets `compactWhenProcessed: true`.

**Step 2: Build**

Run the build command.
Expected: succeeds with no warnings in the changed files.

**Step 3: Commit**

```bash
git add JetLedger/Views/Main/ReceiptRowView.swift
git commit -m "feat(list): date-led receipt rows with portrait thumbnails"
```

---

### Task 4: Visual verification

**Step 1: Run the app in the simulator**

Boot simulator `BE3394BC-9EE2-452E-8770-CA021987D8F0`, install and launch the build (the `/run` skill or `xcrun simctl` install/launch). Verify against the design doc:

- No row anywhere shows "No note".
- Rows with only a date render one title line + status; note and trip rows show their extra lines.
- Multi-page receipt shows a count badge on the thumbnail corner; single-page PDF shows "PDF".
- Processed rows in Completed show a lone green checkmark; a rejected row still shows loud red "Rejected".
- Thumbnails are portrait and receipts read as receipts (no square mid-crop).
- Dark mode: badge material and status colors hold up (toggle appearance in Settings or `simctl ui <udid> appearance dark`).

**Step 2: Fix anything that looks off, rebuild, re-verify, amend or add commits as needed.**
