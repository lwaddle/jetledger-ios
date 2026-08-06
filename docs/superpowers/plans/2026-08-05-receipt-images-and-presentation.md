# Receipt Image Availability and Presentation Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a receipt's image visible whenever the device is online, stop list thumbnails decaying into placeholder glyphs, and fix two presentation defects — a swallowed Settings sheet and a capture session that resumes itself after backgrounding.

**Architecture:** Six independent changes against an existing SwiftUI + SwiftData iOS app. Decision logic is extracted into pure `enum` namespaces of static functions (the codebase's established pattern — see `ReceiptRowFormatting`) so it can be unit-tested without standing up a view. View files then call those functions. No new services, no new dependencies.

**Tech Stack:** Swift 6.2 / Xcode 26.2, SwiftUI, SwiftData, Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), `MockURLProtocol` for network fakes.

Source spec: `docs/superpowers/specs/2026-08-05-receipt-images-and-presentation-design.md`

## Global Constraints

- **Deployment target iOS 17.6.** Nothing may use an API newer than that. `.fileDialogDefaultDirectory(_:)` is iOS 17.0+ and is allowed.
- **Zero third-party dependencies.** Networking goes through the existing `APIClient` / `URLSession`.
- **All types are implicitly `@MainActor`** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). Do not add `@MainActor` annotations; do add `nonisolated` where a type already uses it.
- **`nonisolated` functions cannot use MainActor-isolated constants as default parameter values** — use literals.
- **`#Predicate` cannot use `.rawValue` on enums or `.uuidString` on UUIDs** — both crash at runtime. None of these tasks add a predicate; do not add one.
- **New files need no pbxproj edit** — the project uses `PBXFileSystemSynchronizedRootGroup`.
- **Test suites that touch `MockURLProtocol` must be nested in `extension MockURLProtocolSuites { ... }` and marked `@MainActor @Suite(.serialized)`** — the mock handler is a process-wide static.
- **A test harness must retain its `ModelContainer`.** `ModelContext` does not retain it, and a deallocated container traps inside SwiftData, failing *every* test in the run at 0.000s. Always return the container from a harness factory and hold it for the test's duration.
- **Build:**
  `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build`
