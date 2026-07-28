# Server-Driven Receipt List — Design

**Date:** 2026-07-27
**Status:** Approved, not yet implemented
**Depends on:** Two Go API endpoints (`GET /api/receipts`, `GET /api/receipts/{id}`) being built in
parallel. Contract is frozen; neither is deployed at time of writing.

---

## Problem

The app's receipt list is driven entirely by local state. Every row in the list is a `LocalReceipt`
this device created; the server is only ever asked "what happened to these specific IDs?" via
`GET /api/receipts/status?ids=...`. The server never tells the app what exists.

Three consequences:

1. **Reinstall or a new phone wipes the submission history from the UI** even though the server
   still has every receipt.
2. **iPhone and iPad show different histories** — each device knows only its own captures.
3. **The local ID list grows without bound** against the status endpoint's 50-ID cap.

Receipts that arrived by email forward or web upload have never been visible in the app at all.

## Goal

Make the list a view onto the server's record of *this user's own* staged receipts, while keeping
everything that makes the app work offline. Capture stays local-first and unchanged.

## Non-goals

- No review surface. There is no endpoint for other users' receipts and no approve/reject action.
  An admin triaging a team's receipts on a phone is a separate feature and a separate decision.
- No status-filter UI. The endpoint supports `?status=`, but nothing in the app needs it yet.
- No change to capture, upload queue, or the grant-expiry logic.

---

## Decisions

| Question | Decision |
|---|---|
| Offline history | Full history, mirrored into SwiftData. Readable with no connectivity. |
| Device's own uploads | Merge into one row, keyed on `serverReceiptId`. |
| Swipe-to-remove on rejected | Keep it; persist a local `dismissedAt` so it survives refetch. |
| Images for remote receipts | Fetch on demand, cache to disk, generate a thumbnail on first open. |
| Paging | Infinite scroll, 25 per page. |
| Retention | Keep image cleanup; drop record deletion; no size cap. |
| Trip references | Resolve from the local cache; omit the label on a miss. Never show a raw UUID. |
| `source` visibility | Placeholder glyph only (envelope / tray). No text label. |
| List layout | Pinned local queue over a flat, server-ordered history. |
| Delete | Local-origin rows only. Mirrored rows offer dismiss, not delete. |
| Edit note / trip | Any non-terminal receipt, regardless of source. |

---

## Architecture

Four new units plus surgical changes to three existing ones.

`SyncService` is already 594 lines covering the upload queue, status sync, retention, and orphan
file sweeping. Paging, mirror reconciliation, and image download do not belong in it.

| Unit | Responsibility |
|---|---|
| `ReceiptAPIService` *(existing)* | Add `listReceipts(...)`, `getReceipt(id:accountId:)`, and their DTOs |
| `ServerDateFormatter` *(new — `Utilities/`)* | Parse the server's non-ISO timestamp format. One place, unit-tested. |
| `ReceiptMirror` *(new — `Services/`)* | Reconciliation only: DTOs + `ModelContext` → upsert / prune. No networking, so it is directly testable. |
| `ReceiptListService` *(new — `Services/`, `@Observable`)* | Paging state machine **and detail fetch**. Calls the API, hands results to `ReceiptMirror`. Owns `refresh()`, `loadNextPage()`, `fetchDetail(id:accountId:)`. |
| `ReceiptImageDownloader` *(new — `Services/`)* | Bytes only: `download-url` → GET → write to `receipts/` → thumbnail → set flags. Never calls the list or detail endpoints. Parallels `R2UploadService`. |
| `SyncService` *(existing)* | Phase-2 record deletion removed; remote-image reclaim added. Nothing else changes. |

`AppConstants.Sync.remoteFetchLimit` (`200`) is vestigial from the removed Supabase-era sync and is
deleted. `AppConstants.ReceiptList.pageSize = 25` replaces it.

### Service wiring

`ReceiptListService` and `ReceiptImageDownloader` are constructed in `JetLedgerApp.init()` alongside
the other services, take `authService.apiClient` via `ReceiptAPIService`, and are passed down with
`.environment()`. `ReceiptListService` holds the `ModelContext`, as `SyncService` does.

---

## Data model

