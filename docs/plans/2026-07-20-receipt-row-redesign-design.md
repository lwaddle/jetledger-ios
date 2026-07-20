# Receipt Row Redesign — Date-led Rows

**Date:** 2026-07-20
**Status:** Approved

## Problem

Receipt list rows use the optional `note` as the row title. Notes are rarely
entered, so most rows render the placeholder "No note" — the list reads as
broken/unfinished. Receipts in v1 have no merchant or amount, so a receipt's
real identity is *when it was captured*, *what it looks like*, and *which trip
it belongs to*. The row design should promote data that always exists.

## Design

### Row structure (`ReceiptRowView`)

Top to bottom; lines 2–3 render only when the data exists:

1. **Title — smart capture date**, `.headline`. Formats:
   - Same day: "Today, 2:34 PM"
   - Previous day: "Yesterday, 9:05 AM"
   - Current year: "Jul 12, 2:34 PM"
   - Prior years: "Dec 3, 2025" (no time)
   Always present → no row ever shows placeholder text.
2. **Note** (optional), `.subheadline` secondary, 1 line.
3. **Trip reference** (optional), caption monospace secondary. Shown
   independently of the note — previously a note hid the trip line.
4. **Status line** — `SyncStatusBadge` with a quiet mode: `processed`
   collapses to a lone green checkmark icon (no text; row already sits in the
   "Completed" section). All other states keep icon + text; `failed` and
   `rejected` stay loud (red).

### Thumbnail

- 45×60 portrait (matches stored 96×128 thumbnails — display-side change
  only), corner radius 8, existing hairline border.
- Trailing "2 pages" / "PDF" capsules move onto the thumbnail as a small
  bottom-corner badge on `.thinMaterial`: page count when multi-page, "PDF"
  tag for PDFs.
- Row trailing edge becomes clean (no accessories).
- Cleaned-up-images placeholder keeps its icon at the new portrait size.

### Unchanged

List sections (Active / Completed + "Show N older"), swipe actions,
pull-to-refresh, empty state, `ReceiptDetailView` (a "No note" value inside a
labeled detail field reads fine).

## Files touched

- `JetLedger/Views/Main/ReceiptRowView.swift` — row layout, date helper,
  thumbnail badges
- `JetLedger/Components/SyncStatusBadge.swift` — compact/processed variant

## Testing

Build via `xcodebuild`; visual verification in simulator across states:
no-note row, note+trip row, multi-page, PDF, each sync/server status,
light/dark mode.