- **Test** (needs an iOS 26.x runtime; test targets inherit the project's 26.2 deployment target):
  `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test`
  **`xcodebuild test` exits 0 on failures that occur before any test runs.** Never trust the exit status — grep the log for `** TEST SUCCEEDED **`.

**Task order:** 1 → 2 → 3 → 4 → 5 → 6. Tasks 1–4 are independently testable and can be reviewed in any order among themselves. Task 5 must land before Task 6 is hand-verified, so that any remaining Files-picker jump is attributable to picker state restoration rather than to a presentation race.

---

## File Structure

**Modified:**
- `JetLedger/Utilities/Constants.swift` — add `ReceiptList.thumbnailURLUsableFor`
- `JetLedger/Services/ReceiptListService.swift` — thumbnail grants become age-aware and merge instead of replacing
- `JetLedger/Views/Main/ReceiptRowView.swift` — read thumbnails through the new accessor; pass PDF-ness to the placeholder
- `JetLedger/Views/Main/ReceiptRowFormatting.swift` — PDF-aware placeholder glyph
- `JetLedger/Views/Detail/ReceiptDetailView.swift` — consume the new content rules, add a connectivity retry
- `JetLedger/Models/Enums.swift` — `CameraSessionState: Equatable`
- `JetLedger/Services/CameraSessionManager.swift` — session-ownership flag guarding the interruption handlers
- `JetLedger/Views/Main/MainView.swift` — one sheet modifier driven by an enum; deferred importer hand-off; default import directory

**Created:**
- `JetLedger/Views/Detail/ReceiptDetailContent.swift` — pure rules for "should we refetch" and "what does an image-less receipt say"
- `JetLedgerTests/ReceiptDetailContentTests.swift`
- `JetLedgerTests/CameraSessionManagerTests.swift`

**Test files extended:**
- `JetLedgerTests/ReceiptListServiceTests.swift`
- `JetLedgerTests/ReceiptRowFormattingTests.swift`

---

### Task 1: Thumbnail grants survive a refresh and expire on their own clock

**Problem being fixed:** `ReceiptListService.recordThumbnailURLs(from:replacingAll:)` clears the whole `thumbnailURLs` map whenever `requestedOffset == 0`. Every refresh is offset 0, so every refresh discards the presigned thumbnail of every row paged in beyond the first 25. Those rows drop to a glyph. Separately, the presigned URLs die after 15 minutes, and nothing notices — the row keeps issuing a request guaranteed to fail.

**Files:**
- Modify: `JetLedger/Utilities/Constants.swift:64-68`
- Modify: `JetLedger/Services/ReceiptListService.swift:32-36` (property), `:101` (call site), `:123-131` (method)
- Modify: `JetLedger/Views/Main/ReceiptRowView.swift:143-145`
- Test: `JetLedgerTests/ReceiptListServiceTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `AppConstants.ReceiptList.thumbnailURLUsableFor: TimeInterval`
  - `ReceiptListService.thumbnailURL(for serverReceiptId: UUID, now: Date = Date()) -> URL?`
  - `ReceiptListService.recordThumbnailURLs(from dtos: [ReceiptSummaryDTO])` — note the `replacingAll:` label is **gone**.
  - The stored property `thumbnailURLs` is **removed**; nothing outside the service may read the map directly.

---

- [ ] **Step 1: Write the failing tests**

Append these two tests inside the existing `struct ReceiptListServiceTests` in `JetLedgerTests/ReceiptListServiceTests.swift`, just before its closing brace. They use the existing `makePagingHarness()` factory.

```swift
    // MARK: - Thumbnail grant lifetime

    /// A refresh is always offset 0. Wiping the map on offset 0 discarded the
    /// thumbnail of every row paged in below the first page — which is exactly
    /// where the oldest (rejected) receipts live.
    @Test
    func aRefreshKeepsThumbnailsRecordedForLaterPages() async throws {
        let harness = try makePagingHarness()
        let accountId = UUID()
        let pageOneId = UUID(uuidString: "9f1c0000-0000-4000-8000-000000000001")!
        let pageTwoId = UUID(uuidString: "9f1c0000-0000-4000-8000-000000000002")!

        // Built before the handler and captured as plain Strings: the handler is
        // @Sendable and runs on URLSession's background queue, so capturing a
        // local helper function there does not compile under Swift 6.
        let firstPageBody = """
        {"receipts":[{
          "id":"\(pageOneId.uuidString.lowercased())","status":"pending","source":"ios",
          "ocr_status":"pending","image_count":1,
          "thumbnail_url":"https://r2.test/one",
          "created_at":"2026-07-27 14:03:22","updated_at":"2026-07-27 14:03:22"
        }],"total":50,"limit":25,"offset":0}
        """
        let secondPageBody = """
        {"receipts":[{
          "id":"\(pageTwoId.uuidString.lowercased())","status":"pending","source":"ios",
          "ocr_status":"pending","image_count":1,
          "thumbnail_url":"https://r2.test/two",
          "created_at":"2026-07-01 09:00:00","updated_at":"2026-07-01 09:00:00"
        }],"total":50,"limit":25,"offset":25}
        """

        MockURLProtocol.handler = { request in
            let isSecondPage = request.url?.query?.contains("offset=25") == true
            let body = isSecondPage ? secondPageBody : firstPageBody
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body.data(using: .utf8)!
            )
        }

        await harness.service.refresh(accountId: accountId)
        await harness.service.loadNextPage(accountId: accountId)
        #expect(harness.service.thumbnailURL(for: pageTwoId) != nil, "page two must be recorded")

        // The foreground refresh that used to wipe everything.
        await harness.service.refresh(accountId: accountId)

        #expect(harness.service.thumbnailURL(for: pageOneId) != nil)
        #expect(harness.service.thumbnailURL(for: pageTwoId) != nil,
                "a page-0 refresh must not discard a thumbnail recorded for a later page")
    }

    /// The server presigns these for 15 minutes. Past that the stored URL is a
    /// request guaranteed to fail, so the row should fall to its glyph instead.
    @Test
    func aThumbnailGrantPastItsUsableWindowReadsAsAbsent() async throws {
        let harness = try makePagingHarness()
        let accountId = UUID()
        let receiptId = UUID(uuidString: "9f1c0000-0000-4000-8000-000000000001")!

        respond("""
        {"receipts":[{
          "id":"\(receiptId.uuidString.lowercased())","status":"pending","source":"ios",
          "ocr_status":"pending","image_count":1,
          "thumbnail_url":"https://r2.test/one",
          "created_at":"2026-07-27 14:03:22","updated_at":"2026-07-27 14:03:22"
        }],"total":1,"limit":25,"offset":0}
        """)

        await harness.service.refresh(accountId: accountId)
        #expect(harness.service.thumbnailURL(for: receiptId) != nil)

        let pastExpiry = Date().addingTimeInterval(AppConstants.ReceiptList.thumbnailURLUsableFor + 60)
        #expect(harness.service.thumbnailURL(for: receiptId, now: pastExpiry) == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tail -40
```
Expected: compile failure — `value of type 'ReceiptListService' has no member 'thumbnailURL'` and `type 'AppConstants.ReceiptList' has no member 'thumbnailURLUsableFor'`. A compile failure is a valid red here; the API does not exist yet.

- [ ] **Step 3: Add the constant**

In `JetLedger/Utilities/Constants.swift`, replace the `ReceiptList` enum body:

```swift
    enum ReceiptList {
        /// Server default is 25 and it clamps to 1...100. Sent explicitly rather
        /// than relying on the default.
        static let pageSize = 25

        /// How long a presigned `thumbnail_url` is treated as usable. The server
        /// signs these for 15 minutes; the margin means a row falls back to its
        /// glyph rather than issuing a request that is already dead. Same shape
        /// as `Sync.uploadGrantUsableFor`.
        static let thumbnailURLUsableFor: TimeInterval = 14 * 60
    }
```

- [ ] **Step 4: Make the grants age-aware and merging**

In `JetLedger/Services/ReceiptListService.swift`, replace the `thumbnailURLs` property declaration (currently lines 32-36) with:

```swift
    /// A presigned row thumbnail and when it was fetched.
    private struct ThumbnailGrant {
        let url: URL
        let fetchedAt: Date
    }

    /// Presigned row thumbnails, keyed by server receipt id. Deliberately in
    /// memory and never persisted: these expire in 15 minutes, so a stored URL
    /// would outlive its own validity.
    ///
    /// Merged, never replaced. Replacing on the offset-0 fetch discarded the
    /// thumbnail of every row paged in below the first page — and since a
    /// refresh is always offset 0, the oldest receipts lost theirs on every
    /// foreground. The map is one URL per receipt the user has paged through in
    /// a session, which is not a size worth throwing away live data for.
    private var thumbnailGrants: [UUID: ThumbnailGrant] = [:]
```

Replace `recordThumbnailURLs` (currently lines 123-131) with:

```swift
    /// Keeps the presigned thumbnails for the rows just fetched, merging them
    /// into what is already known.
    private func recordThumbnailURLs(from dtos: [ReceiptSummaryDTO]) {
        let now = Date()
        for dto in dtos {
            guard let raw = dto.thumbnailUrl, let url = URL(string: raw) else { continue }
            thumbnailGrants[dto.id] = ThumbnailGrant(url: url, fetchedAt: now)
        }
    }

    /// The row's thumbnail, or nil once the grant has aged past the window the
    /// server signed it for. An aged-out grant reads as absent so the row shows
    /// its glyph instead of firing a request that cannot succeed.
    func thumbnailURL(for serverReceiptId: UUID, now: Date = Date()) -> URL? {
        guard let grant = thumbnailGrants[serverReceiptId] else { return nil }
        guard now.timeIntervalSince(grant.fetchedAt) < AppConstants.ReceiptList.thumbnailURLUsableFor
        else { return nil }
        return grant.url
    }
```

Update the call site at line 101 — drop the `replacingAll:` argument:

```swift
            recordThumbnailURLs(from: response.receipts)
```

- [ ] **Step 5: Point the row view at the accessor**

In `JetLedger/Views/Main/ReceiptRowView.swift`, replace the `thumbnailURL` computed property (lines 143-145):

```swift
    /// Absent for on-device rows, for server rows the API had no displayable
    /// thumbnail for, and for rows whose presigned grant has aged out — all
    /// normal states, not errors.
    private var thumbnailURL: URL? {
        receipt.serverReceiptId.flatMap { receiptListService.thumbnailURL(for: $0) }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tee /tmp/jl-test.log | tail -40
grep -c '\*\* TEST SUCCEEDED \*\*' /tmp/jl-test.log
```
Expected: the grep prints `1`. If it prints `0`, the run failed regardless of the exit status.

- [ ] **Step 7: Commit**

```bash
git add JetLedger/Utilities/Constants.swift JetLedger/Services/ReceiptListService.swift \
        JetLedger/Views/Main/ReceiptRowView.swift JetLedgerTests/ReceiptListServiceTests.swift
git commit -m "fix: stop a list refresh discarding thumbnails for later pages

A refresh is always offset 0, and recordThumbnailURLs wiped the map on
offset 0, so every foreground dropped the thumbnail of every row below
the first page — where the oldest receipts live. Grants now merge and
carry their own fetch time, so an aged-out URL reads as absent instead
of firing a request that cannot succeed."
```

---

### Task 2: A PDF row's placeholder reads as a PDF, not as a broken image

**Problem being fixed:** The server withholds `thumbnail_url` for a PDF until its page-1 JPEG has been rendered, and that render only happens at OCR ingest or when someone opens the receipt card on the web. An iOS-uploaded PDF that has had neither shows a generic `doc.fill` glyph indefinitely, which reads as a missing image. It is not — it is a PDF the server has no preview for. (The server-side gap is out of scope here; it lives in the web repo.)

**Files:**
- Modify: `JetLedger/Views/Main/ReceiptRowFormatting.swift:36-49`
- Modify: `JetLedger/Views/Main/ReceiptRowView.swift:173-178`
- Test: `JetLedgerTests/ReceiptRowFormattingTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `ReceiptRowFormatting.placeholderIcon(source:imagesCleanedUp:isPDF:) -> String`, where `isPDF` defaults to `false` so existing call sites and tests keep compiling.

---

- [ ] **Step 1: Write the failing tests**

Append to `JetLedgerTests/ReceiptRowFormattingTests.swift`, inside `struct ReceiptRowFormattingTests`, after the existing `cleanedUpImagesKeepTheRetentionGlyph` test:

```swift
    /// The server withholds thumbnail_url for a PDF until its page-1 JPEG has
    /// been rendered, which for an iOS upload may never happen. The generic
    /// glyph read as a broken image; this says "PDF" instead, which is true.
    @Test
    func aPDFWithNoThumbnailGetsTheDocumentGlyph() {
        #expect(ReceiptRowFormatting.placeholderIcon(
            source: .ios, imagesCleanedUp: false, isPDF: true) == "doc.richtext")
        #expect(ReceiptRowFormatting.placeholderIcon(
            source: .email, imagesCleanedUp: false, isPDF: true) == "doc.richtext")
    }

    /// Retention's glyph still explains the absence better than the file type.
    @Test
    func retentionGlyphOutranksThePDFGlyph() {
        #expect(ReceiptRowFormatting.placeholderIcon(
            source: .ios, imagesCleanedUp: true, isPDF: true) == "clock.badge.checkmark")
    }

    /// The new parameter defaults, so every existing caller is unaffected.
    @Test
    func nonPDFRowsKeepTheirSourceGlyph() {
        #expect(ReceiptRowFormatting.placeholderIcon(
            source: .email, imagesCleanedUp: false, isPDF: false) == "envelope.fill")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tail -40
```
Expected: compile failure — `extra argument 'isPDF' in call`.

- [ ] **Step 3: Add the parameter**

In `JetLedger/Views/Main/ReceiptRowFormatting.swift`, replace `placeholderIcon` (lines 36-49):

```swift
    /// The thumbnail placeholder for a receipt with no image on disk.
    ///
    /// For receipts this app never created, the glyph is the only signal that a
    /// receipt the pilot doesn't remember capturing arrived by email or from the
    /// web. Retention's own glyph wins when it applies — "these were cleaned up"
    /// explains the absence better than the source does.
    ///
    /// A PDF outranks the source glyph in turn: the server withholds
    /// `thumbnail_url` for a PDF until its page-1 JPEG has been rendered, which
    /// for an iOS upload that has not been through OCR or opened on the web may
    /// never happen. `doc.fill` there reads as a broken image rather than as a
    /// document with no preview.
    static func placeholderIcon(
        source: ReceiptSource?,
        imagesCleanedUp: Bool,
        isPDF: Bool = false
    ) -> String {
        if imagesCleanedUp { return "clock.badge.checkmark" }
        if isPDF { return "doc.richtext" }
        switch source {
        case .email: return "envelope.fill"
        case .upload: return "tray.and.arrow.up.fill"
        case .ios, nil: return "doc.fill"
        }
    }
```

- [ ] **Step 4: Pass PDF-ness from the row view**

In `JetLedger/Views/Main/ReceiptRowView.swift`, replace the `placeholderIcon` computed property (lines 173-178):

```swift
    /// A local row knows its own content type; a mirrored row has no page
    /// records until its detail is fetched, so the list's mime type is the only
    /// thing that knows.
    private var isPDF: Bool {
        if receipt.pages.contains(where: { $0.contentType == .pdf }) { return true }
        return receipt.firstImageMimeType == PageContentType.pdf.rawValue
    }

    private var placeholderIcon: String {
        ReceiptRowFormatting.placeholderIcon(
            source: receipt.source,
            imagesCleanedUp: receipt.imagesCleanedUp,
            isPDF: isPDF
        )
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tee /tmp/jl-test.log | tail -40
grep -c '\*\* TEST SUCCEEDED \*\*' /tmp/jl-test.log
```
Expected: prints `1`.

- [ ] **Step 6: Commit**

```bash
git add JetLedger/Views/Main/ReceiptRowFormatting.swift JetLedger/Views/Main/ReceiptRowView.swift \
        JetLedgerTests/ReceiptRowFormattingTests.swift
git commit -m "fix: a PDF row with no server thumbnail shows a document glyph

The API withholds thumbnail_url for a PDF until its page-1 JPEG exists,
and for an iOS upload that never went through OCR nothing renders one.
doc.fill read as a broken image; doc.richtext plus the existing PDF badge
reads as what it is."
```

---

### Task 3: The detail view stops surrendering while online

**Problem being fixed:** `ReceiptDetailView` shows `ContentUnavailableView("Images Removed")` whenever every page lacks bytes and no error was raised. Re-downloading runs only through `ReceiptImageDownloader.downloadMissingImages`, which skips any page with `serverFilePath == nil`. `serverFilePath` is written only by `ReceiptMirror.upsertDetail`, and the detail fetch that calls it runs only when `detailFetchedAt == nil`. So a row whose detail was fetched once without acquiring file paths can never fetch detail again, never acquire them, and never download — it shows "Images Removed" permanently, online, with the bytes sitting in R2. Retention is aggressive enough to make this common: `AppConstants.Cleanup.defaultImageRetentionDays` is **7**.

**Files:**
- Create: `JetLedger/Views/Detail/ReceiptDetailContent.swift`
- Create: `JetLedgerTests/ReceiptDetailContentTests.swift`
- Modify: `JetLedger/Views/Detail/ReceiptDetailView.swift:12-22` (environment), `:65-77` (empty state), `:90-92` (task), `:259-263` (refetch condition)

**Interfaces:**
- Consumes: nothing from Tasks 1-2.
- Produces:
  - `enum ReceiptDetailContent`
  - `ReceiptDetailContent.EmptyState` — cases `.retryable`, `.offline`, `.noImage`
  - `static func needsDetailFetch(_ receipt: LocalReceipt) -> Bool`
  - `static func emptyState(for receipt: LocalReceipt, isConnected: Bool) -> EmptyState`

---

- [ ] **Step 1: Write the failing tests**

Create `JetLedgerTests/ReceiptDetailContentTests.swift`:

```swift
//
//  ReceiptDetailContentTests.swift
//  JetLedgerTests
//
//  Covers the rules that decide whether a receipt's images can still be
//  recovered, and what an image-less receipt is allowed to say.
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

@MainActor
@Suite
struct ReceiptDetailContentTests {

    /// Returns the container too: `ModelContext` does not retain it, and a model
    /// whose container has been deallocated traps on access.
    private struct Harness {
        let context: ModelContext
        let container: ModelContainer
    }

    private func makeHarness() throws -> Harness {
        let schema = Schema([
            LocalReceipt.self, LocalReceiptPage.self,
            CachedAccount.self, CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return Harness(context: container.mainContext, container: container)
    }

    @discardableResult
    private func makeReceipt(
        in harness: Harness,
        serverReceiptId: UUID? = UUID(),
        detailFetchedAt: Date? = nil,
        imageCount: Int = 1,
        pages: [(downloaded: Bool, serverFilePath: String?)] = []
    ) -> LocalReceipt {
        let receipt = LocalReceipt(
            accountId: UUID(), capturedAt: Date(), syncStatus: .uploaded
        )
        receipt.serverReceiptId = serverReceiptId
        receipt.detailFetchedAt = detailFetchedAt
        receipt.imageCount = imageCount
        harness.context.insert(receipt)
        for (index, spec) in pages.enumerated() {
            let page = LocalReceiptPage(
                sortOrder: index, localImagePath: "receipts/x/page-00\(index + 1).jpg"
            )
            page.imageDownloaded = spec.downloaded
            page.serverFilePath = spec.serverFilePath
            harness.context.insert(page)
            page.receipt = receipt
        }
        return receipt
    }

    // MARK: - needsDetailFetch

    @Test
    func aReceiptWhoseDetailWasNeverFetchedNeedsAFetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(in: harness, detailFetchedAt: nil, pages: [(true, nil)])
        #expect(ReceiptDetailContent.needsDetailFetch(receipt))
    }

    /// The dead end this task exists to close: detail was fetched once, the
    /// pages never got a serverFilePath out of it, so the downloader skips them
    /// forever and the old condition never refetched.
    @Test
    func aPageMissingBytesAndAFilePathForcesAnotherDetailFetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), pages: [(false, nil)]
        )
        #expect(ReceiptDetailContent.needsDetailFetch(receipt),
                "a page with no bytes and no file path must refetch to learn where its bytes live")
    }

    @Test
    func aPageMissingBytesButKnowingItsFilePathDoesNotRefetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), pages: [(false, "r2/key.jpg")]
        )
        #expect(!ReceiptDetailContent.needsDetailFetch(receipt),
                "the downloader can already act on this — no second detail request")
    }

    @Test
    func aReceiptWithItsBytesOnDiskDoesNotRefetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), pages: [(true, "r2/key.jpg")]
        )
        #expect(!ReceiptDetailContent.needsDetailFetch(receipt))
    }

    /// The server says there are images and this row has no page records to
    /// download into. Refetching is the only way to get them.
    @Test
    func aRowWithNoPagesButAServerImageCountRefetches() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), imageCount: 2, pages: []
        )
        #expect(ReceiptDetailContent.needsDetailFetch(receipt))
    }

    @Test
    func aRowWithNoPagesAndNoServerImagesDoesNotRefetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), imageCount: 0, pages: []
        )
        #expect(!ReceiptDetailContent.needsDetailFetch(receipt),
                "there is nothing to fetch — refetching on every open would be a loop")
    }

    // MARK: - emptyState

    /// Online with a server record, we should have downloaded and did not.
    /// That is a failure the user can retry, not a fact about disk space.
    @Test
    func onlineWithAServerRecordTheEmptyStateIsRetryable() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(in: harness, pages: [(false, "r2/key.jpg")])
        #expect(ReceiptDetailContent.emptyState(for: receipt, isConnected: true) == .retryable)
    }

    @Test
    func offlineTheEmptyStateBlamesConnectivity() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(in: harness, pages: [(false, "r2/key.jpg")])
        #expect(ReceiptDetailContent.emptyState(for: receipt, isConnected: false) == .offline)
    }

    /// Nothing was ever uploaded, so there is genuinely nothing to fetch.
    @Test
    func aReceiptWithNoServerRecordHasNothingToFetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(in: harness, serverReceiptId: nil, pages: [(false, nil)])
        #expect(ReceiptDetailContent.emptyState(for: receipt, isConnected: true) == .noImage)
        #expect(ReceiptDetailContent.emptyState(for: receipt, isConnected: false) == .noImage)
    }

    /// Detail was fetched and the server reported no images at all. Offering a
    /// Try Again button here would promise something that cannot happen.
    @Test
    func aFetchedReceiptTheServerHasNoImagesForIsNotRetryable() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), imageCount: 0, pages: []
        )
        #expect(ReceiptDetailContent.emptyState(for: receipt, isConnected: true) == .noImage)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tail -40
```
Expected: compile failure — `cannot find 'ReceiptDetailContent' in scope`.

- [ ] **Step 3: Create the rules**

Create `JetLedger/Views/Detail/ReceiptDetailContent.swift`:

```swift
//
//  ReceiptDetailContent.swift
//  JetLedger
//

import Foundation

/// Decides whether a receipt's images are still recoverable, and what an
/// image-less receipt is allowed to say. Pure functions so the rules can be
/// tested without standing up a view, matching `ReceiptRowFormatting`.
enum ReceiptDetailContent {

    /// What the detail view shows when no page has bytes on disk.
    enum EmptyState: Equatable {
        /// Online, and the server has a copy: a download should have happened
        /// and did not. Offer a retry rather than an explanation.
        case retryable
        /// Offline. The bytes exist on the server and will arrive with signal.
        case offline
        /// There is nothing anywhere to fetch — never uploaded, or the server
        /// reports no images for it. The only terminal case.
        case noImage
    }

    /// Whether `GET /api/receipts/{id}` should run before attempting a download.
    ///
    /// The last clause is load-bearing. `serverFilePath` is written only by
    /// `ReceiptMirror.upsertDetail`, and `ReceiptImageDownloader` silently skips
    /// any page without one. Keying the refetch on `detailFetchedAt == nil`
    /// alone left a dead end: a row whose detail was fetched once without
    /// acquiring file paths could never fetch again, never acquire them, and
    /// never download — it showed "Images Removed" permanently, online, with
    /// the bytes sitting in R2.
    ///
    /// The middle clause covers the same hole from the other side: the server
    /// says this receipt has images and there are no page records to download
    /// into, so the detail response is the only thing that can create them.
    /// Both are bounded by `imageCount` so a receipt that genuinely has no
    /// images does not refetch on every open.
    static func needsDetailFetch(_ receipt: LocalReceipt) -> Bool {
        if receipt.detailFetchedAt == nil { return true }
        if receipt.pages.isEmpty { return receipt.imageCount > 0 }
        return receipt.pages.contains { !$0.imageDownloaded && $0.serverFilePath == nil }
    }

    /// Reachable only when no page has bytes. Reads connectivity rather than
    /// retention: the user cannot act on "we reclaimed your disk", and being
    /// told so about a receipt whose image is one request away is worse than
    /// useless — it reads as data loss.
    static func emptyState(for receipt: LocalReceipt, isConnected: Bool) -> EmptyState {
        guard receipt.serverReceiptId != nil else { return .noImage }
        // Detail came back and the server reported no images. A Try Again
        // button here would promise something that cannot happen.
        if receipt.detailFetchedAt != nil, receipt.pages.isEmpty, receipt.imageCount == 0 {
            return .noImage
        }
        return isConnected ? .retryable : .offline
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tee /tmp/jl-test.log | tail -40
grep -c '\*\* TEST SUCCEEDED \*\*' /tmp/jl-test.log
```
Expected: prints `1`.

- [ ] **Step 5: Wire the detail view to the rules**

In `JetLedger/Views/Detail/ReceiptDetailView.swift`:

**(a)** After the existing `@Environment(ReceiptImageDownloader.self) private var imageDownloader` line (line 14), add:

```swift
    @Environment(NetworkMonitor.self) private var networkMonitor
```

**(b)** Replace the `else if receipt.pages.isEmpty || ...` branch (lines 65-77) with:

```swift
            } else if receipt.pages.isEmpty || receipt.pages.allSatisfy({ !$0.imageDownloaded }) {
                emptyImageState
            } else {
```

**(c)** Add this computed property just after `body` closes (after line 112), before the `// MARK: - Actions Menu` comment:

```swift
    // MARK: - Empty Image State

    /// Nothing on disk. What that means depends on connectivity, not on
    /// retention: a receipt whose bytes are one request away must never be
    /// described as having had its images removed.
    @ViewBuilder
    private var emptyImageState: some View {
        switch ReceiptDetailContent.emptyState(
            for: receipt, isConnected: networkMonitor.isConnected
        ) {
        case .retryable:
            ContentUnavailableView {
                Label("Couldn't Load Image", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("The receipt image didn't download. Try again.")
            } actions: {
                Button("Try Again") {
                    Task { await loadRemoteContentIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(.brandPrimary))
            }
            .frame(maxHeight: .infinity)

        case .offline:
            ContentUnavailableView {
                Label("Image Not Downloaded", systemImage: "wifi.slash")
            } description: {
                Text("Connect to the internet to view this receipt.")
            }
            .frame(maxHeight: .infinity)

        case .noImage:
            ContentUnavailableView {
                Label("No Image", systemImage: "photo")
            } description: {
                Text("This receipt has no image.")
            }
            .frame(maxHeight: .infinity)
        }
    }
```

**(d)** Replace the `needsPages` line inside `loadRemoteContentIfNeeded` (line 261):

```swift
        let needsPages = ReceiptDetailContent.needsDetailFetch(receipt)
```

**(e)** Add a connectivity retry. Immediately after the existing `.task(id: receipt.id) { ... }` modifier (lines 90-92), add:

```swift
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            // A receipt opened offline fills itself in when signal returns,
            // rather than making the user back out and re-enter.
            guard isConnected, receipt.pages.contains(where: { !$0.imageDownloaded })
            else { return }
            Task { await loadRemoteContentIfNeeded() }
        }
```

- [ ] **Step 6: Build and test**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tee /tmp/jl-test.log | tail -40
grep -c '\*\* TEST SUCCEEDED \*\*' /tmp/jl-test.log
```
Expected: build succeeds; grep prints `1`.

If the build fails with "the compiler is unable to type-check this expression in reasonable time" pointing anywhere in `ReceiptDetailView.body`, the `@ViewBuilder` extraction in step (c) is the mitigation — confirm the switch really lives in its own computed property and not inline in `body`.

- [ ] **Step 7: Commit**

```bash
git add JetLedger/Views/Detail/ReceiptDetailContent.swift \
        JetLedger/Views/Detail/ReceiptDetailView.swift \
        JetLedgerTests/ReceiptDetailContentTests.swift
git commit -m "fix: a receipt's image is fetched whenever the device is online

serverFilePath is written only by upsertDetail, the downloader skips any
page without one, and the detail refetch was gated on detailFetchedAt
being nil. A row that got fetched once without acquiring file paths was
therefore stuck showing 'Images Removed' forever, online, with its bytes
in R2. The refetch now also triggers on a page that lacks both bytes and
a path, and the empty state reads connectivity instead of retention —
'removed to save space' described an implementation detail the user
cannot act on and could not have been true."
```

---

### Task 4: The capture session stops resuming itself

**Problem being fixed:** `CameraSessionManager` observes `AVCaptureSession.interruptionEndedNotification` and calls `startRunning()` unconditionally, with no check that any camera UI is on screen. Backgrounding the app interrupts the session; foregrounding fires interruption-ended and restarts the camera behind the receipt list. Nothing schedules a stop, because `scheduleStop(after:)` is only reached through `MainView.onChange(of: showCapture)`. Open the scanner once, background the app, return, and the iOS camera privacy indicator stays lit until the process dies. The `wasInterrupted` handler shares the flaw: it sets `state = .failed` even when no camera UI exists, poisoning the state the next capture flow reads.

**Files:**
- Modify: `JetLedger/Models/Enums.swift:161`
- Modify: `JetLedger/Services/CameraSessionManager.swift:19-25` (state), `:35-73` (observers), `:165-203` (start/stop)
- Create: `JetLedgerTests/CameraSessionManagerTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `CameraSessionState: Equatable`
  - `CameraSessionManager.isSessionWanted: Bool` (`private(set)`)
  - `CameraSessionManager.handleInterruption()` and `CameraSessionManager.handleInterruptionEnded()` — internal, called by the notification observers and directly by tests.

---

- [ ] **Step 1: Write the failing tests**

Create `JetLedgerTests/CameraSessionManagerTests.swift`:

```swift
//
//  CameraSessionManagerTests.swift
//  JetLedgerTests
//
//  Covers session ownership: an AVCaptureSession must never resume unless
//  something actually asked for it.
//

import Testing
import Foundation
@testable import JetLedger

@MainActor
@Suite
struct CameraSessionManagerTests {

    /// The bug this guards: backgrounding the app interrupts the session, and
    /// foregrounding fired interruptionEnded, which restarted the camera behind
    /// the receipt list with no UI and nothing to ever stop it. The iOS privacy
    /// indicator then stayed lit for the life of the process.
    @Test
    func interruptionEndedDoesNotResumeASessionNobodyAskedFor() {
        let manager = CameraSessionManager()
        #expect(!manager.isSessionWanted)

        manager.handleInterruptionEnded()

        #expect(!manager.isSessionWanted)
        #expect(manager.state == .idle, "no capture UI exists — nothing should have started")
    }

    /// An interruption with no camera on screen must not leave `.failed` behind
    /// for the next capture flow to read.
    @Test
    func anInterruptionWithNoCaptureUIDoesNotPoisonTheState() {
        let manager = CameraSessionManager()

        manager.handleInterruption()

        #expect(manager.state == .idle)
    }

    /// The flag is what the handlers key off, so it has to track the two calls
    /// that bracket a capture flow.
    @Test
    func startingAndStoppingTracksSessionOwnership() {
        let manager = CameraSessionManager()

        manager.startRunning()
        #expect(manager.isSessionWanted)

        manager.stopRunning()
        #expect(!manager.isSessionWanted)
    }
}
```

The positive path — a *wanted* session still surfacing an interruption as
`.failed("Camera is in use by another app")` — is deliberately **not** unit
tested. On the simulator there is no camera, so `startRunning()` dispatches a
configuration that fails asynchronously and writes `state` from a background
hop; asserting `state` after `startRunning()` races that write and produces a
flaky test. That path is covered by the hand-verification step below instead.
The tests above cover the actual regression, which is resuming a session nobody
asked for.

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tail -40
```
Expected: compile failure — `value of type 'CameraSessionManager' has no member 'isSessionWanted'`, plus `binary operator '==' cannot be applied to two 'CameraSessionState' operands`.

- [ ] **Step 3: Make the state comparable**

In `JetLedger/Models/Enums.swift`, line 161:

```swift
enum CameraSessionState: Sendable, Equatable {
```

- [ ] **Step 4: Add session ownership**

In `JetLedger/Services/CameraSessionManager.swift`:

**(a)** After the `private var stopWorkItem: DispatchWorkItem?` declaration (line 19), add:

```swift
    /// Whether anything currently wants the capture session running. Set by
    /// `startRunning`, cleared by `stopRunning`.
    ///
    /// The interruption handlers key off this. Without it, backgrounding the app
    /// interrupted the session and foregrounding resumed it — behind the receipt
    /// list, with no capture UI and nothing scheduled to stop it, leaving the
    /// iOS camera indicator lit for the life of the process.
    @ObservationIgnored
    private(set) var isSessionWanted = false
```

**(b)** Replace `observeSessionNotifications` (lines 35-73) with:

```swift
    /// Without these, a phone call or Split View camera preemption freezes the
    /// preview with state stuck at .running and the shutter enabled, and an
    /// AVCaptureSession runtime error (e.g. media services reset) kills the
    /// session permanently while the UI still claims the camera is live.
    ///
    /// Every handler is gated on `isSessionWanted`: these fire for a session
    /// nobody is looking at just as readily as for a live capture flow.
    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: captureSession, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleInterruption()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: captureSession, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleInterruptionEnded()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleRuntimeError()
            }
        })
    }

    /// Reports an interruption only for a session someone asked for. An
    /// interruption with no camera on screen used to leave `.failed` behind for
    /// the next capture flow to read.
    func handleInterruption() {
        guard isSessionWanted else { return }
        state = .failed("Camera is in use by another app")
    }

    /// Resumes only a session someone asked for.
    func handleInterruptionEnded() {
        guard isSessionWanted else { return }
        startRunning()
    }

    private func handleRuntimeError() {
        guard isSessionWanted else { return }
        // One restart attempt; if the session won't come back, surface it.
        sessionQueue.async {
            if self.isConfigured, !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
            let running = self.captureSession.isRunning
            DispatchQueue.main.async {
                self.state = running
                    ? .running
                    : .failed("Camera error — close and reopen the scanner")
            }
        }
    }