Two vestigial fields from the removed Supabase-era cross-device sync (commits `9fa35d7`, `bee082c`)
are revived with precise meanings rather than deleted. Both are already in the SwiftData schema.

### `LocalReceipt` additions

| Field | Type | Purpose |
|---|---|---|
| `serverCreatedAt` | `Date?` | Server `created_at`. The ordering authority for pruning. |
| `serverUpdatedAt` | `Date?` | Server `updated_at`. Detects server-side change. |
| `sourceRaw` | `String?` | `ios` / `email` / `upload`. Nil for rows never uploaded. |
| `ocrStatusRaw` | `String?` | `pending` / `completed` / `failed`. |
| `expenseId` | `UUID?` | Present once processed into an expense. |
| `imageCount` | `Int` | Server-owned. Lets a mirrored row show a page-count badge before detail is fetched. Meaningless for rows never uploaded; the badge falls back to `pages.count` whenever local pages exist. |
| `detailFetchedAt` | `Date?` | Whether `images` have been pulled for this receipt. |
| `dismissedAt` | `Date?` | Local-only hide, set by swipe-to-remove. Survives refetch. |

**`isRemote`** *(exists, currently unused)* — revived to mean **this device has no capture origin
for this row**. True for rows materialized from a server fetch, false for local captures even after
they upload. It gates Retry / Manage Pages / Delete, and tells `ReceiptMirror` which rows it is
permitted to prune.

Add `@Transient` computed accessors `source: ReceiptSource?` and `ocrStatus: OCRStatus?` over the
raw strings, matching the existing `syncStatus` / `serverStatus` pattern. New enums
`ReceiptSource` and `OCRStatus` go in `Models/Enums.swift`.

### `LocalReceiptPage` additions

| Field | Type | Purpose |
|---|---|---|
| `serverImageId` | `UUID?` | Matches server image rows to local pages across refetches. |
| `serverFilePath` | `String?` | The confirmed R2 object path, for `download-url`. |
| `imageDownloadedAt` | `Date?` | When bytes landed. Drives the remote-image reclaim clock. |

**`imageDownloaded`** *(exists, currently unused, defaults `true`)* — revived as the literal truth
**"bytes exist on disk at `localImagePath`"**. True from creation for captures; false for mirrored
pages until fetched; **set back to false by phase-1 retention cleanup**. That last part is what turns
today's permanent "Images Removed" dead end into a recoverable state.

### Why `serverFilePath` is not `r2ImagePath`

They have different lifecycles. `r2ImagePath` is a **24-hour grant that expires** — the server reaps
granted-but-unclaimed objects, which is why `r2GrantedAt` and `isGrantUsable` exist.
`serverFilePath` is a **confirmed object** that does not expire.

Overloading one field for both is how the grant-expiry bug fixed in `044d085` comes back. On a
successful create, `serverFilePath` is set from `r2ImagePath`; from then on they diverge.

### Sorting

`capturedAt` remains the list sort key and is set to `created_at` for mirrored rows.

`serverCreatedAt` is stored separately because **pruning must reason in the server's ordering**. A
receipt captured offline on Monday and uploaded on Friday has `capturedAt` = Monday and
`created_at` = Friday. The server sorts by the latter; the user thinks in terms of the former.

### Migration

All new fields are optional or have defaults, so SwiftData migrates lightweight. Existing rows get
`isRemote = false` and `imageDownloaded = true`, which is correct for them — they are local captures
with bytes on disk. No migration code needed.

---

## Timestamp parsing

The server returns SQLite `datetime('now')` output: `"2026-07-27 14:03:22"` — UTC, space-separated,
no `T`, no zone suffix. `ISO8601DateFormatter` fails on it.

```swift
nonisolated enum ServerDateFormatter {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func date(from string: String) -> Date? { formatter.date(from: string) }
}
```

`en_US_POSIX` is not optional — without it a user on a non-Gregorian calendar gets nil for every
timestamp. Used for `created_at` / `updated_at` on both new endpoints, and retroactively for
`CreateReceiptResponse.createdAt`, which is the same format and currently parsed by nobody.

---

## API layer

### DTOs

All of `note`, `trip_reference_id`, `rejection_reason`, `expense_id` are `omitempty` server-side —
**the key is absent, not empty**. Every one decodes as an optional.

