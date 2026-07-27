# Server-Driven Receipt List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the receipt list a view onto `GET /api/receipts` mirrored into SwiftData, so submission history survives reinstall, appears on every device, and includes receipts that arrived by email or web upload.

**Architecture:** Server rows are mirrored into the existing `LocalReceipt` / `LocalReceiptPage` models rather than held in a parallel store, so the list stays a `@Query` and works offline. A device's own uploads merge with their server row on `serverReceiptId`. Two long-dormant schema fields — `isRemote` and `imageDownloaded` — are revived with precise meanings. Images for receipts this device never captured are fetched on demand and cached to disk.

**Tech Stack:** Swift 6.2 / Xcode 26.2, SwiftUI, SwiftData, Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), native `URLSession` through the shared `APIClient`. Zero third-party dependencies.

**Design doc:** `docs/plans/2026-07-27-server-driven-receipt-list-design.md`

## Global Constraints

- **Deployment target iOS 17.6.** No iOS 18+ API. `@Attribute(.unique)`, never the `#Unique` macro.
- **All types are implicitly `@MainActor`** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). Do not add redundant `@MainActor` to types; do add it to test suites, matching `SyncServiceRetryTests`.
- **`#Predicate` cannot use `.rawValue` on enums or `.uuidString` on UUIDs** — both crash at runtime. Store raw `String` + `@Transient` typed accessor. Filter UUIDs beyond `accountId` in memory.
- **Zero third-party dependencies.** All networking through `APIClient`.
- **Receipt IDs are lowercased in URL paths.** `UUID.uuidString` is uppercase; the DB stores lowercase; SQLite comparison is case-sensitive.
- **Server timestamps are `"yyyy-MM-dd HH:mm:ss"`, UTC, no `T`, no zone suffix.** Never `ISO8601DateFormatter`.
- **`note`, `trip_reference_id`, `rejection_reason`, `expense_id` are `omitempty`** — the key is absent, not null. Decode as optionals.
- **File writes use `.completeFileProtectionUnlessOpen`.** `ImageUtils` already does this; use its helpers rather than writing files directly.
- **Suites touching `MockURLProtocol` must be nested in `extension MockURLProtocolSuites` and marked `@Suite(.serialized)`** — the handler is a process-wide static. Call `MockURLProtocol.reset()` in `init()`.
- **New files need no pbxproj edit** — the project uses `PBXFileSystemSynchronizedRootGroup`.

**Build and test** — both on the same destination:
```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' -quiet build
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test
```

> **Do not use the simulator id in `CLAUDE.md`** (`BE3394BC-…`, iPhone 16 / iOS 18.4). It builds, but
> `test` fails before running anything: *"iPhone 16's iOS Simulator 18.4 doesn't match
> JetLedgerTests's iOS Simulator 26.2 deployment target."* The app target deploys to iOS 17.6 but
> the **test** targets inherit the project's 26.2, so tests need an iOS 26.x runtime. The id above
> is iPhone 17 Pro / iOS 26.5 and was confirmed green (`** TEST SUCCEEDED **`) against `main` on
> 2026-07-27. `xcrun simctl list devices available | grep -A6 "iOS 26"` finds alternatives.
>
> `xcodebuild ... test` **exits 0 even when the build fails this way** — check the output for
> `** TEST SUCCEEDED **`, never the exit code.

Single suite: append `-only-testing:JetLedgerTests/MockURLProtocolSuites/<SuiteName>` (or `-only-testing:JetLedgerTests/<SuiteName>` for suites not nested under `MockURLProtocolSuites`).

**Endpoints are not deployed.** Everything is built against `MockURLProtocol`. No task in this plan can be verified against a live server.

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `JetLedger/Utilities/ServerDateFormatter.swift` | Parse the server's non-ISO timestamp format |
| `JetLedger/Services/ReceiptMirror.swift` | Reconciliation only: DTOs + `ModelContext` → upsert / prune. No networking. |
| `JetLedger/Services/ReceiptListService.swift` | Paging state machine and detail fetch |
| `JetLedger/Services/ReceiptImageDownloader.swift` | Bytes only: `download-url` → GET → disk → thumbnail |
| `JetLedger/Views/Main/ReceiptRowFormatting.swift` | Pure row-presentation helpers (trip label, placeholder glyph) |
| `JetLedgerTests/ServerDateFormatterTests.swift` | |
| `JetLedgerTests/ReceiptMirrorTests.swift` | |
| `JetLedgerTests/ReceiptListServiceTests.swift` | |
| `JetLedgerTests/ReceiptImageDownloaderTests.swift` | |
| `JetLedgerTests/ReceiptRetentionTests.swift` | |
| `JetLedgerTests/ReceiptRowFormattingTests.swift` | |

**Modify:** `Models/LocalReceipt.swift`, `Models/LocalReceiptPage.swift`, `Models/Enums.swift`, `Utilities/Constants.swift`, `Services/ReceiptAPIService.swift`, `Services/SyncService.swift`, `JetLedgerApp.swift`, `Views/Main/MainView.swift`, `Views/Main/ReceiptListView.swift`, `Views/Main/ReceiptRowView.swift`, `Views/Detail/ReceiptDetailView.swift`, `Views/Detail/ImageGalleryView.swift`

---

## Task 1: Server timestamp parsing

**Files:**
- Create: `JetLedger/Utilities/ServerDateFormatter.swift`
- Test: `JetLedgerTests/ServerDateFormatterTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `ServerDateFormatter.date(from: String) -> Date?`

- [ ] **Step 1: Write the failing test**

Create `JetLedgerTests/ServerDateFormatterTests.swift`. This suite does not touch `MockURLProtocol`, so it is not nested in `MockURLProtocolSuites`.

```swift
//
//  ServerDateFormatterTests.swift
//  JetLedgerTests
//
//  The server emits SQLite `datetime('now')` output, not ISO-8601. A formatter
//  misconfiguration here silently nils every timestamp in the receipt list.
//

import Testing
import Foundation
@testable import JetLedger

@Suite
struct ServerDateFormatterTests {

    @Test
    func parsesSQLiteDatetimeAsUTC() throws {
        let parsed = try #require(ServerDateFormatter.date(from: "2026-07-27 14:03:22"))

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)

        #expect(parts.year == 2026)
        #expect(parts.month == 7)
        #expect(parts.day == 27)
        #expect(parts.hour == 14, "a missing UTC timeZone shifts this by the device offset")
        #expect(parts.minute == 3)
        #expect(parts.second == 22)
    }

    @Test
    func rejectsISO8601Input() {
        #expect(ServerDateFormatter.date(from: "2026-07-27T14:03:22Z") == nil)
    }

    @Test
    func rejectsGarbage() {
        #expect(ServerDateFormatter.date(from: "") == nil)
        #expect(ServerDateFormatter.date(from: "not a date") == nil)
    }

    /// Without `en_US_POSIX`, a device on a non-Gregorian calendar parses every
    /// server timestamp as nil and the whole list loses its dates.
    @Test
    func parsesIdenticallyRegardlessOfDeviceCalendar() throws {
        let expected = try #require(ServerDateFormatter.date(from: "2026-07-27 14:03:22"))

        let buddhist = DateFormatter()
        buddhist.dateFormat = "yyyy-MM-dd HH:mm:ss"
        buddhist.timeZone = TimeZone(identifier: "UTC")
        buddhist.locale = Locale(identifier: "th_TH_u_ca_buddhist")
        let wrong = buddhist.date(from: "2026-07-27 14:03:22")

        #expect(wrong != expected,
                "sanity: a non-POSIX locale really does parse this differently")
        #expect(ServerDateFormatter.date(from: "2026-07-27 14:03:22") == expected)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/ServerDateFormatterTests`
Expected: FAIL to compile — "cannot find 'ServerDateFormatter' in scope"

- [ ] **Step 3: Write minimal implementation**

Create `JetLedger/Utilities/ServerDateFormatter.swift`:

```swift
//
//  ServerDateFormatter.swift
//  JetLedger
//

import Foundation

/// Parses the timestamps the Go API returns. They are SQLite `datetime('now')`
/// output — `"2026-07-27 14:03:22"`, UTC, space-separated, no `T` and no zone
/// suffix — so `ISO8601DateFormatter` fails on every one of them.
///
/// `en_US_POSIX` is not optional: without it a device set to a non-Gregorian
/// calendar parses these to nil and the receipt list loses all of its dates.
nonisolated enum ServerDateFormatter {

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/ServerDateFormatterTests`
Expected: PASS, 4 tests

- [ ] **Step 5: Commit**

```bash
git add JetLedger/Utilities/ServerDateFormatter.swift JetLedgerTests/ServerDateFormatterTests.swift
git commit -m "feat(api): parse the server's SQLite datetime timestamps"
```

---

## Task 2: Schema fields and enums

Revives `isRemote` and `imageDownloaded`, which have been inert since the Supabase-era sync was removed (`9fa35d7`, `bee082c`). Their existing defaults are load-bearing and asserted below.

**Files:**
- Modify: `JetLedger/Models/Enums.swift`
- Modify: `JetLedger/Models/LocalReceipt.swift`
- Modify: `JetLedger/Models/LocalReceiptPage.swift`
- Modify: `JetLedger/Utilities/Constants.swift`
- Test: `JetLedgerTests/ReceiptMirrorTests.swift` (created here, extended in Tasks 4–5)

**Interfaces:**
- Consumes: nothing
- Produces:
  - `enum ReceiptSource: String { case ios, email, upload }`
  - `enum OCRStatus: String { case pending, completed, failed }`
  - `LocalReceipt`: `serverCreatedAt: Date?`, `serverUpdatedAt: Date?`, `sourceRaw: String?`, `ocrStatusRaw: String?`, `expenseId: UUID?`, `imageCount: Int`, `detailFetchedAt: Date?`, `dismissedAt: Date?`, `source: ReceiptSource?`, `ocrStatus: OCRStatus?`
  - `LocalReceiptPage`: `serverImageId: UUID?`, `serverFilePath: String?`, `imageDownloadedAt: Date?`
  - `AppConstants.ReceiptList.pageSize: Int`

- [ ] **Step 1: Write the failing test**

Create `JetLedgerTests/ReceiptMirrorTests.swift`. No `MockURLProtocol` here — `ReceiptMirror` does no networking — so this suite is not nested.

```swift
//
//  ReceiptMirrorTests.swift
//  JetLedgerTests
//
//  Covers the schema fields the server mirror depends on and the reconciliation
//  rules that decide which local rows a server response may create, update, or
//  destroy.
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

@MainActor
@Suite
struct ReceiptMirrorTests {

    // MARK: - Harness

    static func makeContext() throws -> ModelContext {
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config]).mainContext
    }

    // MARK: - Schema defaults

    /// These defaults are what make the SwiftData migration lightweight: every
    /// pre-existing row is a local capture with bytes on disk, and the defaults
    /// must already say so without any migration code.
    @Test
    func existingRowDefaultsDescribeALocalCaptureWithFilesOnDisk() throws {
        let context = try Self.makeContext()
        let page = LocalReceiptPage(sortOrder: 0, localImagePath: "receipts/x/page-001.jpg")
        let receipt = LocalReceipt(accountId: UUID(), pages: [page])
        context.insert(receipt)

        #expect(receipt.isRemote == false, "a row with no server origin is a local capture")
        #expect(page.imageDownloaded == true, "an existing capture already has its bytes")
        #expect(receipt.dismissedAt == nil)
        #expect(receipt.detailFetchedAt == nil)
        #expect(receipt.imageCount == 0)
        #expect(page.serverFilePath == nil)
        #expect(page.imageDownloadedAt == nil)
    }

    @Test
    func typedAccessorsRoundTripThroughRawStrings() throws {
        let context = try Self.makeContext()
        let receipt = LocalReceipt(accountId: UUID())
        context.insert(receipt)

        receipt.source = .email
        receipt.ocrStatus = .completed

        #expect(receipt.sourceRaw == "email")
        #expect(receipt.ocrStatusRaw == "completed")
        #expect(receipt.source == .email)
        #expect(receipt.ocrStatus == .completed)
    }

    @Test
    func unknownRawValuesDecodeToNilRatherThanCrashing() throws {
        let context = try Self.makeContext()
        let receipt = LocalReceipt(accountId: UUID())
        context.insert(receipt)

        receipt.sourceRaw = "carrier_pigeon"
        receipt.ocrStatusRaw = "thinking"

        #expect(receipt.source == nil, "a future server value must not trap the app")
        #expect(receipt.ocrStatus == nil)
    }

    @Test
    func pageSizeIsWithinTheServersClampRange() {
        #expect(AppConstants.ReceiptList.pageSize >= 1)
        #expect(AppConstants.ReceiptList.pageSize <= 100)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/ReceiptMirrorTests`
Expected: FAIL to compile — `value of type 'LocalReceipt' has no member 'source'`, `no member 'dismissedAt'`, `no type 'ReceiptList' in 'AppConstants'`

- [ ] **Step 3: Add the enums**

In `JetLedger/Models/Enums.swift`, after the existing `ServerStatus` declaration:

```swift
/// How a staged receipt reached the server. Receipts with a source other than
/// `.ios` were never created by this app — they arrived by email forward or web
/// upload — and the list shows them anyway.
enum ReceiptSource: String, Codable, Sendable {
    case ios
    case email
    case upload
}

enum OCRStatus: String, Codable, Sendable {
    case pending
    case completed
    case failed
}
```

- [ ] **Step 4: Add the `LocalReceipt` fields**

In `JetLedger/Models/LocalReceipt.swift`, add after `firstFailedAt`:

```swift
    /// Server `created_at`. Kept separate from `capturedAt` because pruning has
    /// to reason in the server's ordering: a receipt captured offline on Monday
    /// and uploaded Friday has two different dates, and the server sorts by the
    /// second one.
    var serverCreatedAt: Date?
    var serverUpdatedAt: Date?
    /// Raw so `#Predicate` can filter on them; see the typed accessors below.
    var sourceRaw: String?
    var ocrStatusRaw: String?
    var expenseId: UUID?
    /// Server-owned page count, so a mirrored row can show a badge before its
    /// detail is fetched. Meaningless for rows that never uploaded.
    var imageCount: Int = 0
    /// Set once `GET /api/receipts/{id}` has populated this receipt's pages.
    var detailFetchedAt: Date?
    /// Local-only hide, set by swipe-to-remove on a rejected receipt. Survives
    /// refetch — without it the server would resurrect a dismissed receipt on
    /// the next page load.
    var dismissedAt: Date?
```

Then add to the computed accessors section, after `serverStatus`:

```swift
    @Transient
    var source: ReceiptSource? {
        get { sourceRaw.flatMap(ReceiptSource.init(rawValue:)) }
        set { sourceRaw = newValue?.rawValue }
    }

    @Transient
    var ocrStatus: OCRStatus? {
        get { ocrStatusRaw.flatMap(OCRStatus.init(rawValue:)) }
        set { ocrStatusRaw = newValue?.rawValue }
    }
```

Finally, replace the existing `isRemote` declaration with a documented one:

```swift
    /// This device has no capture origin for this row — it was materialized from
    /// a server fetch. False for local captures even after they upload. Gates
    /// Retry / Manage Pages / Delete, and tells `ReceiptMirror` which rows it is
    /// allowed to prune.
    var isRemote: Bool = false