```

**(c)** In `startRunning()` (line 165), set the flag as the first statement, before `cancelScheduledStop()`:

```swift
    func startRunning() {
        isSessionWanted = true
        cancelScheduledStop()
        sessionQueue.async { [self] in
```

**(d)** In `stopRunning()` (line 193), clear the flag as the first statement — before the `sessionQueue.async` block, so it is cleared even when the guard inside short-circuits:

```swift
    func stopRunning() {
        isSessionWanted = false
        sessionQueue.async { [self] in
```

`scheduleStop(after:)` is deliberately unchanged: it leaves `isSessionWanted` set until the work item actually fires `stopRunning()`, so re-entering the capture flow inside the 30-second window still reads as wanted.

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tee /tmp/jl-test.log | tail -40
grep -c '\*\* TEST SUCCEEDED \*\*' /tmp/jl-test.log
```
Expected: prints `1`.

Note on the simulator: `performConfiguration` fails there (no camera), so `startRunning()` sets the flag and then bails at its `guard isConfigured`. The tests assert the flag and the state transitions, which is exactly the regression surface — they do not depend on a running session.

- [ ] **Step 6: Verify by hand on a physical device**

A simulator has no camera and no privacy indicator, so this step needs real hardware.

1. Launch the app. The camera indicator must be **off** on the receipt list.
2. Tap **Scan Receipt**. The indicator comes on. Close the scanner and wait 30 seconds — it must go off.
3. Tap **Scan Receipt** again, then background the app (swipe up) and return. Close the scanner, wait 30 seconds — the indicator must go off, and **must not come back**.
4. Repeat step 3 but background and return *after* closing the scanner. The indicator must stay off the whole time. This is the reported bug.
5. Confirm the interruption path still reports: with the scanner open, swipe down Control Center and start a camera-using app or take a call. The scanner must show "Camera is in use by another app" rather than a frozen preview.

- [ ] **Step 7: Commit**

```bash
git add JetLedger/Models/Enums.swift JetLedger/Services/CameraSessionManager.swift \
        JetLedgerTests/CameraSessionManagerTests.swift
git commit -m "fix: the capture session no longer resumes itself in the background

interruptionEnded called startRunning() unconditionally. Backgrounding
interrupts the session, so foregrounding restarted the camera behind the
receipt list with no capture UI and nothing scheduled to stop it — the
iOS camera indicator stayed lit for the life of the process. Both
interruption handlers and the runtime-error handler now require that
something actually asked for the session."
```

---

### Task 5: One sheet modifier, and the importer hands off after dismissal

**Problem being fixed:** `MainView.withPresentations` stacks four presentation modifiers on the same `NavigationSplitView` — `.fullScreenCover`, two `.sheet(isPresented:)`, and `.fileImporter` (itself a sheet). SwiftUI reliably services one presentation per view. The concrete trigger is `MainView.swift:128-130`, which sets `showImport = true` **synchronously inside the `.fileImporter` completion**, requesting a new sheet while the picker is still dismissing. That request is swallowed and leaves the presentation machinery in a state that eats the *next* request — the Settings gear tap. It matches the reported intermittency: the gear misbehaves after an import round-trip.

**Files:**
- Modify: `JetLedger/Views/Main/MainView.swift:25-35` (state), `:105-135` (presentations), `:137-156` (observers), `:342-349` (import button)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `MainView.ActiveSheet` (private). `showImport` and `showSettings` are **removed**; nothing outside `MainView` referenced them.

---

- [ ] **Step 1: Replace the two sheet flags with one enum**

In `JetLedger/Views/Main/MainView.swift`, delete the `@State private var showImport = false` and `@State private var showSettings = false` declarations (lines 26 and 33), and add above `private var canUpload` (line 37):

```swift
    /// One sheet slot, not two. SwiftUI reliably services a single presentation
    /// per view, and this view already carries a `.fullScreenCover` and a
    /// `.fileImporter` alongside. Two independent `.sheet(isPresented:)`
    /// modifiers contending for that slot is how a Settings tap gets swallowed.
    private enum ActiveSheet: Identifiable {
        case importFlow
        case settings

        var id: Int {
            switch self {
            case .importFlow: 0
            case .settings: 1
            }
        }
    }

    @State private var activeSheet: ActiveSheet?
```

- [ ] **Step 2: Point the gear at it**

Replace the toolbar button's action (line 71) so it reads:

```swift
                        Button {
                            activeSheet = .settings
                        } label: {
```

- [ ] **Step 3: Collapse the presentation modifiers**

Replace the whole `withPresentations` computed property (lines 105-135) with:

```swift
    private var withPresentations: some View {
        splitView
        .fullScreenCover(isPresented: $showCapture) {
            if let account = accountService.selectedAccount {
                CaptureFlowView(accountId: account.id, cameraSessionManager: cameraSessionManager)
            }
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
            switch sheet {
            case .importFlow:
                if let account = accountService.selectedAccount {
                    ImportFlowView(accountId: account.id, urls: importedURLs)
                }
            case .settings:
                SettingsView(isOfflineMode: isOfflineMode)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf, .jpeg, .png, .heic],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }

    /// The importer's completion runs while the document picker is still
    /// dismissing. Presenting the import sheet from inside it requested a new
    /// presentation mid-teardown: the request was swallowed, and the machinery
    /// was left confused enough to eat the *next* one — which is how a Settings
    /// tap did nothing. Hopping to the next runloop turn lets the dismissal
    /// finish first.
    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        importedURLs = urls
        if let directory = urls.first?.deletingLastPathComponent() {
            lastImportDirectoryPath = directory.absoluteString
        }
        Task { activeSheet = .importFlow }
    }

    /// Was `onChange(of: showImport)`. `.sheet(item:)`'s `onDismiss` does not
    /// say which item closed, so this now runs for Settings too. That widening
    /// is deliberate and safe: `processQueue` is idempotent and no-ops with an
    /// empty queue, and `importedURLs` is only read while the import sheet is
    /// up. Reconstructing "which sheet was that" to avoid a free no-op would
    /// cost more than it saves.
    private func handleSheetDismiss() {
        importedURLs = []
        if !isOfflineMode {
            syncService.processQueue()
        }
    }
```

Note: `handleFileImport` writes `lastImportDirectoryPath`, which Task 6 introduces. **Add the storage declaration now** so this task builds on its own — put it next to the other `@State` declarations:

```swift
    /// Where the user last imported from, so the document picker opens there
    /// instead of visibly restoring its own location. Consumed in Task 6.
    @AppStorage("lastImportDirectory") private var lastImportDirectoryPath: String = ""
```

`MainView` already imports SwiftUI, so `@AppStorage` needs no new import.

- [ ] **Step 4: Drop the now-dead observer**

In `withStateObservers` (lines 137-156), delete the entire `.onChange(of: showImport) { ... }` modifier — `handleSheetDismiss` replaces it. Leave `.onChange(of: showCapture)` exactly as it is; it drives `cameraSessionManager.scheduleStop(after: 30)` and is unrelated.

- [ ] **Step 5: Build**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```
Expected: build succeeds with no output.

If it fails with "the compiler is unable to type-check this expression in reasonable time", the multi-statement closures went inline instead of into the `handleFileImport` / `handleSheetDismiss` methods. `MainView.body` is split into stages precisely because it has hit that budget before — see the comment at lines 45-56. Keep closures one-liners that call a method.

- [ ] **Step 6: Run the full test suite for regressions**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tee /tmp/jl-test.log | tail -40
grep -c '\*\* TEST SUCCEEDED \*\*' /tmp/jl-test.log
```
Expected: prints `1`. There is no unit coverage for SwiftUI presentation; this run is a regression check only.

- [ ] **Step 7: Verify by hand on a simulator or device**

1. Launch the app and sign in.
2. Tap **Import from Files**, pick a PDF, let the import sheet appear, and dismiss it.
3. Tap the **gear** once. Settings must open on the first tap.
4. Repeat the import round-trip twice more, tapping the gear once each time.
5. Tap **Scan Receipt**, dismiss, then tap the gear once — it must still open first try.

- [ ] **Step 8: Commit**

```bash
git add JetLedger/Views/Main/MainView.swift
git commit -m "fix: Settings opens on the first tap after an import

MainView stacked a fullScreenCover, two sheets and a fileImporter on one
NavigationSplitView, and the importer completion presented the import
sheet synchronously while the picker was still dismissing. That request
was swallowed and left the presentation machinery eating the next one —
the gear tap. One enum-driven sheet slot, and the hand-off waits for the
dismissal to finish."
```

---

### Task 6: The Files picker opens where the user last was

**Problem being fixed:** `UIDocumentPickerViewController` restores its last-used location asynchronously — it presents on its default browse screen, queries the file providers, then navigates once that resolves. `.fileImporter` at `MainView.swift:122` passes no start directory, so the restore is visible as an unprompted jump about three seconds in.

A fixed pin is deliberately rejected: "On My iPhone" is wrong for a user whose receipts live in iCloud Drive, and the app's own sandbox Documents directory contains only `receipts/` internals. Persisting the last-used parent directory lands the picker where the user actually keeps files, with no jump. If a stored URL no longer resolves, the picker falls back to today's behavior — so the failure mode costs nothing.

**Files:**
- Modify: `JetLedger/Views/Main/MainView.swift` — the `.fileImporter` modifier added in Task 5

**Interfaces:**
- Consumes: `MainView.lastImportDirectoryPath` (the `@AppStorage` declared in Task 5) and `MainView.handleFileImport(_:)`, which already writes it.
- Produces: nothing consumed elsewhere.

---

- [ ] **Step 1: Read the stored directory back**

In `JetLedger/Views/Main/MainView.swift`, add next to `canUpload`:

```swift
    /// Where the picker should open. Nil on first run, which is the one time
    /// the user sees the system's own location restore.
    private var lastImportDirectory: URL? {
        guard !lastImportDirectoryPath.isEmpty else { return nil }
        return URL(string: lastImportDirectoryPath)
    }
```

- [ ] **Step 2: Pin the picker's start location**

Add `.fileDialogDefaultDirectory(_:)` to the `.fileImporter` in `withPresentations`. It must come after the `.fileImporter` modifier it configures:

```swift
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf, .jpeg, .png, .heic],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        // Without a start location the picker presents on its browse screen and
        // then visibly navigates to its restored location a few seconds later.
        // Pinning the last-used directory makes that instant and correct; an
        // unresolvable URL falls back to exactly the previous behavior.
        .fileDialogDefaultDirectory(lastImportDirectory)
```

`handleFileImport` already records the directory — no change needed there.

- [ ] **Step 3: Build**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```
Expected: build succeeds. `.fileDialogDefaultDirectory(_:)` is iOS 17.0+, inside the 17.6 target — no availability annotation needed.

- [ ] **Step 4: Run the full test suite for regressions**

Run:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tee /tmp/jl-test.log | tail -40
grep -c '\*\* TEST SUCCEEDED \*\*' /tmp/jl-test.log
```
Expected: prints `1`.

- [ ] **Step 5: Verify by hand**

1. Launch, tap **Import from Files**. First run may still restore its location — expected once.
2. Navigate to a folder, pick a file, complete or cancel the import.
3. Tap **Import from Files** again. It must open **directly** in that folder, with no delayed jump.
4. Force-quit the app and repeat step 3 — `@AppStorage` persists, so it must still land there.

- [ ] **Step 6: Commit**

```bash
git add JetLedger/Views/Main/MainView.swift
git commit -m "fix: the Files picker opens where the user last imported from

UIDocumentPickerViewController restores its last location asynchronously,
so the picker presented on its browse screen and then navigated on its
own a few seconds later. Pinning the remembered directory makes that
instant, and lands somewhere true for a user whose files are in iCloud
Drive rather than On My iPhone."
```

---

## Final Verification

- [ ] **Full clean build and test**

```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tee /tmp/jl-test.log | tail -60
grep -c '\*\* TEST SUCCEEDED \*\*' /tmp/jl-test.log
```

- [ ] **On-device pass against the reviewer demo account**

1. Open a receipt whose images were reclaimed — it must show the image, not "Images Removed".
2. Turn on Airplane Mode and open an undownloaded receipt — "Image Not Downloaded / Connect to the internet to view this receipt". Turn Airplane Mode off without leaving the screen; the image must fill in on its own.
3. Scroll past 25 receipts, pull to refresh, scroll back down — thumbnails on later pages must survive.
4. A PDF row with no server thumbnail shows the `doc.richtext` glyph plus its PDF badge.
5. Import round-trip, then one gear tap opens Settings.
6. Second and subsequent **Import from Files** taps open directly in the last-used folder.
7. Open the scanner, close it, background the app, return, and wait 30 seconds — the camera indicator must be off.

- [ ] **Update `CLAUDE.md`**

Two documented behaviors changed and one server-side gap is worth recording. Add to the **Sync & Upload** section:

```markdown
- **A receipt's image is fetched whenever the device is online.** Retention still
  reclaims disk (`imageRetentionDays`, default 7), but the detail view treats an
  image-less receipt as a fetch to perform, not a fact to report.
  `ReceiptDetailContent.needsDetailFetch` refetches detail when a page lacks both
  bytes and a `serverFilePath` — keying only on `detailFetchedAt == nil` left a
  dead end where a row could never learn where its bytes lived, and showed
  "Images Removed" permanently with the object sitting in R2. The empty state
  now reads connectivity: offline says so, online offers a retry. Fixed
  2026-08-05.
- **Row thumbnail grants merge and expire on their own clock.** `thumbnailURLs`
  used to be wiped on every offset-0 fetch, and a refresh is always offset 0, so
  each foreground discarded the thumbnail of every row past the first page.
  `ReceiptListService.thumbnailURL(for:)` now ages entries out at
  `AppConstants.ReceiptList.thumbnailURLUsableFor` (14m, under the server's 15m
  signature) instead.
- **The server withholds `thumbnail_url` for a PDF until its page-1 JPEG exists**,
  and that render only happens at OCR ingest or when the card is opened on the
  web. An iOS-uploaded PDF with neither has no thumbnail indefinitely; the row
  shows `doc.richtext` rather than pretending an image failed. The real fix is
  server-side (web repo).
```

And to **Camera & Image Processing**:

```markdown
- `CameraSessionManager.isSessionWanted` gates every interruption handler. Without
  it, backgrounding interrupted the session and foregrounding resumed it behind
  the receipt list with no capture UI and nothing to stop it, leaving the iOS
  camera indicator lit for the life of the process. Fixed 2026-08-05.
```

Commit:

```bash
git add CLAUDE.md
git commit -m "docs: record image-availability and camera-session fixes"
```