```swift
struct ReceiptListResponse: Decodable {
    let receipts: [ReceiptSummaryDTO]
    let total: Int
    let limit: Int
    let offset: Int
}

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
    let createdAt: String       // parsed via ServerDateFormatter
    let updatedAt: String
    // snake_case CodingKeys
}

struct ReceiptDetailDTO: Decodable {   // same fields, plus:
    let images: [ReceiptImageDTO]
}

struct ReceiptImageDTO: Decodable {
    let id: UUID
    let filePath: String
    let fileName: String
    let mimeType: String
    let sortOrder: Int
}
```

### Methods

```swift
func listReceipts(status: String?, limit: Int, offset: Int, accountId: UUID) async throws -> ReceiptListResponse
func getReceipt(id: UUID, accountId: UUID) async throws -> ReceiptDetailDTO
```

Both send `Bearer` + `X-Account-ID` through the existing `APIClient`. **Path IDs are lowercased** —
`UUID.uuidString` is uppercase and the DB stores lowercase, the same trap already handled in
`deleteReceipt`, `updateReceipt`, and `checkStatus`.

`limit` is sent explicitly at 25 rather than relying on the default.

---

## Reconciliation (`ReceiptMirror`)

### Upsert

Keyed on `serverReceiptId`. This is what collapses a device's own upload into a single row instead
of showing it twice.

For each DTO in a response:

- **Existing row with matching `serverReceiptId`** → update server-owned fields (`status`, `source`,
  `note`, `tripReferenceId`, `ocrStatus`, `rejectionReason`, `expenseId`, `imageCount`,
  `serverCreatedAt`, `serverUpdatedAt`). Never touch `isRemote`, `dismissedAt`, `capturedAt`,
  `syncStatus`, or anything about local pages.
- **No match** → create a `LocalReceipt` with `isRemote = true`, `syncStatus = .uploaded`,
  `serverReceiptId = dto.id`, `capturedAt = serverCreatedAt`, and no pages yet.

Mirrored rows carry `syncStatus = .uploaded`, so the upload queue's
`syncStatusRaw == queued || failed` predicate excludes them naturally. No extra guard needed.

`terminalStatusAt` is stamped on a mirrored row the first time it is seen as `processed` or
`rejected`, matching how `syncReceiptStatuses` does it, so retention applies uniformly.

### Pruning

Receipts deleted on the web must disappear. Size caps are not the mechanism; the fetch is.

Given the server sorts newest-first, a contiguous fetched page proves what exists in its own date
window. For a response with `newest = receipts.first.created_at` and
`oldest = receipts.last.created_at`:

> Delete any mirrored row for this account whose `serverCreatedAt` falls within
> `[oldest, newest]` and whose `serverReceiptId` is absent from the response.

**Only rows with `isRemote == true` are ever pruned.** A receipt that received its
`serverReceiptId` two seconds ago — after the request was already in flight — would otherwise be
deleted out from under the user. Local-origin rows keep their existing removal path:
`syncReceiptStatuses` already treats "present in request, absent from a successful response" as
removed-during-review.

An empty response prunes nothing; there is no window to reason about.

### Paging drift

Offset paging duplicates or skips rows if receipts are created mid-scroll. Upsert-by-id makes
duplicates harmless, and a skipped row reappears on the next refresh. Cursor pagination is not worth
building for this.

---

## Paging (`ReceiptListService`)

Observable state, per selected account, reset on account switch:

```swift
var isLoadingPage: Bool
var hasMore: Bool
var total: Int
var loadError: String?
private var offset: Int
```

- **`refresh()`** — `offset = 0`, fetch page, upsert, prune within the response's range, set `total`.
  Called from the four places `MainView` already syncs: launch (`.task`), account switch
  (`.task(id:)`), foreground resume (`scenePhase == .active`), and pull-to-refresh. Rows already
  paged in beyond the first page stay in the mirror; only `offset` resets.
- **`loadNextPage()`** — guarded by `isLoadingPage`; advances `offset` by `pageSize`, upserts,
  prunes within the new range. `hasMore = offset < total`. An empty page also ends paging.
- Offline (`!networkMonitor.isConnected`) → no request; the mirror renders as-is.
- No session (offline identity) → never fetches.

Errors set `loadError` without clearing the mirror. Nothing already on screen disappears because a
request failed.