```

- [ ] **Step 5: Add the `LocalReceiptPage` fields**

In `JetLedger/Models/LocalReceiptPage.swift`, add after `r2GrantedAt`:

```swift
    /// The server's image row id, used to match server images to local pages
    /// across refetches.
    var serverImageId: UUID?
    /// The confirmed R2 object path, for `POST /api/receipts/download-url`.
    ///
    /// Deliberately not `r2ImagePath`: that is a 24h grant that the server reaps
    /// if unclaimed, which is why `r2GrantedAt` and `isGrantUsable` exist. This
    /// one names an object that already exists and does not expire. Folding them
    /// into one field is how the grant-expiry bug fixed in 044d085 comes back.
    var serverFilePath: String?
    /// When bytes fetched from the server landed on disk. Drives the reclaim
    /// clock for downloaded images, which have no terminal-status date to key on.
    var imageDownloadedAt: Date?
```

Replace the existing `imageDownloaded` declaration with a documented one:

```swift
    /// Literally "bytes exist on disk at `localImagePath`". True from creation
    /// for captures; false for mirrored pages until fetched; set back to false by
    /// retention cleanup, which is what makes a cleaned-up receipt re-downloadable
    /// instead of a permanent dead end.
    var imageDownloaded: Bool = true
```

- [ ] **Step 6: Update constants**

In `JetLedger/Utilities/Constants.swift`, delete this line from `enum Sync`:

```swift
        static let remoteFetchLimit = 200
```

It is vestigial from the removed Supabase-era sync and referenced nowhere. Then add a new nested enum after `enum Sync`:

```swift
    enum ReceiptList {
        /// Server default is 25 and it clamps to 1...100. Sent explicitly rather
        /// than relying on the default.
        static let pageSize = 25
    }
```

- [ ] **Step 7: Run test to verify it passes**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/ReceiptMirrorTests`
Expected: PASS, 4 tests

- [ ] **Step 8: Verify nothing else referenced the deleted constant**

Run: `grep -rn "remoteFetchLimit" --include="*.swift" .`
Expected: no output

- [ ] **Step 9: Commit**

```bash
git add JetLedger/Models/Enums.swift JetLedger/Models/LocalReceipt.swift \
        JetLedger/Models/LocalReceiptPage.swift JetLedger/Utilities/Constants.swift \
        JetLedgerTests/ReceiptMirrorTests.swift
git commit -m "feat(model): add server-mirror fields and revive isRemote/imageDownloaded"
```

---

## Task 3: List and detail API methods

**Files:**
- Modify: `JetLedger/Services/ReceiptAPIService.swift`
- Test: `JetLedgerTests/ReceiptListServiceTests.swift` (created here, extended in Task 6)

**Interfaces:**
- Consumes: `AppConstants.ReceiptList.pageSize` (Task 2)
- Produces:
  - `ReceiptSummaryDTO` with `id: UUID`, `status: String`, `source: String`, `note: String?`, `tripReferenceId: UUID?`, `ocrStatus: String?`, `rejectionReason: String?`, `expenseId: UUID?`, `imageCount: Int`, `createdAt: String`, `updatedAt: String`
  - `ReceiptImageDTO` with `id: UUID`, `filePath: String`, `fileName: String`, `mimeType: String`, `sortOrder: Int`
  - `ReceiptDetailDTO` with all `ReceiptSummaryDTO` fields plus `images: [ReceiptImageDTO]`
  - `ReceiptListResponse` with `receipts: [ReceiptSummaryDTO]`, `total: Int`, `limit: Int`, `offset: Int`
  - `ReceiptAPIService.listReceipts(status:limit:offset:accountId:) async throws -> ReceiptListResponse`
  - `ReceiptAPIService.getReceipt(id:accountId:) async throws -> ReceiptDetailDTO`

- [ ] **Step 1: Write the failing test**

Create `JetLedgerTests/ReceiptListServiceTests.swift`:

```swift
//
//  ReceiptListServiceTests.swift
//  JetLedgerTests
//
//  Covers the list/detail API surface and the paging state machine on top of it.
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

/// Thread-safe request recorder — MockURLProtocol's handler runs on URLSession's
/// background queue.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(method: String, path: String, query: String?)] = []

    func record(_ request: URLRequest) {
        let entry = (
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            query: request.url?.query
        )
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [(method: String, path: String, query: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

extension MockURLProtocolSuites {

@MainActor
@Suite(.serialized)
struct ReceiptListServiceTests {

    init() {
        MockURLProtocol.reset()
    }

    // MARK: - Harness

    private func makeAPI() -> ReceiptAPIService {
        ReceiptAPIService(apiClient: APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: MockURLProtocol.makeSession()
        ))
    }

    private func respond(_ json: String, log: RequestLog? = nil) {
        MockURLProtocol.handler = { request in
            log?.record(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                json.data(using: .utf8)!
            )
        }
    }

    // MARK: - Decoding

    @Test
    func decodesAFullListRow() async throws {
        let api = makeAPI()
        respond("""
        {"receipts":[{
          "id":"9f1c0000-0000-4000-8000-000000000001",
          "status":"rejected",
          "source":"email",
          "note":"Fwd: Signature Flight Support receipt",
          "trip_reference_id":"3a7e0000-0000-4000-8000-000000000002",
          "ocr_status":"completed",
          "rejection_reason":"unreadable",
          "expense_id":"",
          "image_count":1,
          "created_at":"2026-07-27 14:03:22",
          "updated_at":"2026-07-27 15:11:08"
        }],"total":137,"limit":25,"offset":0}
        """)

        let response = try await api.listReceipts(
            status: nil, limit: 25, offset: 0, accountId: UUID()
        )

        #expect(response.total == 137)
        #expect(response.receipts.count == 1)
        let row = try #require(response.receipts.first)
        #expect(row.status == "rejected")
        #expect(row.source == "email")
        #expect(row.note == "Fwd: Signature Flight Support receipt")
        #expect(row.ocrStatus == "completed")
        #expect(row.rejectionReason == "unreadable")
        #expect(row.imageCount == 1)
        #expect(ServerDateFormatter.date(from: row.createdAt) != nil)
    }

    /// The server omits these keys entirely rather than sending null. A
    /// non-optional property would fail the whole page decode.
    @Test
    func decodesARowWithEveryOmitemptyKeyAbsent() async throws {
        let api = makeAPI()
        respond("""
        {"receipts":[{
          "id":"9f1c0000-0000-4000-8000-000000000001",
          "status":"pending",
          "source":"ios",
          "ocr_status":"pending",
          "image_count":2,
          "created_at":"2026-07-27 14:03:22",
          "updated_at":"2026-07-27 14:03:22"
        }],"total":1,"limit":25,"offset":0}
        """)

        let response = try await api.listReceipts(
            status: nil, limit: 25, offset: 0, accountId: UUID()
        )

        let row = try #require(response.receipts.first)
        #expect(row.note == nil)
        #expect(row.tripReferenceId == nil)
        #expect(row.rejectionReason == nil)
        #expect(row.expenseId == nil)
    }

    @Test
    func decodesDetailWithImages() async throws {
        let api = makeAPI()
        respond("""
        {
          "id":"9f1c0000-0000-4000-8000-000000000001",
          "status":"rejected",
          "source":"email",
          "ocr_status":"completed",
          "rejection_reason":"unreadable",
          "image_count":1,
          "created_at":"2026-07-27 14:03:22",
          "updated_at":"2026-07-27 15:11:08",
          "images":[{
            "id":"b21d0000-0000-4000-8000-000000000003",
            "file_path":"tenants/acct/staged_receipts/2026/07/b21d.jpg",
            "file_name":"IMG_4417.jpg",
            "mime_type":"image/jpeg",
            "sort_order":0
          }]
        }
        """)

        let detail = try await api.getReceipt(
            id: UUID(uuidString: "9f1c0000-0000-4000-8000-000000000001")!,
            accountId: UUID()
        )

        #expect(detail.images.count == 1)
        let image = try #require(detail.images.first)
        #expect(image.filePath == "tenants/acct/staged_receipts/2026/07/b21d.jpg")
        #expect(image.fileName == "IMG_4417.jpg")
        #expect(image.mimeType == "image/jpeg")
        #expect(image.sortOrder == 0)
    }

    // MARK: - Request shape

    @Test
    func listSendsLimitAndOffsetAndOmitsStatusWhenNil() async throws {
        let api = makeAPI()
        let log = RequestLog()
        respond(#"{"receipts":[],"total":0,"limit":25,"offset":50}"#, log: log)

        _ = try await api.listReceipts(status: nil, limit: 25, offset: 50, accountId: UUID())

        let query = try #require(log.all.first?.query)
        #expect(query.contains("limit=25"))
        #expect(query.contains("offset=50"))
        #expect(!query.contains("status="), "an absent filter must not send an empty status")
    }

    @Test
    func listSendsStatusWhenProvided() async throws {
        let api = makeAPI()
        let log = RequestLog()
        respond(#"{"receipts":[],"total":0,"limit":25,"offset":0}"#, log: log)

        _ = try await api.listReceipts(status: "pending", limit: 25, offset: 0, accountId: UUID())

        #expect(try #require(log.all.first?.query).contains("status=pending"))
    }

    /// UUID.uuidString is uppercase, the DB stores lowercase, and SQLite compares
    /// case-sensitively — an uppercase path id is a guaranteed 404.
    @Test
    func detailPathUsesALowercaseId() async throws {
        let api = makeAPI()
        let log = RequestLog()
        respond("""
        {"id":"9f1c0000-0000-4000-8000-000000000001","status":"pending","source":"ios",
         "image_count":0,"created_at":"2026-07-27 14:03:22","updated_at":"2026-07-27 14:03:22",
         "images":[]}
        """, log: log)

        let id = UUID(uuidString: "9F1C0000-0000-4000-8000-000000000001")!
        _ = try await api.getReceipt(id: id, accountId: UUID())

        let path = try #require(log.all.first?.path)
        #expect(path == "/api/receipts/9f1c0000-0000-4000-8000-000000000001")
    }
}

} // MockURLProtocolSuites
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/MockURLProtocolSuites/ReceiptListServiceTests`
Expected: FAIL to compile — "value of type 'ReceiptAPIService' has no member 'listReceipts'"

- [ ] **Step 3: Add the DTOs**

In `JetLedger/Services/ReceiptAPIService.swift`, add to the DTO section after `ReceiptStatusResponse`:

```swift
// MARK: - List / Detail DTOs

/// One row of `GET /api/receipts`.
///
/// `note`, `tripReferenceId`, `rejectionReason` and `expenseId` are `omitempty`
/// server-side — the key is *absent*, not null — so every one of them must be
/// optional or the whole page fails to decode.
///
/// `createdAt` / `updatedAt` stay `String` and are parsed with
/// `ServerDateFormatter`; they are SQLite `datetime('now')` output, which no
/// JSONDecoder date strategy handles.
struct ReceiptSummaryDTO: Decodable {
    let id: UUID
    let status: String
    let source: String
    let note: String?
    let tripReferenceId: UUID?
    let ocrStatus: String?
    let rejectionReason: String?
    let expenseId: UUID?
    let imageCount: Int
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, status, source, note
        case tripReferenceId = "trip_reference_id"
        case ocrStatus = "ocr_status"
        case rejectionReason = "rejection_reason"
        case expenseId = "expense_id"
        case imageCount = "image_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ReceiptImageDTO: Decodable {
    let id: UUID
    let filePath: String
    let fileName: String
    let mimeType: String
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case filePath = "file_path"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case sortOrder = "sort_order"
    }
}

/// `GET /api/receipts/{id}` — a list row plus its images.
struct ReceiptDetailDTO: Decodable {
    let id: UUID
    let status: String
    let source: String
    let note: String?
    let tripReferenceId: UUID?
    let ocrStatus: String?
    let rejectionReason: String?
    let expenseId: UUID?
    let imageCount: Int
    let createdAt: String
    let updatedAt: String
    let images: [ReceiptImageDTO]

    enum CodingKeys: String, CodingKey {
        case id, status, source, note, images
        case tripReferenceId = "trip_reference_id"
        case ocrStatus = "ocr_status"
        case rejectionReason = "rejection_reason"
        case expenseId = "expense_id"
        case imageCount = "image_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// The mirror applies summary and detail responses through one code path.
    var summary: ReceiptSummaryDTO {
        ReceiptSummaryDTO(
            id: id, status: status, source: source, note: note,
            tripReferenceId: tripReferenceId, ocrStatus: ocrStatus,
            rejectionReason: rejectionReason, expenseId: expenseId,
            imageCount: imageCount, createdAt: createdAt, updatedAt: updatedAt
        )
    }
}

struct ReceiptListResponse: Decodable {
    let receipts: [ReceiptSummaryDTO]
    /// Count matching the filter, not the page size — this is what drives paging.
    let total: Int
    let limit: Int
    let offset: Int
}
```

`ReceiptDetailDTO.summary` needs `ReceiptSummaryDTO`'s memberwise initializer, which a `Decodable` struct with no explicit `init` gets for free. Do not add a custom `init(from:)` to `ReceiptSummaryDTO`.

- [ ] **Step 4: Add the methods**

In `JetLedger/Services/ReceiptAPIService.swift`, add after `checkStatus`:

```swift
    // MARK: - List / Detail

    /// The authenticated user's own staged receipts, newest first. Tenant scope
    /// comes from `X-Account-ID`.
    func listReceipts(
        status: String?,
        limit: Int,
        offset: Int,
        accountId: UUID
    ) async throws -> ReceiptListResponse {
        var query = ["limit": String(limit), "offset": String(offset)]
        if let status { query["status"] = status }
        return try await apiClient.get(
            AppConstants.WebAPI.receipts,
            query: query,
            accountId: accountId
        )
    }

    /// 404 here means "not yours or not there" — the endpoint deliberately does
    /// not distinguish the two.
    func getReceipt(id: UUID, accountId: UUID) async throws -> ReceiptDetailDTO {
        try await apiClient.request(
            .get,
            "\(AppConstants.WebAPI.receipts)/\(id.uuidString.lowercased())",
            accountId: accountId
        )
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/MockURLProtocolSuites/ReceiptListServiceTests`
Expected: PASS, 6 tests

- [ ] **Step 6: Commit**

```bash
git add JetLedger/Services/ReceiptAPIService.swift JetLedgerTests/ReceiptListServiceTests.swift
git commit -m "feat(api): add receipt list and detail endpoints"
```

---

## Task 4: Mirror upsert

**Files:**
- Create: `JetLedger/Services/ReceiptMirror.swift`
- Test: `JetLedgerTests/ReceiptMirrorTests.swift` (extend)

**Interfaces:**
- Consumes: `ServerDateFormatter` (Task 1); `LocalReceipt`/`LocalReceiptPage` fields (Task 2); `ReceiptSummaryDTO`, `ReceiptDetailDTO`, `ReceiptImageDTO` (Task 3)
- Produces:
  - `ReceiptMirror(modelContext: ModelContext)`
  - `func upsert(_ dtos: [ReceiptSummaryDTO], accountId: UUID)`
  - `func upsertDetail(_ dto: ReceiptDetailDTO, accountId: UUID) -> LocalReceipt?`
  - `func receipt(forServerId: UUID, accountId: UUID) -> LocalReceipt?`

- [ ] **Step 1: Write the failing test**

Append these tests inside `struct ReceiptMirrorTests` in `JetLedgerTests/ReceiptMirrorTests.swift`, after `pageSizeIsWithinTheServersClampRange`:

