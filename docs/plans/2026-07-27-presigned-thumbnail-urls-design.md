# Presigned Thumbnail URLs — Design

**Date:** 2026-07-27
**Status:** Approved, implementing
**Amends:** `2026-07-27-server-driven-receipt-list-design.md`
**Depends on:** Go API PR #45 (presigned URLs on list rows and detail images) and
PR #46 (`thumbnail_url` is always a directly displayable image). Neither deployed
at time of writing.

---

## Why

The original design ruled out row thumbnails for mirrored receipts on contract
grounds: `GET /api/receipts` returned `image_count` but no `file_path`, so
painting a 45×60 cell would have cost a detail fetch, a `download-url`, and a
full-resolution GET **per row**. Rows for receipts this device never captured
therefore showed a source glyph.

PR #45 adds a presigned, self-authenticating `thumbnail_url` to each list row,
which removes that constraint entirely. PR #46 guarantees the URL, when present,
always points at something directly displayable.

## Correction to the incoming brief

The brief asks to "delete the per-row `GET /api/receipts/{id}` fetch" as the
cause of `Receipt detail fetch failed: cancelled` and blank cells. **No such
per-row fetch exists in this client.** `fetchDetail` has exactly two call sites:
`ReceiptDetailView` (once, on open) and `MainView.navigateToReceipt` (deep-link
fallback). `ReceiptRowView` performs no networking.

- The **detail fetch stays.** The list carries only `first_image_*`, so opening a
  receipt still needs the full image list. PR #45 removes the per-*image*
  `download-url` call, not the detail fetch.
- **`Receipt detail fetch failed: cancelled`** is this app's own log line.
  `ReceiptDetailView` uses `.task(id:)` and `MainView` applies
  `.id(selectedReceipt.id)`, so changing the iPad selection tears the view down
  and cancels the in-flight fetch. It is cancellation, not failure, and is fixed
  here by giving it its own result case.
- **Blank cells** were intended behavior for mirrored rows, and are what
  `thumbnail_url` now fills in.

---

## Decisions

| Question | Decision |
|---|---|
| PDF rows | No special-casing. PR #46 makes `thumbnail_url` always displayable; absent → glyph. |
| Missing `thumbnail_url` | Show the glyph. **Not** an edge case — migration 23 defaults older rows to "not ready", so many PDF receipts start without one and heal as their web card is viewed. |
| Per-row `download-url` fallback | Not built. It would reintroduce the per-row request chain these fields exist to remove. |
| URL expiry | Not tracked. No timer. Existing refresh points re-presign; a failed load falls back to the glyph. |
| Persisting URLs | Never. Only the non-expiring `first_image_path` / `first_image_mime_type` reach SwiftData. |

---

## Changes

### DTOs

`ReceiptSummaryDTO` gains `thumbnailUrl`, `firstImagePath`, `firstImageMimeType` —
all optional, since all three are `omitempty` and absence is a normal state.
`ReceiptImageDTO` gains an optional presigned `url`.

The detail response repeats the three summary fields. This costs no new code:
`ReceiptDetailDTO` already decodes `ReceiptSummaryDTO` out of the same flat
container, so one struct decodes both shapes.

### Persistence

`LocalReceipt` gains `firstImagePath: String?` and `firstImageMimeType: String?` —
an R2 key and a mime type, both stable and safe to store.

`thumbnail_url` is **never** persisted. It lives in `ReceiptListService` as an
in-memory `[UUID: URL]` keyed by `serverReceiptId`, replaced on each list fetch.
Nothing on disk can go stale.

### Row rendering

Precedence in `ReceiptRowView`:

1. Local thumbnail on disk (unchanged — captures and downloaded images)
2. Presigned `thumbnail_url` via `AsyncImage`
3. Source glyph

No mime branch and no downloads: PR #46 guarantees a present URL is displayable.
`AsyncImage`'s failure phase falls back to the glyph, so an expired URL degrades
instead of showing a broken cell.

`first_image_mime_type` still drives the PDF badge for rows with no local pages —
it describes the actual receipt file, which is a separate question from what the
thumbnail shows.

### Detail

`ReceiptImageDownloader` uses `images[].url` when present and skips
`download-url`. That URL is the **original**, so the existing page-1 PDF
rendering is unchanged. `download-url` remains the fallback when `url` is absent,
using the `serverFilePath` already stored — which also self-heals a 403 without
refetching the list.

### Cancellation

`ReceiptListService.DetailFetchResult` gains `.cancelled`, matched before the
generic error handler. An abandoned iPad selection stops logging a warning and
stops surfacing an error state to the user.

---

## Out of scope

`image/png` is new to the app and `PageContentType` has only `jpeg` / `pdf`. A
detail image with that mime stores its bytes under a `.jpg` name and decodes
correctly (`UIImage` sniffs content rather than trusting the extension). Adding a
real `.png` case would touch the upload path's content-type handling, which is
unrelated to this change.

## Testing

- Summary and detail decode with all three new fields present, and with all three
  absent.
- `images[].url` is preferred over `download-url`; `download-url` is still used
  when `url` is absent.
- Row render precedence: local thumbnail wins over presigned URL, presigned URL
  wins over glyph, glyph when neither.
- A cancelled detail fetch returns `.cancelled` rather than `.failed`.