`GET /api/receipts/status?ids=...` is **unchanged and retained** as the cheap poll for receipts
uploaded in the current session. Its overlap with the list fetch is harmless.

---

## Images (`ReceiptImageDownloader`)

The list endpoint returns `image_count` but **no `file_path`** — only the detail endpoint returns
`images`. So there is no cheap thumbnail path. Prefetching a thumbnail per list row would cost
`GET /api/receipts/{id}` → `POST /download-url` → GET the full-resolution original (1–3 MB), per row.
For a 25-row page that is ~75 requests and tens of megabytes to paint 45×60 rectangles. Ruled out on
contract grounds, not taste.

### On opening a receipt

A receipt with no `serverReceiptId` has never reached the server; it renders from local files only
and none of the following runs.

1. If `detailFetchedAt == nil` or any page has `imageDownloaded == false`,
   `ReceiptListService.fetchDetail(id:accountId:)` calls `getReceipt`.
2. `ReceiptMirror` upserts image rows into `LocalReceiptPage`, matched on `serverImageId`, ordered
   by `sort_order`. Sets `serverFilePath`, `contentTypeRaw` from `mime_type`, `detailFetchedAt`.
3. `ReceiptImageDownloader` then handles each page lacking bytes: `POST /api/receipts/download-url`
   with `serverFilePath` → GET the object → write via `ImageUtils.saveReceiptImage` /
   `saveReceiptPDF` into the receipt's existing directory → set `imageDownloaded`,
   `imageDownloadedAt`.
4. Generate a thumbnail (`saveThumbnail` for JPEG, `renderPDFThumbnail` for PDF) so the list row
   fills in on subsequent views.

The presigned download URL expires, so only bytes are cached, never the URL.

`.completeFileProtectionUnlessOpen` applies to these writes as it does to every other file write in
the app.

### States

Gallery shows a progress indicator while downloading and an error state with retry on failure.

A **404 on detail** means the receipt is gone server-side, and the response differs by origin:

- `isRemote == true` → delete the mirrored row, pop back to the list, and say so. Nothing is lost;
  the row was only ever a mirror.
- `isRemote == false` → the user's own capture was deleted during web review. Apply the treatment
  `syncReceiptStatuses` already uses for this case — `serverStatus = .rejected`,
  `rejectionReason = "Removed during review on the web."`, stamp `terminalStatusAt` — and keep the
  row. The local images are still the only copy and must not be destroyed on a 404.

---

## Retention

Today: phase 1 deletes images 7 days after terminal status; phase 2 deletes the SwiftData record at
14 days.

**Phase 2's record deletion is removed.** It now destroys local-only state the server cannot
restore. Concretely: a user dismisses a rejected receipt on day 3 → phase 2 deletes the record on
day 14 → the next fetch re-mirrors it on day 15 with no `dismissedAt` → the dismissed receipt comes
back. Metadata is roughly 200 bytes a row; ten years at twenty receipts a week is about 2 MB. That
is not the growth worth writing eviction logic for, and a size cap would fight infinite scroll —
paging rows in only for a cap to evict them and force a refetch.

**Phase 1 is unchanged**, and improves: it now also sets `imageDownloaded = false` on each page, so
a cleaned-up receipt is re-downloadable instead of a permanent dead end.