```swift
    // MARK: - DTO builders

    private func summary(
        id: UUID,
        status: String = "pending",
        source: String = "email",
        note: String? = nil,
        tripReferenceId: UUID? = nil,
        createdAt: String = "2026-07-20 12:00:00",
        updatedAt: String = "2026-07-20 12:00:00",
        imageCount: Int = 1
    ) throws -> ReceiptSummaryDTO {
        var fields: [String] = [
            "\"id\":\"\(id.uuidString.lowercased())\"",
            "\"status\":\"\(status)\"",
            "\"source\":\"\(source)\"",
            "\"ocr_status\":\"pending\"",
            "\"image_count\":\(imageCount)",
            "\"created_at\":\"\(createdAt)\"",
            "\"updated_at\":\"\(updatedAt)\""
        ]
        if let note { fields.append("\"note\":\"\(note)\"") }
        if let tripReferenceId {
            fields.append("\"trip_reference_id\":\"\(tripReferenceId.uuidString.lowercased())\"")
        }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder().decode(ReceiptSummaryDTO.self, from: Data(json.utf8))
    }

    // MARK: - Upsert

    @Test
    func upsertCreatesAMirroredRowMarkedRemoteAndUploaded() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let serverId = UUID()

        mirror.upsert([try summary(id: serverId, status: "rejected", source: "email")], accountId: accountId)

        let rows = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.serverReceiptId == serverId)
        #expect(row.accountId == accountId)
        #expect(row.isRemote == true)
        #expect(row.source == .email)
        #expect(row.serverStatus == .rejected)
        #expect(row.syncStatus == .uploaded,
                "a mirrored row must never be picked up by the upload queue")
        #expect(row.serverCreatedAt == ServerDateFormatter.date(from: "2026-07-20 12:00:00"))
        #expect(row.capturedAt == row.serverCreatedAt,
                "a mirrored row has no capture date of its own")
        #expect(row.terminalStatusAt != nil, "a rejected row must be terminal so retention applies")
    }

    /// This is what collapses a device's own upload into one row instead of two.
    @Test
    func upsertMergesOntoAnExistingLocalRowByServerReceiptId() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let serverId = UUID()

        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let page = LocalReceiptPage(sortOrder: 0, localImagePath: "receipts/x/page-001.jpg")
        let local = LocalReceipt(
            id: UUID(), accountId: accountId, capturedAt: captured, syncStatus: .uploaded, pages: [page]
        )
        local.serverReceiptId = serverId
        context.insert(local)
        page.receipt = local
        context.insert(page)
        try context.save()

        mirror.upsert([try summary(id: serverId, status: "processed", source: "ios")], accountId: accountId)

        let rows = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(rows.count == 1, "the server row must merge, not duplicate")
        let row = try #require(rows.first)
        #expect(row.serverStatus == .processed)
        #expect(row.isRemote == false, "a local capture stays local-origin after it uploads")
        #expect(row.capturedAt == captured, "the server must not overwrite the local capture date")
        #expect(row.pages.count == 1, "local pages must survive an upsert")
    }

    /// The whole point of persisting the flag: a refetch must not resurrect a
    /// receipt the user dismissed.
    @Test
    func upsertPreservesADismissedFlag() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let serverId = UUID()

        mirror.upsert([try summary(id: serverId, status: "rejected")], accountId: accountId)
        let row = try #require(try context.fetch(FetchDescriptor<LocalReceipt>()).first)
        row.dismissedAt = Date()
        try context.save()

        mirror.upsert([try summary(id: serverId, status: "rejected")], accountId: accountId)

        let after = try #require(try context.fetch(FetchDescriptor<LocalReceipt>()).first)
        #expect(after.dismissedAt != nil)
    }

    @Test
    func upsertAppliesServerOwnedMetadata() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let tripId = UUID()

        mirror.upsert(
            [try summary(id: UUID(), note: "Fuel KTEB", tripReferenceId: tripId, imageCount: 3)],
            accountId: accountId
        )

        let row = try #require(try context.fetch(FetchDescriptor<LocalReceipt>()).first)
        #expect(row.note == "Fuel KTEB")
        #expect(row.tripReferenceId == tripId)
        #expect(row.imageCount == 3)
    }

    @Test
    func upsertIsIdempotent() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let dto = try summary(id: UUID())

        mirror.upsert([dto], accountId: accountId)
        mirror.upsert([dto], accountId: accountId)
        mirror.upsert([dto], accountId: accountId)

        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)
    }

    @Test
    func upsertScopesRowsToTheirAccount() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountA = UUID()
        let accountB = UUID()
        let sharedId = UUID()

        mirror.upsert([try summary(id: sharedId)], accountId: accountA)
        mirror.upsert([try summary(id: sharedId)], accountId: accountB)

        let rows = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(rows.count == 2, "the same server id under a different tenant is a different row")
        #expect(Set(rows.map(\.accountId)) == Set([accountA, accountB]))
    }

    // MARK: - Detail upsert

    @Test
    func upsertDetailCreatesPagesAwaitingDownload() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let serverId = UUID()
        let json = """
        {"id":"\(serverId.uuidString.lowercased())","status":"pending","source":"email",
         "ocr_status":"completed","image_count":2,
         "created_at":"2026-07-20 12:00:00","updated_at":"2026-07-20 12:00:00",
         "images":[
           {"id":"b21d0000-0000-4000-8000-000000000003","file_path":"tenants/a/one.jpg",
            "file_name":"one.jpg","mime_type":"image/jpeg","sort_order":0},
           {"id":"b21d0000-0000-4000-8000-000000000004","file_path":"tenants/a/two.pdf",
            "file_name":"two.pdf","mime_type":"application/pdf","sort_order":1}
         ]}
        """
        let dto = try JSONDecoder().decode(ReceiptDetailDTO.self, from: Data(json.utf8))

        let row = try #require(mirror.upsertDetail(dto, accountId: accountId))

        #expect(row.detailFetchedAt != nil)
        let pages = row.pages.sorted { $0.sortOrder < $1.sortOrder }
        #expect(pages.count == 2)
        #expect(pages[0].serverFilePath == "tenants/a/one.jpg")
        #expect(pages[0].contentType == .jpeg)
        #expect(pages[0].imageDownloaded == false, "mirrored pages have no bytes yet")
        #expect(pages[1].contentType == .pdf)
        #expect(pages[1].sortOrder == 1)
    }

    @Test
    func upsertDetailIsIdempotentOnImageIds() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let serverId = UUID()
        let json = """
        {"id":"\(serverId.uuidString.lowercased())","status":"pending","source":"email",
         "ocr_status":"completed","image_count":1,
         "created_at":"2026-07-20 12:00:00","updated_at":"2026-07-20 12:00:00",
         "images":[{"id":"b21d0000-0000-4000-8000-000000000003","file_path":"tenants/a/one.jpg",
          "file_name":"one.jpg","mime_type":"image/jpeg","sort_order":0}]}
        """
        let dto = try JSONDecoder().decode(ReceiptDetailDTO.self, from: Data(json.utf8))

        _ = mirror.upsertDetail(dto, accountId: accountId)
        let row = try #require(mirror.upsertDetail(dto, accountId: accountId))

        #expect(row.pages.count == 1, "re-fetching detail must not duplicate pages")
    }

    /// A local capture's pages point at real files on disk. A detail response
    /// must annotate them, never replace them.
    @Test
    func upsertDetailDoesNotDisturbALocalCapturesPages() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let serverId = UUID()

        let page = LocalReceiptPage(sortOrder: 0, localImagePath: "receipts/x/page-001.jpg")
        let local = LocalReceipt(id: UUID(), accountId: accountId, syncStatus: .uploaded, pages: [page])
        local.serverReceiptId = serverId
        context.insert(local)
        page.receipt = local
        context.insert(page)
        try context.save()

        let json = """
        {"id":"\(serverId.uuidString.lowercased())","status":"pending","source":"ios",
         "ocr_status":"completed","image_count":1,
         "created_at":"2026-07-20 12:00:00","updated_at":"2026-07-20 12:00:00",
         "images":[{"id":"b21d0000-0000-4000-8000-000000000003","file_path":"tenants/a/one.jpg",
          "file_name":"one.jpg","mime_type":"image/jpeg","sort_order":0}]}
        """
        let dto = try JSONDecoder().decode(ReceiptDetailDTO.self, from: Data(json.utf8))

        let row = try #require(mirror.upsertDetail(dto, accountId: accountId))

        #expect(row.pages.count == 1)
        let updated = try #require(row.pages.first)
        #expect(updated.localImagePath == "receipts/x/page-001.jpg",
                "the local file path must survive")
        #expect(updated.imageDownloaded == true, "the bytes are still on disk")
        #expect(updated.serverFilePath == "tenants/a/one.jpg",
                "but the page now knows its server object")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/ReceiptMirrorTests`
Expected: FAIL to compile — "cannot find 'ReceiptMirror' in scope"

- [ ] **Step 3: Write the implementation**

Create `JetLedger/Services/ReceiptMirror.swift`:

```swift
//
//  ReceiptMirror.swift
//  JetLedger
//

import Foundation
import OSLog
import SwiftData

/// Reconciles server receipt rows into SwiftData. No networking lives here —
/// callers hand it decoded DTOs — which is what makes the merge and prune rules
/// testable without a URL session.
struct ReceiptMirror {
    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "ReceiptMirror")

    let modelContext: ModelContext

    // MARK: - Lookup

    /// Rows for one tenant. `accountId` is safe in a `#Predicate`; matching on
    /// `serverReceiptId` is not (UUID comparison beyond the stored account id has
    /// bitten us before), so that half is filtered in memory.
    private func rows(accountId: UUID) -> [LocalReceipt] {
        let descriptor = FetchDescriptor<LocalReceipt>(
            predicate: #Predicate<LocalReceipt> { $0.accountId == accountId }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func receipt(forServerId serverId: UUID, accountId: UUID) -> LocalReceipt? {
        rows(accountId: accountId).first { $0.serverReceiptId == serverId }
    }

    // MARK: - Upsert

    /// Merges a page of server rows. Existing rows are matched on
    /// `serverReceiptId`, which is what collapses a receipt this device uploaded
    /// into a single row rather than showing it twice.
    func upsert(_ dtos: [ReceiptSummaryDTO], accountId: UUID) {
        guard !dtos.isEmpty else { return }

        var byServerId: [UUID: LocalReceipt] = [:]
        for row in rows(accountId: accountId) {
            if let serverId = row.serverReceiptId {
                byServerId[serverId] = row
            }
        }

        for dto in dtos {
            if let existing = byServerId[dto.id] {
                apply(dto, to: existing)
            } else {
                let created = ServerDateFormatter.date(from: dto.createdAt) ?? Date()
                let row = LocalReceipt(
                    accountId: accountId,
                    capturedAt: created,
                    syncStatus: .uploaded
                )
                row.serverReceiptId = dto.id
                // No capture origin on this device: gates Retry / Manage Pages /
                // Delete, and marks the row as prunable.
                row.isRemote = true
                modelContext.insert(row)
                byServerId[dto.id] = row
                apply(dto, to: row)
            }
        }

        trySave()
    }

    /// Applies only server-owned fields. `capturedAt`, `isRemote`, `dismissedAt`,
    /// `syncStatus` and everything about local pages are deliberately untouched —
    /// the server has no opinion about them and would destroy local state.
    private func apply(_ dto: ReceiptSummaryDTO, to row: LocalReceipt) {
        row.note = dto.note
        row.tripReferenceId = dto.tripReferenceId
        row.sourceRaw = dto.source
        row.ocrStatusRaw = dto.ocrStatus
        row.expenseId = dto.expenseId
        row.imageCount = dto.imageCount
        row.serverCreatedAt = ServerDateFormatter.date(from: dto.createdAt)
        row.serverUpdatedAt = ServerDateFormatter.date(from: dto.updatedAt)
        row.rejectionReason = dto.rejectionReason
        row.lastSyncedAt = Date()

        if let status = ServerStatus(rawValue: dto.status) {
            row.serverStatus = status
            // Stamped the same way syncReceiptStatuses does, so retention
            // reclaims mirrored rows on the same schedule as local ones.
            if status != .pending, row.terminalStatusAt == nil {
                row.terminalStatusAt = Date()
            }
        }
    }

    // MARK: - Detail

    /// Applies a detail response and reconciles its images onto the receipt's
    /// pages. Returns the row so the caller can hand it to the downloader.
    @discardableResult
    func upsertDetail(_ dto: ReceiptDetailDTO, accountId: UUID) -> LocalReceipt? {
        upsert([dto.summary], accountId: accountId)
        guard let row = receipt(forServerId: dto.id, accountId: accountId) else {
            Self.logger.error("Detail upsert found no row for \(dto.id)")
            return nil
        }

        var byImageId: [UUID: LocalReceiptPage] = [:]
        for page in row.pages {
            if let imageId = page.serverImageId {
                byImageId[imageId] = page
            }
        }
        // A local capture's pages have no server image id yet. Match them by
        // sort order so the first detail fetch annotates them instead of adding
        // a second, byte-less copy of every page.
        var bySortOrder: [Int: LocalReceiptPage] = [:]
        for page in row.pages where page.serverImageId == nil {
            bySortOrder[page.sortOrder] = page
        }

        for image in dto.images {
            let page = byImageId[image.id] ?? bySortOrder[image.sortOrder]
            if let page {
                page.serverImageId = image.id
                page.serverFilePath = image.filePath
                page.sortOrder = image.sortOrder
                if let contentType = PageContentType(rawValue: image.mimeType) {
                    page.contentType = contentType
                }
                bySortOrder[image.sortOrder] = nil
            } else {
                let contentType = PageContentType(rawValue: image.mimeType) ?? .jpeg
                let page = LocalReceiptPage(
                    sortOrder: image.sortOrder,
                    // Where the bytes will land once downloaded. The path is
                    // built now so the downloader has a stable destination.
                    localImagePath: "receipts/\(row.id.uuidString)/"
                        + String(format: "page-%03d.%@", image.sortOrder + 1, contentType.fileExtension),
                    contentType: contentType
                )
                page.serverImageId = image.id
                page.serverFilePath = image.filePath
                page.imageDownloaded = false
                modelContext.insert(page)
                // Setting the inverse is what puts this on `row.pages`.
                // Appending as well double-inserts it.
                page.receipt = row
            }
        }

        row.detailFetchedAt = Date()
        trySave()
        return row
    }

    // MARK: - Helpers

    private func trySave() {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("SwiftData save failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/ReceiptMirrorTests`
Expected: PASS, 13 tests

- [ ] **Step 5: Commit**

```bash
git add JetLedger/Services/ReceiptMirror.swift JetLedgerTests/ReceiptMirrorTests.swift
git commit -m "feat(sync): mirror server receipt rows into SwiftData"
```

---

## Task 5: Mirror pruning

Receipts deleted on the web must leave the mirror. The rule exploits newest-first ordering: within a fetched page, any mirrored row dated between that page's newest and oldest entries but absent from the response is gone server-side.

**Files:**
- Modify: `JetLedger/Services/ReceiptMirror.swift`
- Test: `JetLedgerTests/ReceiptMirrorTests.swift` (extend)

**Interfaces:**
- Consumes: everything from Task 4
- Produces: `func prune(_ dtos: [ReceiptSummaryDTO], accountId: UUID) -> Set<UUID>` — returns the **local** ids of deleted rows so the caller can drop a live iPad detail selection

- [ ] **Step 1: Write the failing test**

Append inside `struct ReceiptMirrorTests`:

```swift
    // MARK: - Prune

    @Test
    func pruneRemovesAMirroredRowMissingFromItsOwnDateRange() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let keptId = UUID()
        let goneId = UUID()

        mirror.upsert([
            try summary(id: keptId, createdAt: "2026-07-25 12:00:00"),
            try summary(id: goneId, createdAt: "2026-07-20 12:00:00")
        ], accountId: accountId)
        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 2)

        // A later page covering the same window no longer contains goneId.
        let deleted = mirror.prune([
            try summary(id: keptId, createdAt: "2026-07-25 12:00:00"),
            try summary(id: UUID(), createdAt: "2026-07-18 12:00:00")
        ], accountId: accountId)

        let remaining = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(!remaining.contains { $0.serverReceiptId == goneId },
                "a row inside the fetched window but absent from it was deleted on the web")
        #expect(remaining.contains { $0.serverReceiptId == keptId })
        #expect(deleted.count == 1)
    }

    @Test
    func pruneLeavesRowsOutsideTheFetchedRangeAlone() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let olderId = UUID()

        mirror.upsert([try summary(id: olderId, createdAt: "2026-06-01 12:00:00")], accountId: accountId)

        _ = mirror.prune([
            try summary(id: UUID(), createdAt: "2026-07-25 12:00:00"),
            try summary(id: UUID(), createdAt: "2026-07-20 12:00:00")
        ], accountId: accountId)

        let remaining = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(remaining.contains { $0.serverReceiptId == olderId },
                "a page proves nothing about receipts older than its oldest entry")
    }

    /// A receipt that got its serverReceiptId after this request went out is
    /// legitimately absent from the response. Deleting it would destroy the only
    /// copy of the user's images.
    @Test
    func pruneNeverTouchesALocalOriginRow() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()

        let local = LocalReceipt(
            id: UUID(),
            accountId: accountId,
            capturedAt: try #require(ServerDateFormatter.date(from: "2026-07-22 12:00:00")),
            syncStatus: .uploaded
        )
        local.serverReceiptId = UUID()
        local.serverCreatedAt = ServerDateFormatter.date(from: "2026-07-22 12:00:00")
        local.isRemote = false
        context.insert(local)
        try context.save()

        _ = mirror.prune([
            try summary(id: UUID(), createdAt: "2026-07-25 12:00:00"),
            try summary(id: UUID(), createdAt: "2026-07-20 12:00:00")
        ], accountId: accountId)

        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1,
                "a local capture is only ever removed by the user or status sync")
    }

    @Test
    func pruneIgnoresOtherAccounts() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountA = UUID()
        let accountB = UUID()

        mirror.upsert([try summary(id: UUID(), createdAt: "2026-07-22 12:00:00")], accountId: accountB)

        _ = mirror.prune([
            try summary(id: UUID(), createdAt: "2026-07-25 12:00:00"),
            try summary(id: UUID(), createdAt: "2026-07-20 12:00:00")
        ], accountId: accountA)

        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)
    }

    @Test
    func pruneOnAnEmptyResponseDeletesNothing() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()

        mirror.upsert([try summary(id: UUID())], accountId: accountId)

        let deleted = mirror.prune([], accountId: accountId)

        #expect(deleted.isEmpty, "an empty page describes no window and proves nothing")
        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)
    }

    @Test
    func pruneKeepsRowsPresentInTheResponse() throws {
        let context = try Self.makeContext()
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let id = UUID()
        let page = [try summary(id: id, createdAt: "2026-07-22 12:00:00")]

        mirror.upsert(page, accountId: accountId)
        let deleted = mirror.prune(page, accountId: accountId)

        #expect(deleted.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/ReceiptMirrorTests`
Expected: FAIL to compile — "value of type 'ReceiptMirror' has no member 'prune'"

- [ ] **Step 3: Write the implementation**

Add to `JetLedger/Services/ReceiptMirror.swift`, after `upsertDetail`:

```swift
    // MARK: - Prune

    /// Deletes mirrored rows the server has dropped.
    ///
    /// The server sorts newest-first, so a page proves exactly what exists
    /// between its newest and oldest entries and nothing outside that window.
    /// A mirrored row dated inside the window but absent from the response was
    /// deleted on the web.
    ///
    /// Only `isRemote` rows are eligible. A receipt that received its
    /// `serverReceiptId` after this request went out is legitimately absent from
    /// the response, and deleting it would destroy the only copy of the user's
    /// images. Local captures are removed by the user or by `syncReceiptStatuses`,
    /// never here.
    ///
    /// Returns the deleted rows' **local** ids so the caller can clear a live
    /// detail selection before the next body evaluation touches a dead model.
    @discardableResult
    func prune(_ dtos: [ReceiptSummaryDTO], accountId: UUID) -> Set<UUID> {
        guard let newestString = dtos.first?.createdAt,
              let oldestString = dtos.last?.createdAt,
              let newest = ServerDateFormatter.date(from: newestString),
              let oldest = ServerDateFormatter.date(from: oldestString)
        else { return [] }

        let returned = Set(dtos.map(\.id))
        var deleted: Set<UUID> = []

        for row in rows(accountId: accountId) where row.isRemote {
            guard let serverId = row.serverReceiptId,
                  let created = row.serverCreatedAt,
                  created >= oldest, created <= newest,
                  !returned.contains(serverId)
            else { continue }

            ImageUtils.deleteReceiptImages(receiptId: row.id)
            deleted.insert(row.id)
            modelContext.delete(row)
        }

        if !deleted.isEmpty {
            Self.logger.info("Pruned \(deleted.count) receipts removed server-side")
            trySave()
        }
        return deleted
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/ReceiptMirrorTests`
Expected: PASS, 19 tests

- [ ] **Step 5: Commit**

```bash
git add JetLedger/Services/ReceiptMirror.swift JetLedgerTests/ReceiptMirrorTests.swift
git commit -m "feat(sync): prune receipts deleted server-side from the mirror"
```

---

## Task 6: Paging service

**Files:**
- Create: `JetLedger/Services/ReceiptListService.swift`
- Test: `JetLedgerTests/ReceiptListServiceTests.swift` (extend)

**Interfaces:**
- Consumes: `ReceiptAPIService.listReceipts`/`getReceipt` (Task 3); `ReceiptMirror.upsert`/`upsertDetail`/`prune`/`receipt(forServerId:accountId:)` (Tasks 4–5); `AppConstants.ReceiptList.pageSize` (Task 2)
- Produces:
  - `ReceiptListService(receiptAPI:networkMonitor:modelContext:)`
  - `var isLoadingPage: Bool`, `var hasMore: Bool`, `var total: Int`, `var loadError: String?`
  - `@discardableResult func refresh(accountId: UUID) async -> Set<UUID>`
  - `@discardableResult func loadNextPage(accountId: UUID) async -> Set<UUID>`
  - `func fetchDetail(serverReceiptId: UUID, accountId: UUID) async -> DetailFetchResult`
  - `enum DetailFetchResult { case ok(LocalReceipt), removedFromServer(LocalReceipt), deleted, failed(String) }`

- [ ] **Step 1: Write the failing test**

Append inside `struct ReceiptListServiceTests` in `JetLedgerTests/ReceiptListServiceTests.swift`:

```swift
    // MARK: - Paging harness

    private struct PagingHarness {
        let service: ReceiptListService
        let context: ModelContext
        let container: ModelContainer
        let monitor: NetworkMonitor
    }

    private func makePagingHarness(isConnected: Bool = true) throws -> PagingHarness {
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let monitor = NetworkMonitor()
        monitor.setConnectedForTesting(isConnected)
        let service = ReceiptListService(
            receiptAPI: makeAPI(),
            networkMonitor: monitor,
            modelContext: container.mainContext
        )
        return PagingHarness(
            service: service, context: container.mainContext,
            container: container, monitor: monitor
        )
    }

    /// Builds a page body of `count` rows dated one day apart descending from
    /// 2026-07-27, matching the server's newest-first ordering.
    private func pageBody(count: Int, total: Int, offset: Int, startDay: Int = 27) -> String {
        let rows = (0..<count).map { index -> String in
            let day = String(format: "%02d", max(1, startDay - offset - index))
            return """
            {"id":"\(UUID().uuidString.lowercased())","status":"pending","source":"ios",
             "ocr_status":"pending","image_count":1,
             "created_at":"2026-07-\(day) 12:00:00","updated_at":"2026-07-\(day) 12:00:00"}
            """
        }
        return #"{"receipts":[\#(rows.joined(separator: ","))],"total":\#(total),"limit":25,"offset":\#(offset)}"#
    }

    // MARK: - Paging

    @Test
    func refreshMirrorsTheFirstPageAndRecordsTotal() async throws {
        let h = try makePagingHarness()
        respond(pageBody(count: 3, total: 137, offset: 0))

        await h.service.refresh(accountId: UUID())

        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 3)
        #expect(h.service.total == 137)
        #expect(h.service.hasMore == true)
        #expect(h.service.isLoadingPage == false)
        #expect(h.service.loadError == nil)
    }

    @Test
    func loadNextPageAdvancesTheOffset() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        let log = RequestLog()
        respond(pageBody(count: 25, total: 60, offset: 0), log: log)
        await h.service.refresh(accountId: accountId)

        respond(pageBody(count: 25, total: 60, offset: 25, startDay: 2), log: log)
        await h.service.loadNextPage(accountId: accountId)

        let queries = log.all.compactMap(\.query)
        #expect(queries.contains { $0.contains("offset=0") })
        #expect(queries.contains { $0.contains("offset=25") })
        #expect(queries.allSatisfy { $0.contains("limit=25") })
    }

    @Test
    func hasMoreGoesFalseOnceTheTotalIsReached() async throws {
        let h = try makePagingHarness()
        respond(pageBody(count: 3, total: 3, offset: 0))

        await h.service.refresh(accountId: UUID())

        #expect(h.service.hasMore == false)
    }

    @Test
    func loadNextPageStopsOnAnEmptyPage() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        respond(pageBody(count: 2, total: 99, offset: 0))
        await h.service.refresh(accountId: accountId)

        respond(#"{"receipts":[],"total":99,"limit":25,"offset":25}"#)
        await h.service.loadNextPage(accountId: accountId)

        #expect(h.service.hasMore == false,
                "an empty page ends paging even when total disagrees")
    }

    @Test
    func refreshResetsPagingAfterAnAccountSwitch() async throws {
        let h = try makePagingHarness()
        let accountA = UUID()
        respond(pageBody(count: 25, total: 60, offset: 0))
        await h.service.refresh(accountId: accountA)
        respond(pageBody(count: 25, total: 60, offset: 25, startDay: 2))
        await h.service.loadNextPage(accountId: accountA)

        let accountB = UUID()
        let log = RequestLog()
        respond(pageBody(count: 1, total: 1, offset: 0), log: log)
        await h.service.refresh(accountId: accountB)

        #expect(try #require(log.all.first?.query).contains("offset=0"))
        #expect(h.service.total == 1)
    }

    /// Infinite scroll fires `loadNextPage` from a view body; without a guard a
    /// fast scroll issues the same page repeatedly.
    @Test
    func concurrentLoadNextPageCallsIssueOneRequest() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        respond(pageBody(count: 25, total: 99, offset: 0))
        await h.service.refresh(accountId: accountId)

        let log = RequestLog()
        respond(pageBody(count: 25, total: 99, offset: 25, startDay: 2), log: log)
        async let first: Void = h.service.loadNextPage(accountId: accountId)
        async let second: Void = h.service.loadNextPage(accountId: accountId)
        async let third: Void = h.service.loadNextPage(accountId: accountId)
        _ = await (first, second, third)

        #expect(log.all.count == 1, "an in-flight page load must swallow duplicate triggers")
    }

    @Test
    func offlineRefreshMakesNoRequestAndKeepsTheMirror() async throws {
        let h = try makePagingHarness(isConnected: false)
        let accountId = UUID()
        ReceiptMirror(modelContext: h.context).upsert(
            [try JSONDecoder().decode(ReceiptSummaryDTO.self, from: Data("""
            {"id":"\(UUID().uuidString.lowercased())","status":"pending","source":"email",
             "ocr_status":"pending","image_count":1,
             "created_at":"2026-07-20 12:00:00","updated_at":"2026-07-20 12:00:00"}
            """.utf8))],
            accountId: accountId
        )
        let log = RequestLog()
        respond(pageBody(count: 1, total: 1, offset: 0), log: log)

        await h.service.refresh(accountId: accountId)

        #expect(log.all.isEmpty, "offline must not hit the network")
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1,
                "the cached history must still be there")
    }

    @Test
    func aFailedFetchSetsLoadErrorWithoutEmptyingTheMirror() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        respond(pageBody(count: 2, total: 2, offset: 0))
        await h.service.refresh(accountId: accountId)

        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await h.service.refresh(accountId: accountId)

        #expect(h.service.loadError != nil)
        #expect(h.service.isLoadingPage == false)
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 2,
                "a failed request must never blank the list already on screen")
    }

    @Test
    func aSuccessfulRefreshClearsAPreviousError() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await h.service.refresh(accountId: accountId)
        #expect(h.service.loadError != nil)

        respond(pageBody(count: 1, total: 1, offset: 0))
        await h.service.refresh(accountId: accountId)

        #expect(h.service.loadError == nil)
    }

    // MARK: - Detail fetch

    @Test
    func fetchDetailMirrorsAReceiptThisDeviceNeverSaw() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        let serverId = UUID()
        respond("""
        {"id":"\(serverId.uuidString.lowercased())","status":"rejected","source":"email",
         "ocr_status":"completed","rejection_reason":"unreadable","image_count":1,
         "created_at":"2026-07-20 12:00:00","updated_at":"2026-07-20 13:00:00",
         "images":[{"id":"b21d0000-0000-4000-8000-000000000003","file_path":"tenants/a/one.jpg",
          "file_name":"one.jpg","mime_type":"image/jpeg","sort_order":0}]}
        """)

        let result = await h.service.fetchDetail(serverReceiptId: serverId, accountId: accountId)

        guard case .ok(let row) = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
        #expect(row.serverReceiptId == serverId)
        #expect(row.isRemote == true)
        #expect(row.pages.count == 1)
        #expect(row.pages.first?.imageDownloaded == false)
    }

    /// A mirrored row is only a mirror — when the server says it is gone, it goes.
    @Test
    func detail404DeletesAMirroredRow() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        let serverId = UUID()
        respond("""
        {"receipts":[{"id":"\(serverId.uuidString.lowercased())","status":"pending","source":"email",
         "ocr_status":"pending","image_count":1,
         "created_at":"2026-07-20 12:00:00","updated_at":"2026-07-20 12:00:00"}],
         "total":1,"limit":25,"offset":0}
        """)
        await h.service.refresh(accountId: accountId)
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)

        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             #"{"error":"not found"}"#.data(using: .utf8)!)
        }
        let result = await h.service.fetchDetail(serverReceiptId: serverId, accountId: accountId)

        guard case .deleted = result else {
            Issue.record("expected .deleted, got \(result)")
            return
        }
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 0)
    }

    /// The local images are the only copy. A 404 marks the row removed; it must
    /// not destroy it.
    @Test
    func detail404OnALocalCaptureMarksItRemovedAndKeepsTheRow() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        let serverId = UUID()

        let local = LocalReceipt(id: UUID(), accountId: accountId, syncStatus: .uploaded)
        local.serverReceiptId = serverId
        local.serverStatus = .pending
        local.isRemote = false
        h.context.insert(local)
        try h.context.save()

        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             #"{"error":"not found"}"#.data(using: .utf8)!)
        }
        let result = await h.service.fetchDetail(serverReceiptId: serverId, accountId: accountId)

        guard case .removedFromServer = result else {
            Issue.record("expected .removedFromServer, got \(result)")
            return
        }
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)
        #expect(local.serverStatus == .rejected)
        #expect(local.rejectionReason?.contains("Removed") == true)
        #expect(local.terminalStatusAt != nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/MockURLProtocolSuites/ReceiptListServiceTests`
Expected: FAIL to compile — "cannot find 'ReceiptListService' in scope"

- [ ] **Step 3: Write the implementation**

Create `JetLedger/Services/ReceiptListService.swift`:

```swift
//
//  ReceiptListService.swift
//  JetLedger
//

import Foundation
import Observation
import OSLog
import SwiftData

/// Pages `GET /api/receipts` and fetches `GET /api/receipts/{id}`, handing every
/// response to `ReceiptMirror`. The mirror is what the list actually renders, so
/// a failed request degrades to stale-but-present rather than to an empty screen.
@Observable
class ReceiptListService {
    /// Outcome of a detail fetch. A 404 means different things depending on
    /// whether the row was only a mirror or the user's own capture.
    enum DetailFetchResult {
        case ok(LocalReceipt)
        /// The server dropped a receipt this device captured. The row survives —
        /// its local images are the only copy — and is marked removed.
        case removedFromServer(LocalReceipt)
        /// A mirrored row the server no longer has. Deleted from the mirror.
        case deleted
        case failed(String)
    }

    var isLoadingPage = false
    var hasMore = true
    var total = 0
    var loadError: String?

    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "ReceiptListService")
    private let receiptAPI: ReceiptAPIService
    private let networkMonitor: NetworkMonitor
    private let mirror: ReceiptMirror
    private var offset = 0
    private var pagedAccountId: UUID?

    init(
        receiptAPI: ReceiptAPIService,
        networkMonitor: NetworkMonitor,
        modelContext: ModelContext
    ) {
        self.receiptAPI = receiptAPI
        self.networkMonitor = networkMonitor
        self.mirror = ReceiptMirror(modelContext: modelContext)
    }

    // MARK: - Paging

    /// Re-fetches the newest page. Rows already paged in below it stay in the
    /// mirror — only the paging cursor resets.
    ///
    /// Returns the local ids of rows pruned as deleted server-side, so the caller
    /// can drop a live detail selection before it touches a destroyed model.
    @discardableResult
    func refresh(accountId: UUID) async -> Set<UUID> {
        offset = 0
        hasMore = true
        pagedAccountId = accountId
        return await fetchPage(accountId: accountId, offset: 0)
    }

    @discardableResult
    func loadNextPage(accountId: UUID) async -> Set<UUID> {
        guard hasMore, !isLoadingPage else { return [] }
        guard pagedAccountId == accountId else { return await refresh(accountId: accountId) }
        return await fetchPage(accountId: accountId, offset: offset + AppConstants.ReceiptList.pageSize)
    }

    private func fetchPage(accountId: UUID, offset requestedOffset: Int) async -> Set<UUID> {
        guard networkMonitor.isConnected else { return [] }
        // Set before the first suspension point so a duplicate trigger arriving
        // from a scrolling view body is swallowed rather than issuing the same
        // page again.
        guard !isLoadingPage else { return [] }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            let response = try await receiptAPI.listReceipts(
                status: nil,
                limit: AppConstants.ReceiptList.pageSize,
                offset: requestedOffset,
                accountId: accountId
            )

            mirror.upsert(response.receipts, accountId: accountId)
            let pruned = mirror.prune(response.receipts, accountId: accountId)

            total = response.total
            offset = requestedOffset
            // Trust an empty page over `total`: offset paging drifts when
            // receipts are created mid-scroll, and an empty page is the only
            // unambiguous end-of-list signal.
            hasMore = !response.receipts.isEmpty
                && (requestedOffset + response.receipts.count) < response.total
            loadError = nil
            return pruned
        } catch let apiError as APIError where apiError == .unauthorized() {
            // APIClient has already invoked onUnauthorized; nothing to surface.
            Self.logger.warning("Receipt list auth error — stopping")
            return []
        } catch {
            loadError = error.localizedDescription
            Self.logger.warning("Receipt list fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Detail

    func fetchDetail(serverReceiptId: UUID, accountId: UUID) async -> DetailFetchResult {
        do {
            let detail = try await receiptAPI.getReceipt(id: serverReceiptId, accountId: accountId)
            guard let row = mirror.upsertDetail(detail, accountId: accountId) else {
                return .failed("This receipt could not be loaded.")
            }
            return .ok(row)
        } catch let apiError as APIError where apiError == .serverError(404) {
            return handleDetailNotFound(serverReceiptId: serverReceiptId, accountId: accountId)
        } catch {
            Self.logger.warning("Receipt detail fetch failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// 404 means "not yours or not there" — the endpoint deliberately does not
    /// distinguish. Either way the receipt is unreachable, but the response
    /// depends on whether anything would be lost by deleting the row.
    private func handleDetailNotFound(serverReceiptId: UUID, accountId: UUID) -> DetailFetchResult {
        guard let row = mirror.receipt(forServerId: serverReceiptId, accountId: accountId) else {
            return .deleted
        }
        if row.isRemote {
            mirror.prune(byLocalId: row.id)
            return .deleted
        }
        // Matches how syncReceiptStatuses treats a receipt that vanished during
        // web review. The local images stay — they are the only copy.
        row.serverStatus = .rejected
        row.rejectionReason = "Removed during review on the web."
        if row.terminalStatusAt == nil {
            row.terminalStatusAt = Date()
        }
        mirror.save()
        return .removedFromServer(row)
    }
}
```

- [ ] **Step 4: Add the two `ReceiptMirror` helpers this needs**

In `JetLedger/Services/ReceiptMirror.swift`, add after `prune(_:accountId:)`:

```swift
    /// Deletes one mirrored row by its local id. Used when a detail 404 proves a
    /// single receipt is gone without a page to reason about.
    func prune(byLocalId localId: UUID) {
        let descriptor = FetchDescriptor<LocalReceipt>(
            predicate: #Predicate<LocalReceipt> { $0.id == localId }
        )
        guard let row = (try? modelContext.fetch(descriptor))?.first, row.isRemote else { return }
        ImageUtils.deleteReceiptImages(receiptId: row.id)
        modelContext.delete(row)
        trySave()
    }

    /// Persists changes callers made directly to mirrored rows.
    func save() {
        trySave()
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/MockURLProtocolSuites/ReceiptListServiceTests`
Expected: PASS, 18 tests

- [ ] **Step 6: Commit**

```bash
git add JetLedger/Services/ReceiptListService.swift JetLedger/Services/ReceiptMirror.swift \
        JetLedgerTests/ReceiptListServiceTests.swift
git commit -m "feat(sync): page the server receipt list and fetch detail"
```

---

## Task 7: Image downloader

**Files:**
- Create: `JetLedger/Services/ReceiptImageDownloader.swift`
- Test: `JetLedgerTests/ReceiptImageDownloaderTests.swift`

**Interfaces:**
- Consumes: `ReceiptAPIService.getDownloadURL(filePath:)` (existing); `LocalReceiptPage.serverFilePath`/`imageDownloaded`/`imageDownloadedAt` (Task 2)
- Produces:
  - `ReceiptImageDownloader(receiptAPI:modelContext:session:)`
  - `func downloadMissingImages(for receipt: LocalReceipt) async throws`
  - `var inFlightReceiptIds: Set<UUID>`

- [ ] **Step 1: Write the failing test**

Create `JetLedgerTests/ReceiptImageDownloaderTests.swift`:

```swift
//
//  ReceiptImageDownloaderTests.swift
//  JetLedgerTests
//
//  Covers on-demand image fetch for receipts this device never captured, and for
//  local captures whose images retention has already reclaimed.
//

import Testing
import Foundation
import SwiftData
import UIKit
@testable import JetLedger

extension MockURLProtocolSuites {

@MainActor
@Suite(.serialized)
struct ReceiptImageDownloaderTests {

    init() {
        MockURLProtocol.reset()
    }

    // MARK: - Harness

    private struct Harness {
        let downloader: ReceiptImageDownloader
        let context: ModelContext
        let container: ModelContainer
    }

    private func makeHarness() throws -> Harness {
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let apiClient = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: MockURLProtocol.makeSession()
        )
        let downloader = ReceiptImageDownloader(
            receiptAPI: ReceiptAPIService(apiClient: apiClient),
            modelContext: container.mainContext,
            session: MockURLProtocol.makeSession()
        )
        return Harness(
            downloader: downloader, context: container.mainContext, container: container
        )
    }

    /// A one-pixel JPEG, so the thumbnail step has something real to decode.
    private static func jpegBytes() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }

    private func makeRemoteReceipt(
        in context: ModelContext,
        serverFilePath: String = "tenants/a/one.jpg",
        contentType: PageContentType = .jpeg
    ) throws -> LocalReceipt {
        let receiptId = UUID()
        let page = LocalReceiptPage(
            sortOrder: 0,
            localImagePath: "receipts/\(receiptId.uuidString)/page-001.\(contentType.fileExtension)",
            contentType: contentType
        )
        page.serverFilePath = serverFilePath
        page.serverImageId = UUID()
        page.imageDownloaded = false
        let receipt = LocalReceipt(id: receiptId, accountId: UUID(), syncStatus: .uploaded)
        receipt.serverReceiptId = UUID()
        receipt.isRemote = true
        context.insert(receipt)
        page.receipt = receipt
        context.insert(page)
        receipt.pages = [page]
        try context.save()
        return receipt
    }

    /// Routes download-url then the object GET.
    private func installDownloadHandler(bytes: Data) {
        MockURLProtocol.handler = { request in
            let url = request.url!
            if url.path == "/api/receipts/download-url" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"download_url":"https://example.test/r2/object","expires_in":900}"#
                        .data(using: .utf8)!
                )
            }
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                bytes
            )
        }
    }

    // MARK: - Tests

    @Test
    func downloadsMissingImageAndWritesItToDisk() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(in: h.context)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        installDownloadHandler(bytes: try Self.jpegBytes())

        try await h.downloader.downloadMissingImages(for: receipt)

        let page = try #require(receipt.pages.first)
        #expect(page.imageDownloaded == true)
        #expect(page.imageDownloadedAt != nil)
        #expect(ImageUtils.loadReceiptImage(relativePath: page.localImagePath) != nil,
                "the bytes must be readable back off disk")
    }

    /// Once a receipt has been opened, its list row should stop showing a
    /// placeholder glyph.
    @Test
    func generatesAThumbnailSoTheListRowFillsIn() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(in: h.context)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        installDownloadHandler(bytes: try Self.jpegBytes())

        try await h.downloader.downloadMissingImages(for: receipt)

        let page = try #require(receipt.pages.first)
        let thumbPath = ImageUtils.thumbnailPath(for: page.localImagePath)
        #expect(ImageUtils.loadReceiptImage(relativePath: thumbPath) != nil)
    }

    @Test
    func skipsPagesThatAlreadyHaveTheirBytes() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(in: h.context)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        installDownloadHandler(bytes: try Self.jpegBytes())
        try await h.downloader.downloadMissingImages(for: receipt)

        var requestCount = 0
        let lock = NSLock()
        MockURLProtocol.handler = { request in
            lock.lock(); requestCount += 1; lock.unlock()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        try await h.downloader.downloadMissingImages(for: receipt)

        lock.lock()
        let count = requestCount
        lock.unlock()
        #expect(count == 0, "a page with bytes on disk must not be re-fetched")
    }

    @Test
    func skipsPagesWithNoServerObject() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(in: h.context)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        let page = try #require(receipt.pages.first)
        page.serverFilePath = nil
        try h.context.save()

        var requestCount = 0
        let lock = NSLock()
        MockURLProtocol.handler = { request in
            lock.lock(); requestCount += 1; lock.unlock()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        try await h.downloader.downloadMissingImages(for: receipt)

        lock.lock()
        let count = requestCount
        lock.unlock()
        #expect(count == 0)
    }

    @Test
    func aFailedDownloadLeavesThePageMarkedMissing() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(in: h.context)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }

        await #expect(throws: (any Error).self) {
            try await h.downloader.downloadMissingImages(for: receipt)
        }

        let page = try #require(receipt.pages.first)
        #expect(page.imageDownloaded == false, "a failed download must stay retryable")
        #expect(page.imageDownloadedAt == nil)
    }

    @Test
    func downloadsAPDFPageAndRendersItsThumbnail() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(
            in: h.context, serverFilePath: "tenants/a/one.pdf", contentType: .pdf
        )
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }

        let pdfData = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: pdfData))
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
        let pdfContext = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        pdfContext.beginPDFPage(nil)
        pdfContext.setFillColor(UIColor.white.cgColor)
        pdfContext.fill(mediaBox)
        pdfContext.endPDFPage()
        pdfContext.closePDF()
        installDownloadHandler(bytes: pdfData as Data)

        try await h.downloader.downloadMissingImages(for: receipt)

        let page = try #require(receipt.pages.first)
        #expect(page.imageDownloaded == true)
        #expect(ImageUtils.pdfPageCount(relativePath: page.localImagePath) == 1)
        let thumbPath = ImageUtils.thumbnailPath(for: page.localImagePath)
        #expect(ImageUtils.loadReceiptImage(relativePath: thumbPath) != nil)
    }
}

} // MockURLProtocolSuites
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/MockURLProtocolSuites/ReceiptImageDownloaderTests`
Expected: FAIL to compile — "cannot find 'ReceiptImageDownloader' in scope"

- [ ] **Step 3: Write the implementation**

Create `JetLedger/Services/ReceiptImageDownloader.swift`:

```swift
//
//  ReceiptImageDownloader.swift
//  JetLedger
//

import Foundation
import Observation
import OSLog
import SwiftData
import UIKit

/// Fetches receipt images the device doesn't have — receipts that arrived by
/// email or web upload, and local captures whose files retention has reclaimed.
///
/// The presigned download URL expires, so only bytes are cached, never the URL.
@Observable
class ReceiptImageDownloader {
    /// Receipts with a download in flight, so the detail view can show progress
    /// without owning the state itself.
    private(set) var inFlightReceiptIds: Set<UUID> = []

    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "ReceiptImageDownloader")
    private let receiptAPI: ReceiptAPIService
    private let modelContext: ModelContext
    private let session: URLSession

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }

    init(
        receiptAPI: ReceiptAPIService,
        modelContext: ModelContext,
        session: URLSession = ReceiptImageDownloader.makeDefaultSession()
    ) {
        self.receiptAPI = receiptAPI
        self.modelContext = modelContext
        self.session = session
    }

    /// Downloads every page that names a server object but has no bytes on disk.
    /// Pages already present are skipped, so this is safe to call on every open.
    func downloadMissingImages(for receipt: LocalReceipt) async throws {
        let pending = receipt.pages
            .filter { !$0.imageDownloaded && $0.serverFilePath != nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard !pending.isEmpty else { return }

        let receiptId = receipt.id
        inFlightReceiptIds.insert(receiptId)
        defer { inFlightReceiptIds.remove(receiptId) }

        for page in pending {
            guard let filePath = page.serverFilePath else { continue }

            let grant = try await receiptAPI.getDownloadURL(filePath: filePath)
            guard let url = URL(string: grant.downloadUrl) else {
                throw APIError.serverError(0)
            }
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw APIError.serverError(http.statusCode)
            }

            // The page's local path is assigned by ImageUtils, which owns the
            // naming scheme and applies file protection on write.
            let savedPath: String?
            switch page.contentType {
            case .pdf:
                savedPath = ImageUtils.saveReceiptPDF(
                    data: data, receiptId: receiptId, pageIndex: page.sortOrder
                )
                if savedPath != nil {
                    _ = ImageUtils.savePDFThumbnail(
                        pdfData: data, receiptId: receiptId, pageIndex: page.sortOrder
                    )
                }
            case .jpeg:
                savedPath = ImageUtils.saveReceiptImage(
                    data: data, receiptId: receiptId, pageIndex: page.sortOrder
                )
                // A thumbnail here is what lets the list row stop showing a
                // placeholder glyph for a receipt the user has opened.
                if savedPath != nil, let image = UIImage(data: data) {
                    _ = ImageUtils.saveThumbnail(
                        from: image, receiptId: receiptId, pageIndex: page.sortOrder
                    )
                }
            }

            guard let savedPath else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "Could not save the downloaded receipt image."
                ])
            }

            page.localImagePath = savedPath
            page.imageDownloaded = true
            page.imageDownloadedAt = Date()
            trySave()
        }

        // The receipt is no longer image-less, so the detail view's "Images
        // Removed" state must not reappear for it.
        receipt.imagesCleanedUp = false
        trySave()
    }

    private func trySave() {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("SwiftData save failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/MockURLProtocolSuites/ReceiptImageDownloaderTests`
Expected: PASS, 6 tests

- [ ] **Step 5: Commit**

```bash
git add JetLedger/Services/ReceiptImageDownloader.swift JetLedgerTests/ReceiptImageDownloaderTests.swift
git commit -m "feat(sync): download and cache images for server-only receipts"
```

---

## Task 8: Retention changes

Phase 2's record deletion now destroys `dismissedAt`, which the server cannot restore — a dismissed receipt would come back on the next fetch. It is removed. Downloaded images get their own reclaim clock because a pending email receipt never reaches terminal status.

**Files:**
- Modify: `JetLedger/Services/SyncService.swift` (`performCleanup`, ~lines 487–526)
- Test: `JetLedgerTests/ReceiptRetentionTests.swift`

**Interfaces:**
- Consumes: `LocalReceiptPage.imageDownloaded`/`imageDownloadedAt` (Task 2)
- Produces: `SyncService.performCleanup() -> Set<UUID>` (unchanged signature; changed behavior)

- [ ] **Step 1: Write the failing test**

Create `JetLedgerTests/ReceiptRetentionTests.swift`:

```swift
//
//  ReceiptRetentionTests.swift
//  JetLedgerTests
//
//  Retention reclaims disk, not metadata. With the server as the source of truth
//  for the list, deleting a record destroys local-only state (a dismissed flag)
//  that no refetch can restore.
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

extension MockURLProtocolSuites {

@MainActor
@Suite(.serialized)
struct ReceiptRetentionTests {

    init() {
        MockURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: AppConstants.Cleanup.imageRetentionKey)
    }

    private struct Harness {
        let sync: SyncService
        let context: ModelContext
        let container: ModelContainer
    }

    private func makeHarness() throws -> Harness {
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let monitor = NetworkMonitor()
        monitor.setConnectedForTesting(false)
        let apiClient = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: MockURLProtocol.makeSession()
        )
        let sync = SyncService(
            receiptAPI: ReceiptAPIService(apiClient: apiClient),
            r2Upload: R2UploadService(session: MockURLProtocol.makeSession()),
            networkMonitor: monitor,
            modelContext: container.mainContext
        )
        return Harness(sync: sync, context: container.mainContext, container: container)
    }

    /// Writes a receipt with one real page file on disk.
    @discardableResult
    private func makeReceipt(
        in context: ModelContext,
        terminalDaysAgo: Int?,
        imageDownloadedDaysAgo: Int? = nil,
        isRemote: Bool = false
    ) throws -> LocalReceipt {
        let receiptId = UUID()
        let relativePath = "receipts/\(receiptId.uuidString)/page-001.jpg"
        let dir = ImageUtils.documentsDirectory()
            .appendingPathComponent("receipts/\(receiptId.uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 64).write(to: dir.appendingPathComponent("page-001.jpg"))

        let page = LocalReceiptPage(sortOrder: 0, localImagePath: relativePath)
        if let days = imageDownloadedDaysAgo {
            page.imageDownloadedAt = Date().addingTimeInterval(-Double(days) * 86_400)
        }
        let receipt = LocalReceipt(id: receiptId, accountId: UUID(), syncStatus: .uploaded, pages: [page])
        receipt.serverReceiptId = UUID()
        receipt.serverStatus = .processed
        receipt.isRemote = isRemote
        if let days = terminalDaysAgo {
            receipt.terminalStatusAt = Date().addingTimeInterval(-Double(days) * 86_400)
        }
        context.insert(receipt)
        page.receipt = receipt
        context.insert(page)
        try context.save()
        return receipt
    }

    // MARK: - Phase 1

    @Test
    func phaseOneDeletesImagesAndMarksThemRedownloadable() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, terminalDaysAgo: 10)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        let path = try #require(receipt.pages.first?.localImagePath)

        h.sync.performCleanup()

        #expect(receipt.imagesCleanedUp == true)
        #expect(ImageUtils.loadReceiptImage(relativePath: path) == nil)
        #expect(receipt.pages.first?.imageDownloaded == false,
                "a cleaned page must be re-downloadable, not a permanent dead end")
    }

    @Test
    func phaseOneLeavesRecentTerminalReceiptsAlone() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, terminalDaysAgo: 1)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        let path = try #require(receipt.pages.first?.localImagePath)

        h.sync.performCleanup()

        #expect(receipt.imagesCleanedUp == false)
        #expect(ImageUtils.loadReceiptImage(relativePath: path) != nil)
    }

    // MARK: - Phase 2 removal

    /// The record is a mirror of a row the server owns. Deleting it only causes
    /// a refetch — and loses the dismissed flag on the way.
    @Test
    func aLongTerminalReceiptKeepsItsRecord() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, terminalDaysAgo: 60)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }

        let deleted = h.sync.performCleanup()

        #expect(deleted.isEmpty)
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1,
                "retention reclaims disk, not the server's own metadata")
        #expect(receipt.imagesCleanedUp == true, "its images are still reclaimed")
    }

    /// The exact regression that forced phase 2's removal.
    @Test
    func dismissedFlagSurvivesCleanup() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, terminalDaysAgo: 60)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        receipt.dismissedAt = Date()
        try h.context.save()

        h.sync.performCleanup()

        let remaining = try #require(try h.context.fetch(FetchDescriptor<LocalReceipt>()).first)
        #expect(remaining.dismissedAt != nil,
                "deleting the record would resurrect a receipt the user dismissed")
    }

    // MARK: - Downloaded-image reclaim

    /// A pending email receipt never becomes terminal, so a terminal-status clock
    /// would never reclaim its downloaded image.
    @Test
    func downloadedImagesPastTheWindowAreReclaimed() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(
            in: h.context, terminalDaysAgo: nil, imageDownloadedDaysAgo: 30, isRemote: true
        )
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        let path = try #require(receipt.pages.first?.localImagePath)

        h.sync.performCleanup()

        #expect(ImageUtils.loadReceiptImage(relativePath: path) == nil)
        #expect(receipt.pages.first?.imageDownloaded == false)
        #expect(receipt.pages.first?.imageDownloadedAt == nil)
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1,
                "only the bytes go; the row stays")
    }

    @Test
    func recentlyDownloadedImagesAreKept() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(
            in: h.context, terminalDaysAgo: nil, imageDownloadedDaysAgo: 1, isRemote: true
        )
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        let path = try #require(receipt.pages.first?.localImagePath)

        h.sync.performCleanup()

        #expect(ImageUtils.loadReceiptImage(relativePath: path) != nil)
    }

    /// An original capture has no download stamp — its only copy is on this
    /// device and the download clock must never touch it.
    @Test
    func anOriginalCaptureIsNeverReclaimedByTheDownloadClock() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, terminalDaysAgo: nil)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        let path = try #require(receipt.pages.first?.localImagePath)

        h.sync.performCleanup()

        #expect(receipt.pages.first?.imageDownloadedAt == nil)
        #expect(ImageUtils.loadReceiptImage(relativePath: path) != nil,
                "a local capture with no download stamp is not download-cache")
    }
}

} // MockURLProtocolSuites
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/MockURLProtocolSuites/ReceiptRetentionTests`
Expected: FAIL — `aLongTerminalReceiptKeepsItsRecord` and `dismissedFlagSurvivesCleanup` fail (record deleted), `phaseOneDeletesImagesAndMarksThemRedownloadable` fails (`imageDownloaded` still true), both reclaim tests fail (no reclaim exists)

- [ ] **Step 3: Rewrite `performCleanup`**

In `JetLedger/Services/SyncService.swift`, replace the whole `performCleanup` method with:

```swift
    /// Reclaims disk. Deliberately does **not** delete SwiftData records: the
    /// list is a mirror of rows the server owns, so deleting one only forces a
    /// refetch — and destroys the local-only `dismissedAt` on the way, which is
    /// how a receipt the user swiped away comes back a day later. Rows leave the
    /// mirror through `ReceiptMirror.prune`, which acts on server evidence.
    ///
    /// Returns the IDs of receipts whose records were deleted so callers can drop
    /// live references. Nothing deletes records here today; the contract is kept
    /// because the iPad detail selection depends on it and pruning uses the same
    /// shape.
    @discardableResult
    func performCleanup() -> Set<UUID> {
        let retentionDays = UserDefaults.standard.object(forKey: AppConstants.Cleanup.imageRetentionKey) as? Int
            ?? AppConstants.Cleanup.defaultImageRetentionDays
        let imageCutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!

        reclaimTerminalReceiptImages(olderThan: imageCutoff)
        reclaimDownloadedImages(olderThan: imageCutoff)

        trySave()
        cleanOrphanedFiles()
        return []
    }

    /// Terminal receipts give up their local images once the retention window
    /// passes. `imageDownloaded = false` is what makes this recoverable: the
    /// detail view re-downloads from the server instead of showing a permanent
    /// "Images Removed".
    private func reclaimTerminalReceiptImages(olderThan cutoff: Date) {
        let descriptor = FetchDescriptor<LocalReceipt>(
            predicate: #Predicate<LocalReceipt> { receipt in
                receipt.terminalStatusAt != nil
            }
        )
        guard let receipts = try? modelContext.fetch(descriptor) else { return }

        for receipt in receipts {
            guard let terminalDate = receipt.terminalStatusAt,
                  terminalDate < cutoff,
                  !receipt.imagesCleanedUp
            else { continue }

            ImageUtils.deleteReceiptImages(receiptId: receipt.id)
            receipt.imagesCleanedUp = true
            for page in receipt.pages {
                page.imageDownloaded = false
                page.imageDownloadedAt = nil
            }
        }
    }

    /// Images fetched from the server are a cache, and a receipt that never
    /// reaches a terminal status — a pending email forward, say — would otherwise
    /// hold its downloaded bytes forever.
    ///
    /// Keyed on `imageDownloadedAt`, not on the receipt's `isRemote` flag: a local
    /// capture whose files were reclaimed above and later re-downloaded for
    /// viewing is `isRemote == false`, but those bytes came from the server and
    /// must be reclaimable again. Original captures never carry the stamp.
    private func reclaimDownloadedImages(olderThan cutoff: Date) {
        let descriptor = FetchDescriptor<LocalReceiptPage>()
        guard let pages = try? modelContext.fetch(descriptor) else { return }

        for page in pages {
            guard let downloadedAt = page.imageDownloadedAt,
                  downloadedAt < cutoff,
                  page.imageDownloaded
            else { continue }

            ImageUtils.deletePageImage(relativePath: page.localImagePath)
            page.imageDownloaded = false
            page.imageDownloadedAt = nil
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/MockURLProtocolSuites/ReceiptRetentionTests`
Expected: PASS, 7 tests

- [ ] **Step 5: Confirm the existing upload-queue suite still passes**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/MockURLProtocolSuites/SyncServiceRetryTests`
Expected: PASS, all pre-existing tests unchanged

- [ ] **Step 6: Commit**

```bash
git add JetLedger/Services/SyncService.swift JetLedgerTests/ReceiptRetentionTests.swift
git commit -m "fix(cleanup): reclaim images, keep records, add a download-age clock"
```

---

## Task 9: Service wiring

**Files:**
- Modify: `JetLedger/JetLedgerApp.swift` (`handleAuthStateChange`, both `.authenticated` and `.offlineReady` branches; `rootView`)
- Modify: `JetLedger/Views/Main/MainView.swift`

**Interfaces:**
- Consumes: `ReceiptListService.init(receiptAPI:networkMonitor:modelContext:)` and `refresh(accountId:)` (Task 6); `ReceiptImageDownloader.init(receiptAPI:modelContext:session:)` (Task 7)
- Produces: `ReceiptListService` and `ReceiptImageDownloader` reachable from any view via `@Environment`

- [ ] **Step 1: Add the state properties**

In `JetLedger/JetLedgerApp.swift`, after `@State private var pushService: PushNotificationService?`:

```swift
    @State private var receiptListService: ReceiptListService?
    @State private var receiptImageDownloader: ReceiptImageDownloader?
```

- [ ] **Step 2: Construct them in the `.authenticated` branch**

In `handleAuthStateChange`, in the `.authenticated` case, immediately after `syncService = sync`:

```swift
            receiptListService = ReceiptListService(
                receiptAPI: receiptAPI,
                networkMonitor: networkMonitor,
                modelContext: context
            )
            receiptImageDownloader = ReceiptImageDownloader(
                receiptAPI: receiptAPI,
                modelContext: context
            )
```

- [ ] **Step 3: Construct them in the `.offlineReady` branch**

In the `.offlineReady` case, immediately after `syncService = sync`, add the identical two assignments. Offline they never issue a request — `ReceiptListService.fetchPage` returns early when `networkMonitor.isConnected` is false — but the views require them to be present.

- [ ] **Step 4: Clear them on sign-out**

In the `.unauthenticated` case, next to `syncService = nil`:

```swift
            receiptListService = nil
            receiptImageDownloader = nil
```

- [ ] **Step 5: Pass them into `MainView`**

In `rootView`, both `.authenticated` and `.offlineReady` cases currently read:

```swift
            if let accountService, let syncService, let tripReferenceService, let pushService {
```

Change both conditions to also bind the new services, and add two `.environment(...)` modifiers. The `.authenticated` case becomes:

```swift
        case .authenticated:
            if let accountService, let syncService, let tripReferenceService, let pushService,
               let receiptListService, let receiptImageDownloader {
                MainView()
                    .environment(accountService)
                    .environment(syncService)
                    .environment(tripReferenceService)
                    .environment(pushService)
                    .environment(receiptListService)
                    .environment(receiptImageDownloader)
            } else {
                ProgressView("Loading accounts...")
            }
```

And `.offlineReady`:

```swift
        case .offlineReady:
            if let accountService, let syncService, let tripReferenceService, let pushService,
               let receiptListService, let receiptImageDownloader {
                MainView(isOfflineMode: true)
                    .environment(accountService)
                    .environment(syncService)
                    .environment(tripReferenceService)
                    .environment(pushService)
                    .environment(receiptListService)
                    .environment(receiptImageDownloader)
            } else {
                ProgressView("Loading...")
            }
```

- [ ] **Step 6: Read the service in `MainView` and refresh at the four sync points**

In `JetLedger/Views/Main/MainView.swift`, add after the other `@Environment` properties:

```swift
    @Environment(ReceiptListService.self) private var receiptListService
```

Replace the `.task(id:)` modifier body:

```swift
        .task(id: accountService.selectedAccount?.id) {
            if !isOfflineMode, let accountId = accountService.selectedAccount?.id {
                await tripReferenceService.loadTripReferences(for: accountId)
                await syncService.syncReceiptStatuses()
                await refreshReceiptList(accountId: accountId)
                runCleanup()
            }
        }
```

In the `scenePhase` `.active` handler, replace the inner `Task { ... }` block:

```swift
                Task {
                    // Memberships can change while the app is backgrounded —
                    // e.g. accepting an org invitation from Mail on this same
                    // device. Refresh silently so the account switcher (and
                    // roles) update on return instead of requiring a relaunch.
                    await accountService.refreshAccounts()
                    await syncService.syncReceiptStatuses()
                    await refreshReceiptList(accountId: accountId)
                    runCleanup()
                }
```

Add this helper next to `runCleanup()`:

```swift
    /// Refreshes the server-backed list and drops the detail selection if the
    /// refresh proved that receipt was deleted on the web — a live
    /// `ReceiptDetailView` holding a destroyed `@Model` crashes on the next body
    /// evaluation.
    private func refreshReceiptList(accountId: UUID) async {
        let selectedId = selectedReceipt?.id
        let pruned = await receiptListService.refresh(accountId: accountId)
        if let selectedId, pruned.contains(selectedId) {
            selectedReceipt = nil
        }
    }
```

- [ ] **Step 7: Build**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' -quiet build`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Run the full test suite**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test`
Expected: PASS, no regressions

- [ ] **Step 9: Commit**

```bash
git add JetLedger/JetLedgerApp.swift JetLedger/Views/Main/MainView.swift
git commit -m "feat(app): wire the receipt list service into the app and refresh points"
```

---

## Task 10: Row presentation helpers

Pulled into pure functions so the presentation rules are testable without instantiating SwiftUI views.

**Files:**
- Create: `JetLedger/Views/Main/ReceiptRowFormatting.swift`
- Modify: `JetLedger/Views/Main/ReceiptRowView.swift`
- Modify: `JetLedger/Views/Detail/ReceiptDetailView.swift` (move `rejectionReasonLabel` out)
- Test: `JetLedgerTests/ReceiptRowFormattingTests.swift`

**Interfaces:**
- Consumes: `ReceiptSource` (Task 2); `CachedTripReference` (existing, has `id`, `accountId`, `externalId`, `name`, `displayTitle`)
- Produces:
  - `ReceiptRowFormatting.tripLabel(externalId:name:tripReferenceId:cache:) -> String?`
  - `ReceiptRowFormatting.placeholderIcon(source:imagesCleanedUp:) -> String`
  - `ReceiptRowFormatting.rejectionReasonLabel(_:) -> String`

- [ ] **Step 1: Write the failing test**

Create `JetLedgerTests/ReceiptRowFormattingTests.swift`:

```swift
//
//  ReceiptRowFormattingTests.swift
//  JetLedgerTests
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

@MainActor
@Suite
struct ReceiptRowFormattingTests {

    private func makeCache(id: UUID, externalId: String?, name: String?) throws -> [CachedTripReference] {
        let schema = Schema([
            LocalReceipt.self, LocalReceiptPage.self,
            CachedAccount.self, CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let context = try ModelContainer(for: schema, configurations: [config]).mainContext
        let ref = CachedTripReference(
            id: id, accountId: UUID(), externalId: externalId, name: name, createdAt: nil
        )
        context.insert(ref)
        return [ref]
    }

    // MARK: - Trip label

    @Test
    func prefersTheLocallyStoredTripFields() throws {
        let label = ReceiptRowFormatting.tripLabel(
            externalId: "N4471-0713", name: "Teterboro", tripReferenceId: UUID(), cache: []
        )
        #expect(label == "Trip N4471-0713")
    }

    @Test
    func resolvesAMirroredRowsTripFromTheCache() throws {
        let tripId = UUID()
        let cache = try makeCache(id: tripId, externalId: "ABC-123", name: "Aspen")

        let label = ReceiptRowFormatting.tripLabel(
            externalId: nil, name: nil, tripReferenceId: tripId, cache: cache
        )

        #expect(label == "Trip ABC-123")
    }

    @Test
    func fallsBackToTheTripNameWhenThereIsNoExternalId() throws {
        let tripId = UUID()
        let cache = try makeCache(id: tripId, externalId: nil, name: "Aspen")

        let label = ReceiptRowFormatting.tripLabel(
            externalId: nil, name: nil, tripReferenceId: tripId, cache: cache
        )

        #expect(label == "Aspen")
    }

    /// A raw UUID is never acceptable row copy.
    @Test
    func omitsTheLabelOnACacheMiss() throws {
        let label = ReceiptRowFormatting.tripLabel(
            externalId: nil, name: nil, tripReferenceId: UUID(), cache: []
        )
        #expect(label == nil)
    }

    @Test
    func omitsTheLabelWhenThereIsNoTripAtAll() {
        let label = ReceiptRowFormatting.tripLabel(
            externalId: nil, name: nil, tripReferenceId: nil, cache: []
        )
        #expect(label == nil)
    }

    // MARK: - Placeholder glyph

    @Test
    func placeholderCarriesTheSourceForReceiptsThisDeviceNeverCaptured() {
        #expect(ReceiptRowFormatting.placeholderIcon(source: .email, imagesCleanedUp: false) == "envelope.fill")
        #expect(ReceiptRowFormatting.placeholderIcon(source: .upload, imagesCleanedUp: false) == "tray.and.arrow.up.fill")
        #expect(ReceiptRowFormatting.placeholderIcon(source: .ios, imagesCleanedUp: false) == "doc.fill")
        #expect(ReceiptRowFormatting.placeholderIcon(source: nil, imagesCleanedUp: false) == "doc.fill")
    }

    /// Retention's own glyph explains the absence better than the source does.
    @Test
    func cleanedUpImagesKeepTheRetentionGlyph() {
        #expect(ReceiptRowFormatting.placeholderIcon(source: .email, imagesCleanedUp: true)
                == "clock.badge.checkmark")
    }

    // MARK: - Rejection reasons

    @Test
    func mapsTheFourServerRejectionReasons() {
        #expect(ReceiptRowFormatting.rejectionReasonLabel("duplicate") == "Duplicate")
        #expect(ReceiptRowFormatting.rejectionReasonLabel("unreadable") == "Unreadable")
        #expect(ReceiptRowFormatting.rejectionReasonLabel("not_business") == "Not Business")
        #expect(ReceiptRowFormatting.rejectionReasonLabel("other") == "Other")
    }

    @Test
    func humanizesAnUnknownReason() {
        #expect(ReceiptRowFormatting.rejectionReasonLabel("some_new_reason") == "Some New Reason")
    }

    @Test
    func passesThroughTheStatusSyncSentence() {
        let sentence = "Removed during review on the web."
        #expect(ReceiptRowFormatting.rejectionReasonLabel(sentence) == sentence)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/ReceiptRowFormattingTests`
Expected: FAIL to compile — "cannot find 'ReceiptRowFormatting' in scope"

- [ ] **Step 3: Write the implementation**

Create `JetLedger/Views/Main/ReceiptRowFormatting.swift`:

```swift
//
//  ReceiptRowFormatting.swift
//  JetLedger
//

import Foundation

/// Presentation rules shared by the list row and the detail screen. Pure
/// functions so the rules can be tested without standing up a view.
enum ReceiptRowFormatting {

    /// A receipt's trip label.
    ///
    /// Local captures carry the trip's external id and name on the row itself.
    /// A mirrored row has only `trip_reference_id`, so it is resolved against the
    /// cached trip references loaded per account on launch. A miss omits the
    /// label entirely — showing a raw UUID is never acceptable row copy, and the
    /// cache refreshes on the next launch, so misses are rare and self-healing.
    static func tripLabel(
        externalId: String?,
        name: String?,
        tripReferenceId: UUID?,
        cache: [CachedTripReference]
    ) -> String? {
        if let externalId { return "Trip \(externalId)" }
        if let name { return name }

        guard let tripReferenceId,
              let match = cache.first(where: { $0.id == tripReferenceId })
        else { return nil }

        if let externalId = match.externalId { return "Trip \(externalId)" }
        return match.name
    }

    /// The thumbnail placeholder for a receipt with no image on disk.
    ///
    /// For receipts this app never created, the glyph is the only signal that a
    /// receipt the pilot doesn't remember capturing arrived by email or from the
    /// web. Retention's own glyph wins when it applies — "these were cleaned up"
    /// explains the absence better than the source does.
    static func placeholderIcon(source: ReceiptSource?, imagesCleanedUp: Bool) -> String {
        if imagesCleanedUp { return "clock.badge.checkmark" }
        switch source {
        case .email: return "envelope.fill"
        case .upload: return "tray.and.arrow.up.fill"
        case .ios, nil: return "doc.fill"
        }
    }

    /// Server rejection reasons are `duplicate`, `unreadable`, `not_business`,
    /// `other`. Anything else — including the sentence `syncReceiptStatuses`
    /// writes for a receipt removed during web review — is humanized or passed
    /// through unchanged.
    static func rejectionReasonLabel(_ reason: String) -> String {
        switch reason {
        case "duplicate": return "Duplicate"
        case "unreadable": return "Unreadable"
        case "not_business": return "Not Business"
        case "other": return "Other"
        default:
            guard reason.contains("_") else { return reason }
            return reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test -only-testing:JetLedgerTests/ReceiptRowFormattingTests`
Expected: PASS, 11 tests

- [ ] **Step 5: Adopt the helpers in `ReceiptRowView`**

In `JetLedger/Views/Main/ReceiptRowView.swift`, add the trip-reference cache to `ReceiptRowView` and route the label through the helper. Replace the `tripLabel` computed property and add an environment read:

```swift
struct ReceiptRowView: View {
    let receipt: LocalReceipt

    @Environment(TripReferenceService.self) private var tripReferenceService
```

```swift
    private var tripLabel: String? {
        ReceiptRowFormatting.tripLabel(
            externalId: receipt.tripReferenceExternalId,
            name: receipt.tripReferenceName,
            tripReferenceId: receipt.tripReferenceId,
            cache: tripReferenceService.tripReferences
        )
    }
```

In the private `ReceiptThumbnail` view, replace its `placeholderIcon` computed property:

```swift
    private var placeholderIcon: String {
        ReceiptRowFormatting.placeholderIcon(
            source: receipt.source,
            imagesCleanedUp: receipt.imagesCleanedUp
        )
    }
```

Also update `ReceiptThumbnail.badge` so a mirrored row with no pages yet still shows its count, replacing the first condition:

```swift
    private var badge: String? {
        // A mirrored row has no page records until its detail is fetched, so the
        // server's count is the only thing that knows there is more than one.
        let count = receipt.pages.isEmpty ? receipt.imageCount : receipt.pages.count
        if count > 1 {
            return "\(count)"
        }
        if let pdfPage = receipt.pages.first(where: { $0.contentType == .pdf }) {
            if let pageCount = ImageUtils.pdfPageCount(relativePath: pdfPage.localImagePath),
               pageCount > 1 {
                return "PDF·\(pageCount)"
            }
            return "PDF"
        }
        return nil
    }
```

- [ ] **Step 6: Delete the duplicate in `ReceiptDetailView`**

In `JetLedger/Views/Detail/ReceiptDetailView.swift`, delete the private `rejectionReasonLabel(_:)` method entirely and change its one call site inside `rejectionCallout`:

```swift
                    Text(ReceiptRowFormatting.rejectionReasonLabel(reason))
```

- [ ] **Step 7: Build and run the full suite**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test`
Expected: BUILD SUCCEEDED, all tests pass

- [ ] **Step 8: Commit**

```bash
git add JetLedger/Views/Main/ReceiptRowFormatting.swift JetLedger/Views/Main/ReceiptRowView.swift \
        JetLedger/Views/Detail/ReceiptDetailView.swift JetLedgerTests/ReceiptRowFormattingTests.swift
git commit -m "feat(list): resolve trip labels and source glyphs for mirrored rows"
```

---

## Task 11: List layout and infinite scroll

**Files:**
- Modify: `JetLedger/Views/Main/ReceiptListView.swift`

**Interfaces:**
- Consumes: `ReceiptListService.loadNextPage(accountId:)`, `.hasMore`, `.isLoadingPage`, `.loadError` (Task 6); `LocalReceipt.dismissedAt` (Task 2)
- Produces: no new API

- [ ] **Step 1: Filter dismissed rows out of the query**

In `JetLedger/Views/Main/ReceiptListView.swift`, replace the `init` predicate:

```swift
    init(accountId: UUID, selectedReceipt: Binding<LocalReceipt?>, @ViewBuilder header: () -> Header) {
        self.accountId = accountId
        _selectedReceipt = selectedReceipt
        _receipts = Query(
            filter: #Predicate<LocalReceipt> { receipt in
                receipt.accountId == accountId && receipt.dismissedAt == nil
            },
            sort: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        self.header = header()
    }
```

- [ ] **Step 2: Replace the Active/Completed split with pinned queue + flat history**

Add the service and account id, then replace the `activeReceipts` / `completedReceipts` / `visibleCompleted` / `hiddenCompletedCount` properties and the `showAllCompleted` state with:

```swift
    @Environment(ReceiptListService.self) private var receiptListService
```

```swift
    /// Receipts that exist only on this phone. They are actionable — retry,
    /// manage pages — and nothing else knows about them, so they pin to the top.
    /// A row leaves this section the moment it gets a server id.
    private var onDeviceReceipts: [LocalReceipt] {
        receipts.filter { $0.serverReceiptId == nil }
    }

    /// Everything the server knows about, in the order the server returns it.
    private var historyReceipts: [LocalReceipt] {
        receipts.filter { $0.serverReceiptId != nil }
    }
```

Delete `@State private var showAllCompleted = false`.

- [ ] **Step 3: Rewrite the list body**

Replace the `else { ... }` branch of `if receipts.isEmpty` in `var body` with:

```swift
            } else {
                if !onDeviceReceipts.isEmpty {
                    Section {
                        ForEach(onDeviceReceipts) { receipt in
                            ReceiptRowView(receipt: receipt)
                                .tag(receipt)
                                .swipeActions(edge: .trailing) {
                                    retryButton(for: receipt)
                                }
                        }
                    } header: {
                        Text("On This Device")
                    }
                }

                if !historyReceipts.isEmpty {
                    Section {
                        ForEach(historyReceipts) { receipt in
                            ReceiptRowView(receipt: receipt)
                                .tag(receipt)
                                .swipeActions(edge: .trailing) {
                                    dismissButton(for: receipt)
                                    retryButton(for: receipt)
                                }
                                .onAppear {
                                    // Infinite scroll: the last row appearing is
                                    // the trigger. loadNextPage swallows repeat
                                    // calls while a page is in flight.
                                    if receipt.id == historyReceipts.last?.id {
                                        Task { await receiptListService.loadNextPage(accountId: accountId) }
                                    }
                                }
                        }
                    }
                }

                if receiptListService.isLoadingPage {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
```

- [ ] **Step 4: Make the empty state honest about a failed load**

Replace the `if receipts.isEmpty` branch:

```swift
            if receipts.isEmpty {
                if let loadError = receiptListService.loadError {
                    // An empty mirror plus a failed fetch is not "no receipts" —
                    // saying so would be a lie the user acts on.
                    ContentUnavailableView {
                        Label("Couldn't Load Receipts", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") {
                            Task { await receiptListService.refresh(accountId: accountId) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(.brandPrimary))
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView {
                        Label("No Receipts Yet", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Tap Scan Receipt to capture your first receipt.")
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            } else {
```

- [ ] **Step 5: Make pull-to-refresh reload the server list**

Pull-to-refresh is one of the four points the list must re-fetch, and it lives here rather than in `MainView`. Replace the `.refreshable` modifier body:

```swift
        .refreshable {
            syncService.processQueue()
            await accountService.refreshAccounts()
            await syncService.syncReceiptStatuses()
            // Capture before cleanup so the check never reads a deleted model.
            let selectedId = selectedReceipt?.id
            let pruned = await receiptListService.refresh(accountId: accountId)
            syncService.performCleanup()
            if let selectedId, pruned.contains(selectedId) {
                selectedReceipt = nil
            }
        }
```

`performCleanup` no longer deletes records (Task 8), so only the mirror's pruned ids can invalidate the selection.

- [ ] **Step 6: Replace the remove button with a dismiss button**

Replace `removeButton(for:)` with:

```swift
    /// Rejected receipts are dead weight once seen. Dismissing hides the row on
    /// this device only — the server record stays for admin review on the web,
    /// and `dismissedAt` is persisted so the next page fetch doesn't bring it
    /// straight back.
    @ViewBuilder
    private func dismissButton(for receipt: LocalReceipt) -> some View {
        if receipt.serverStatus == .rejected {
            Button(role: .destructive) {
                if selectedReceipt == receipt {
                    selectedReceipt = nil
                }
                syncService.dismissRejectedReceipt(receipt)
            } label: {
                Label("Dismiss", systemImage: "eye.slash")
            }
        }
    }
```

- [ ] **Step 7: Add `dismissRejectedReceipt` to `SyncService`**

In `JetLedger/Services/SyncService.swift`, replace `removeRejectedReceiptLocally(_:)` with:

```swift
    /// Hides a rejected receipt on this device. The server record is deliberately
    /// left alone — permanently deleting a rejected receipt is an admin decision
    /// made on the web.
    ///
    /// The row is flagged rather than deleted: the list is now a mirror of the
    /// server's, so a deleted row comes straight back on the next page fetch.
    /// Local images go immediately; they are the only thing costing disk.
    func dismissRejectedReceipt(_ receipt: LocalReceipt) {
        guard receipt.serverStatus == .rejected else { return }
        ImageUtils.deleteReceiptImages(receiptId: receipt.id)
        for page in receipt.pages {
            page.imageDownloaded = false
            page.imageDownloadedAt = nil
        }
        receipt.imagesCleanedUp = true
        receipt.dismissedAt = Date()
        trySave()
    }
```

- [ ] **Step 8: Update the existing tests for the renamed method**

In `JetLedgerTests/SyncServiceRetryTests.swift`, rename the two tests and update their assertions:

```swift
    @Test
    func dismissRejectedReceiptHidesItLocallyWithoutNetwork() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .uploaded)
        receipt.serverReceiptId = UUID()
        receipt.serverStatus = .rejected
        try h.context.save()
        let imageDir = ImageUtils.documentsDirectory()
            .appendingPathComponent("receipts/\(receipt.id.uuidString)")
        let log = RequestLog()
        MockURLProtocol.handler = { request in
            log.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        h.sync.dismissRejectedReceipt(receipt)

        #expect(receipt.dismissedAt != nil)
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1,
                "the row must survive so the next page fetch doesn't resurrect it")
        #expect(!FileManager.default.fileExists(atPath: imageDir.path))
        #expect(log.all.isEmpty, "server record must survive — deletion is an admin decision on the web")
    }

    @Test
    func dismissRejectedReceiptIgnoresNonRejectedReceipts() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .uploaded)
        receipt.serverStatus = .pending
        try h.context.save()
        defer { removeFiles(for: receipt) }

        h.sync.dismissRejectedReceipt(receipt)

        #expect(receipt.dismissedAt == nil)
    }
```

- [ ] **Step 9: Build and run the full suite**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test`
Expected: BUILD SUCCEEDED, all tests pass

- [ ] **Step 10: Verify no stale references**

Run: `grep -rn "removeRejectedReceiptLocally\|showAllCompleted" --include="*.swift" .`
Expected: no output

- [ ] **Step 11: Commit**

```bash
git add JetLedger/Views/Main/ReceiptListView.swift JetLedger/Services/SyncService.swift \
        JetLedgerTests/SyncServiceRetryTests.swift
git commit -m "feat(list): pinned device queue over a server-paged history"
```

---

## Task 12: Detail screen and deep links

**Files:**
- Modify: `JetLedger/Views/Detail/ReceiptDetailView.swift`
- Modify: `JetLedger/Views/Main/MainView.swift` (`navigateToReceipt`)

**Interfaces:**
- Consumes: `ReceiptListService.fetchDetail(serverReceiptId:accountId:)` and `DetailFetchResult` (Task 6); `ReceiptImageDownloader.downloadMissingImages(for:)` (Task 7)
- Produces: no new API

- [ ] **Step 1: Load detail and images when the screen appears**

In `JetLedger/Views/Detail/ReceiptDetailView.swift`, add the two services and load state:

```swift
    @Environment(ReceiptListService.self) private var receiptListService
    @Environment(ReceiptImageDownloader.self) private var imageDownloader

    @State private var isLoadingImages = false
    @State private var imageLoadError: String?
    @State private var removedFromServer = false
```

Add this `.task` to the outer `VStack` in `body`, after `.navigationBarTitleDisplayMode(.inline)`:

```swift
        .task(id: receipt.id) {
            await loadRemoteContentIfNeeded()
        }
```

And add the method:

```swift
    /// Fetches detail and downloads any missing images. Safe to call on every
    /// appearance — pages that already have bytes are skipped.
    private func loadRemoteContentIfNeeded() async {
        guard let serverId = receipt.serverReceiptId else { return }
        let needsPages = receipt.detailFetchedAt == nil
        let needsBytes = receipt.pages.contains { !$0.imageDownloaded }
        guard needsPages || needsBytes else { return }

        isLoadingImages = true
        defer { isLoadingImages = false }
        imageLoadError = nil

        if needsPages {
            switch await receiptListService.fetchDetail(
                serverReceiptId: serverId, accountId: receipt.accountId
            ) {
            case .ok:
                break
            case .removedFromServer:
                removedFromServer = true
                return
            case .deleted:
                // The mirrored row is gone; pop back before the body reads it.
                selectedReceipt = nil
                return
            case .failed(let message):
                imageLoadError = message
                return
            }
        }

        do {
            try await imageDownloader.downloadMissingImages(for: receipt)
        } catch {
            imageLoadError = error.localizedDescription
        }
    }
```

- [ ] **Step 2: Replace the gallery branch with the four real states**

Replace the `if receipt.imagesCleanedUp { ... } else { ... }` block at the top of `body`:

```swift
            if isLoadingImages && receipt.pages.allSatisfy({ !$0.imageDownloaded }) {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading receipt…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let imageLoadError {
                ContentUnavailableView {
                    Label("Couldn't Load Images", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(imageLoadError)
                } actions: {
                    Button("Try Again") {
                        Task { await loadRemoteContentIfNeeded() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(.brandPrimary))
                }
                .frame(maxHeight: .infinity)
            } else if receipt.pages.isEmpty || receipt.pages.allSatisfy({ !$0.imageDownloaded }) {
                // Nothing on disk and nothing left to try: only reachable when
                // the receipt has no server record to download from.
                ContentUnavailableView {
                    Label("Images Removed", systemImage: "clock.badge.checkmark")
                } description: {
                    if let date = receipt.terminalStatusAt {
                        Text("This receipt was \(receipt.serverStatus == .rejected ? "rejected" : "processed") on \(date, format: .dateTime.month().day().year()). Local images have been removed to save space.")
                    } else {
                        Text("Local images have been removed to save space.")
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ImageGalleryView(pages: receipt.pages.filter(\.imageDownloaded))
                    .frame(maxHeight: .infinity)
            }
```

- [ ] **Step 3: Gate the actions menu by origin**

Replace `actionsMenu`'s `confirmationDialog` contents:

```swift
        .confirmationDialog("Actions", isPresented: $showActionsSheet, titleVisibility: .hidden) {
            Button("Edit Details") { showEditSheet = true }

            // Retry and page management act on local files. A mirrored row has
            // none, so there is nothing to retry or reorder.
            if !receipt.isRemote {
                if receipt.pages.count > 1 && (receipt.syncStatus == .queued || receipt.syncStatus == .failed) {
                    Button("Manage Pages") { showManagePages = true }
                }

                if receipt.syncStatus == .failed || receipt.syncStatus == .queued {
                    Button("Retry Upload") { syncService.retryReceipt(receipt) }
                }

                // The phone does not destroy server records it had no part in
                // creating. Mirrored rows are dismissed from the list instead.
                Button("Delete", role: .destructive) { showDeleteConfirm = true }
            }
        }
```

- [ ] **Step 4: Surface a server-side removal**

Add to `metadataSection`'s `VStack`, immediately before the `if receipt.serverStatus == .rejected` block:

```swift
                if removedFromServer {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(.statusWarningContent))
                        Text("This receipt was removed during review on the web. Your copy is still on this device.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.statusWarning).opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
```

- [ ] **Step 5: Make deep links fetch a receipt that isn't local**

In `JetLedger/Views/Main/MainView.swift`, replace `navigateToReceipt(serverReceiptId:)`:

```swift
    /// A push can name a receipt this device never uploaded — an email forward,
    /// or one captured on another phone. Falling through to a detail fetch is
    /// what stops the tap landing on a plain list.
    private func navigateToReceipt(serverReceiptId: UUID) {
        let descriptor = FetchDescriptor<LocalReceipt>()
        if let receipts = try? modelContext.fetch(descriptor),
           let match = receipts.first(where: { $0.serverReceiptId == serverReceiptId }) {
            selectedReceipt = match
            return
        }

        guard let accountId = accountService.selectedAccount?.id else { return }
        Task {
            switch await receiptListService.fetchDetail(
                serverReceiptId: serverReceiptId, accountId: accountId
            ) {
            case .ok(let receipt), .removedFromServer(let receipt):
                selectedReceipt = receipt
            case .deleted:
                deepLinkErrorMessage = "That receipt is no longer available."
            case .failed(let message):
                deepLinkErrorMessage = message
            }
        }
    }
```

Add the state property next to the other `@State` declarations:

```swift
    @State private var deepLinkErrorMessage: String?
```

And an alert, next to the existing `.alert("Import Error", ...)`:

```swift
        .alert("Receipt Unavailable", isPresented: Binding(
            get: { deepLinkErrorMessage != nil },
            set: { if !$0 { deepLinkErrorMessage = nil } }
        )) {
            Button("OK") { deepLinkErrorMessage = nil }
        } message: {
            Text(deepLinkErrorMessage ?? "")
        }
```

- [ ] **Step 6: Build and run the full suite**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test`
Expected: BUILD SUCCEEDED, all tests pass

- [ ] **Step 7: Commit**

```bash
git add JetLedger/Views/Detail/ReceiptDetailView.swift JetLedger/Views/Main/MainView.swift
git commit -m "feat(detail): fetch server receipts on demand and deep-link to them"
```

---

## Task 13: Documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Rewrite the Sync & Upload section's list description**

In `CLAUDE.md`, in the **Sync & Upload** section, replace the bullet reading `Status sync on foreground + pull-to-refresh (bulk GET /api/receipts/status)` with:

```markdown
- **The receipt list is server-driven.** `GET /api/receipts` (paged, 25/page, newest first) is
  mirrored into SwiftData by `ReceiptMirror`, so history survives reinstall, appears on every
  device, and includes receipts that arrived by email forward or web upload (`source` of `email`
  or `upload`). `ReceiptListService` owns paging and the detail fetch; `ReceiptImageDownloader`
  fetches images on demand and caches them to disk. `GET /api/receipts/status?ids=...` remains as
  the cheap poll for receipts uploaded in the current session. Added 2026-07-27.
- **`isRemote` means "this device has no capture origin for this row"**; `imageDownloaded` means
  "bytes exist on disk at `localImagePath`". Both had been inert since the Supabase-era sync was
  removed. `LocalReceiptPage.serverFilePath` is deliberately separate from `r2ImagePath` — the
  latter is a 24h grant that expires, the former a confirmed object that does not.
- **A mirrored row is pruned only on server evidence.** Within a fetched page, a row dated between
  that page's newest and oldest entries but absent from it was deleted on the web. Rows with
  `isRemote == false` are never pruned — one that got its `serverReceiptId` mid-request would
  otherwise be deleted out from under the user.
- Server timestamps are SQLite `datetime('now')` (`"2026-07-27 14:03:22"`, UTC, no `T`). Parse with
  `ServerDateFormatter`, never `ISO8601DateFormatter`.
- Status sync on foreground + pull-to-refresh (bulk `GET /api/receipts/status`)
```

- [ ] **Step 2: Update the rejected-receipt bullet**

Replace the bullet beginning `Rejected receipts can be swiped away in the list` with:

```markdown
- Rejected receipts can be swiped away in the list — **local hide only**
  (`dismissRejectedReceipt` sets `dismissedAt`), no API call: permanently deleting a rejected
  receipt is an admin decision made on the web. The flag is persisted rather than the row deleted,
  because the list is now a server mirror and a deleted row returns on the next page fetch.
  Decided 2026-07-18, reworked 2026-07-27.
```

- [ ] **Step 3: Update the auto-cleanup bullet**

Replace the bullet beginning `Auto-cleanup: images deleted after retention period` with:

```markdown
- Auto-cleanup reclaims **disk, not records**: local images are deleted after the retention period
  (`@AppStorage("imageRetentionDays")`) and the pages marked `imageDownloaded = false` so the
  detail view re-downloads them. Downloaded images have their own clock keyed on
  `imageDownloadedAt` — a pending email receipt never reaches terminal status, so nothing else
  would ever reclaim them. SwiftData records are no longer deleted: the row is a mirror of one the
  server owns, and deleting it destroyed the local-only `dismissedAt`, resurrecting receipts the
  user had dismissed.
```

- [ ] **Step 4: Document the test simulator**

The Build section of `CLAUDE.md` gives one `xcodebuild` line, for `build`. That destination cannot run tests, and `xcodebuild test` exits 0 anyway — which reads as a pass. Replace the code block in the **Build** section with:

```sh
# Build — app target deploys to iOS 17.6
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build

# Test — needs an iOS 26.x runtime: the *test* targets inherit the project's
# 26.2 deployment target, so the 18.4 sim above fails before running anything.
# xcodebuild test exits 0 on that failure — check for "** TEST SUCCEEDED **".
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test
```

- [ ] **Step 5: Verify the claims match the code**

Run: `grep -rn "func dismissRejectedReceipt\|func prune\|imageDownloadedAt" --include="*.swift" JetLedger/`
Expected: matches in `SyncService.swift`, `ReceiptMirror.swift`, `LocalReceiptPage.swift`

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: describe the server-driven receipt list in CLAUDE.md"
```

---

## Manual verification

The endpoints do not exist yet, so none of this can run against a real server. When the Go PR deploys, verify in order:

1. **Fresh install with existing server history** — sign in on a device with no local data. The list populates from the server; rows show status, date, and rejection reason.
2. **Email-forwarded receipt** — forward a receipt to the account. It appears with an envelope placeholder; opening it downloads the image and the row's thumbnail fills in on return.
3. **Infinite scroll** — an account with >25 receipts pages as you scroll, with a footer spinner and no duplicate rows.
4. **Second device** — the same account on iPad shows the same history.
5. **Offline** — enable airplane mode and relaunch. History renders from the mirror; opening an already-downloaded receipt shows its image.
6. **Dismiss persistence** — dismiss a rejected receipt, pull to refresh, confirm it stays gone. Force-quit, relaunch, confirm still gone.
7. **Deleted on the web** — delete a receipt from the web app, pull to refresh, confirm the row disappears.
8. **Deep link** — with a push naming a receipt not in local storage, tapping opens its detail.
9. **Capture round-trip** — capture a receipt offline, go online, confirm it uploads and merges into a single row rather than appearing twice.