**New: remote-image reclaim.** A pending email-forwarded receipt never reaches terminal status, so
its downloaded image would never be reclaimed by a terminal-status clock. Any page whose
`imageDownloadedAt` is older than the user's retention window has its file deleted and
`imageDownloaded` set false. Same user-facing setting, same mental model ("images are kept for N
days"), and it is re-downloadable.

The rule keys on `imageDownloadedAt`, **not** on the receipt's `isRemote` flag. Only bytes fetched
from the server ever carry that stamp, and gating on `isRemote` would miss a real case: a local
capture cleaned up by phase 1 and later re-downloaded for viewing is `isRemote == false` but its
bytes came from the server and must be reclaimable again. Pages holding original local captures
never have `imageDownloadedAt` set and are untouched by this rule.

Deleted-on-web receipts leave the mirror through fetch-range pruning, not retention.

---

## UI

### List (`ReceiptListView`)

The `@Query` gains `dismissedAt == nil`. The Active/Completed split and the "Show N older" collapse
are replaced by:

- **"On this device"** — pinned section, `serverReceiptId == nil`. Everything queued, uploading, or
  failed: actionable work that exists nowhere else. A row leaves this section the moment it uploads.
- **History** — flat, newest-first by `capturedAt`, infinite-scrolled. `loadNextPage()` fires when
  the last row appears, with a footer spinner.

The stalled-upload banner is unchanged.

`serverReceiptId == nil` is the section predicate rather than `syncStatus`, because a row with
`syncStatus == .uploaded` always has a server ID — one condition instead of three.

### Row (`ReceiptRowView`)

Unchanged for local captures. For a mirrored row with no downloaded image, the thumbnail placeholder
carries the source: **envelope** for `email`, **tray** for `upload`, existing document glyph for
`ios`. No text label — the list stays about receipts, not plumbing. Once opened, the generated
thumbnail replaces the glyph.

Trip label resolves `tripReferenceId` against `TripReferenceService`'s cached list. Hit → existing
`"Trip ABC-123"` treatment. Miss → omit. A raw UUID is never displayed. The cache refreshes per
account on launch, so misses are rare and self-healing.

Rejection reasons map to display labels: `duplicate` → Duplicate, `unreadable` → Unreadable,
`not_business` → Not Business, `other` → Other. The existing `rejectionReasonLabel` in
`ReceiptDetailView` already does this and moves somewhere shared.

### Detail (`ReceiptDetailView`)

- **Editable** — unchanged rule: any receipt not processed and not rejected, regardless of source.
  Tagging an email-forwarded fuel receipt to a trip from the cockpit is the case this serves.
- **Delete** — only when `isRemote == false`. The phone does not destroy server records it had no
  part in creating. Mirrored rows offer the local dismiss instead.
- **Retry Upload / Manage Pages** — hidden when `isRemote == true`. There is nothing local to retry
  or reorder.

### Deep links

`MainView.navigateToReceipt(serverReceiptId:)` currently returns silently when no local match
exists. It now falls through to `ReceiptListService.fetchDetail(id:)`, mirrors the result, and
selects it. A 404 alerts that the receipt is no longer available.

Per the server sequencing note, pushes currently fire only for `source == "ios"`, so this path is
exercised in development only by receipts this app created. The gate loosens in a follow-up server
PR after this ships.

### Other surfaces

Viewers (`canUpload == false`) now get a real history instead of an empty list — the read-only
banner stays, but the screen below it is no longer blank.

---

## Testing

Existing `SyncServiceRetryTests` must continue to pass unchanged.

**`ServerDateFormatterTests`** — parses `"2026-07-27 14:03:22"` to the correct UTC instant; returns
nil for ISO-8601 input; correct under a non-Gregorian locale.

**`ReceiptMirrorTests`** — upsert creates a row with `isRemote = true`; upsert against an existing
`serverReceiptId` updates server fields and preserves `dismissedAt` / `capturedAt` / local pages; a
row absent from a fetched range is pruned; a row outside the range is not; a row with
`isRemote == false` is never pruned; absent `omitempty` keys decode to nil; an empty response prunes
nothing.

**`ReceiptListServiceTests`** *(via `MockURLProtocol`)* — offset advances by page size; `hasMore`
derives from `total`; a second `loadNextPage()` during an in-flight load is a no-op; a failed fetch
sets `loadError` without emptying the mirror; the request path carries a lowercase ID.

**Retention tests** — phase 1 sets `imageDownloaded = false`; phase 2 no longer deletes records;
`dismissedAt` survives a cleanup pass; a remote page past its download-age window is reclaimed while
a local capture's page is not.

---

## Risks

- **Endpoints are not deployed.** All work is against a frozen contract with mocked responses. The
  first real integration run is the earliest anything is confirmed end to end.
- **Offset paging drift** is accepted rather than solved. Mitigated by upsert-by-id and refresh.
- **The mirror grows unbounded** by design. Sized above as negligible; revisit only with evidence.
- **Reviving `isRemote` / `imageDownloaded`** gives previously-inert schema fields real behavior.
  Existing rows default correctly (`false` / `true`), so no migration is needed — but the defaults
  are load-bearing and are asserted in tests.
