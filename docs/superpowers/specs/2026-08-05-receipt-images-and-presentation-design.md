# Receipt image availability and presentation fixes — design

Date: 2026-08-05
Status: approved

Five defects found while exercising the app as the App Store reviewer demo
account. Three concern whether a receipt image is visible at all; two concern
UIKit/SwiftUI presentation plumbing. They are grouped in one spec because they
were found in one pass, not because they share an implementation.

---

## 1. Detail view surrenders instead of re-downloading

### Observed

A receipt with `syncStatus == .uploaded` and a thumbnail in the list opens to
`ContentUnavailableView("Images Removed")` with the copy "Local images have
been removed to save space." The Edit affordance is then worthless: the user
cannot see what they are editing.

### Cause

`ReceiptDetailView` renders that state whenever every page has
`imageDownloaded == false` and no error was raised
(`ReceiptDetailView.swift:65`). Re-downloading runs only through
`ReceiptImageDownloader.downloadMissingImages`, which silently skips any page
with `serverFilePath == nil` (`ReceiptImageDownloader.swift:48`).

`serverFilePath` is written in exactly one place — `ReceiptMirror.upsertDetail`
— and the detail fetch that calls it runs only when `detailFetchedAt == nil`
(`ReceiptDetailView.swift:261`).

That is a dead end. A row whose detail was fetched once without acquiring file
paths for its pages will never fetch detail again, so it will never acquire
them, so it will never download. It shows "Images Removed" permanently, even on
a fast connection with the bytes sitting in R2.

### Decision

Keep retention cleanup. Reclaiming disk from terminal receipts is legitimate —
a pilot capturing offline for months accumulates real storage at 1–3MB per
receipt, and the window is user-adjustable via `imageRetentionDays`. Make the
cleanup invisible instead of removing it: if opening a receipt always
re-downloads when online, the user never learns that anything was reclaimed.

### Changes

**Widen the detail-refetch condition.** In
`ReceiptDetailView.loadRemoteContentIfNeeded`:

```
needsPages = receipt.detailFetchedAt == nil
          || receipt.pages.contains { !$0.imageDownloaded && $0.serverFilePath == nil }
```

A receipt that needs bytes but does not know where they live re-fetches its
detail to find out. This is the change that makes the dead end unreachable; the
cost is one extra `GET /api/receipts/{id}` for a receipt in that state.

**Reframe the empty state by connectivity, not by deletion.** The
`pages.isEmpty || allSatisfy { !$0.imageDownloaded }` branch splits:

- Online, and the receipt has a `serverReceiptId`: reaching this branch means a
  download should have happened and did not. Render the existing "Couldn't Load
  Images" state with its Try Again button.
- Offline: render `Label("Image Not Downloaded", systemImage: "wifi.slash")`
  with the description "Connect to the internet to view this receipt."
- No `serverReceiptId` (never uploaded, nothing to download from): keep a
  terminal message, since there is genuinely nothing to fetch.

The phrase "removed to save space" is deleted. It described an implementation
detail the user has no way to act on, and it read as data loss.

**Retry when connectivity returns.** Add
`.onChange(of: networkMonitor.isConnected)` to `ReceiptDetailView` that calls
`loadRemoteContentIfNeeded()` when the value flips to true and the receipt
still has undownloaded pages. A receipt opened offline fills in when signal
returns rather than requiring the user to back out and re-enter.

`ReceiptDetailView` gains an `@Environment(NetworkMonitor.self)` dependency.

### Not changed

`SyncService.performCleanup`, `reclaimTerminalReceiptImages` and
`reclaimDownloadedImages` keep their current behavior. `imagesCleanedUp` keeps
driving the list row's placeholder glyph.

---

## 2. List thumbnails fall back to placeholder glyphs

### Observed

Every row with `serverStatus == .rejected` shows a placeholder. One row with
`syncStatus == .uploaded` also showed a placeholder; after opening its detail
and navigating back, its thumbnail appeared. That row was a PDF and carried the
"PDF" badge.

### Cause A — the thumbnail map is wiped on every refresh

`ReceiptListService.recordThumbnailURLs(from:replacingAll:)` clears
`thumbnailURLs` whenever `requestedOffset == 0` (`ReceiptListService.swift:126`).
A refresh — foreground, pull-to-refresh, account switch — is always offset 0, so
it discards the presigned URL of every row the user had paged in beyond the
first 25. Those rows drop to their glyph and stay there until re-fetched.

Rejected receipts are the oldest ones in the account, so they are exactly the
rows that live past page 1. This is the leading explanation for the rejected-row
placeholders.

### Cause B — PDFs have no server thumbnail until something renders one

`thumbnailKey` in the web repo (`api/receipts.go:664`) withholds `thumbnail_url`
for a PDF whose `thumbnail_ready` flag is 0. That flag is set in only two
places:

- `services/ocr_pipeline.go:219`, at OCR ingest
- `handlers/staged_receipts.go:753`, when someone views the receipt card **on
  the web**, which heals the flag on demand

An iOS-uploaded PDF that has not been through OCR and has never been opened on
the web therefore has no `thumbnail_url` indefinitely. The iOS row falls to a
glyph. Opening the detail downloads the PDF and `ImageUtils.savePDFThumbnail`
renders a local thumbnail, which is why the row filled in afterwards.

This is a server-side gap. It is recorded here and noted for the web repo; it is
not fixed from the iOS side, which has no way to render a thumbnail for a remote
PDF without downloading the whole file into a list cell.

### Cause C — presigned thumbnails expire and `AsyncImage` never retries

`receiptURLTTLSecs` gives these URLs a short life (15 minutes). `AsyncImage`
issues one request and renders `placeholder` on failure with no retry. An app
left open past the TTL shows glyphs for every server-backed row, and the stored
URL is then a request guaranteed to fail.

### Changes

**Merge rather than replace, and track age.** `thumbnailURLs` becomes
`[UUID: ThumbnailGrant]`, where `ThumbnailGrant` is a small struct holding `url`
and `fetchedAt`. The stored map goes `private`; `ReceiptThumbnail` reads it
through a new `thumbnailURL(for serverReceiptId: UUID) -> URL?` method so the
age check cannot be bypassed by a caller. `recordThumbnailURLs` always merges;
the `replacingAll` parameter is removed. The accessor returns `nil` for any
entry older than
`AppConstants.ReceiptList.thumbnailURLUsableFor` — 14 minutes, a margin under
the server's TTL, following the same pattern as `Sync.uploadGrantUsableFor`.

An aged-out entry yields the glyph, which is what happens today, minus the
doomed network request. Unbounded growth was the stated reason for wiping the
map; a `UUID`-to-URL entry per receipt the user has paged through in one session
is a few hundred entries at most, which does not justify discarding live data.

**Make the PDF placeholder intentional.**
`ReceiptRowFormatting.placeholderIcon` gains awareness of PDF content so a PDF
row with no thumbnail shows `doc.richtext` rather than the generic
missing-image glyph. Combined with the existing "PDF" badge the cell reads as
"this is a PDF", not "this is broken". The signal is the row's
`firstImageMimeType` (mirrored rows) or a page's `contentType` (local rows).

---

## 3. Files importer jumps from Recents to On My iPhone

### Observed

Tapping "Import from Files" opens the picker on its browse/Recents screen, then
after roughly three seconds navigates on its own to "On My iPhone".

### Cause

`UIDocumentPickerViewController` restores its last-used location
asynchronously. It presents on the default screen, queries the file providers,
then navigates to the saved location once that resolves. `.fileImporter` at
`MainView.swift:122` passes no start directory, so the restore is visible as a
jump.

This is distinct from §4. A three-second delay followed by a smooth navigation
is restoration, not a presentation race. The §4 fix may or may not affect it;
this change is independently correct.

### Changes

Persist the parent directory of the file the user last picked and pass it back
via `.fileDialogDefaultDirectory(_:)` (iOS 17.0+, within the 17.6 deployment
target).

- Store `urls.first?.deletingLastPathComponent()` as a string in
  `@AppStorage("lastImportDirectory")` in the `.fileImporter` completion.
- Read it back into a `URL?` and apply `.fileDialogDefaultDirectory`.

A fixed pin is deliberately rejected: pinning to "On My iPhone" is wrong for a
user whose receipts live in iCloud Drive, and the app's own sandbox Documents
directory contains only `receipts/` internals. First launch behaves as today
(one jump, once); every launch after is instant and lands where the user
actually keeps files. If a stored URL no longer resolves, the picker falls back
to its current behavior — the same outcome as today, so the failure mode costs
nothing.

---

## 4. Settings gear sometimes needs multiple taps

### Observed

Tapping the toolbar gear intermittently does nothing; a second, occasionally
third, tap opens Settings. Not reliably reproducible.

### Cause

`MainView.withPresentations` stacks four presentation modifiers on the same
`NavigationSplitView`: `.fullScreenCover(showCapture)`, `.sheet(showImport)`,
`.sheet(showSettings)`, and `.fileImporter(showFilePicker)` — itself a sheet
presentation. SwiftUI reliably services one presentation per view.

The concrete trigger is `MainView.swift:128-130`, which sets `showImport = true`
**synchronously inside the `.fileImporter` completion closure**. That requests a
new sheet while the document picker is still dismissing. The request is
swallowed, and the presentation machinery is left in a state that then eats the
next request — which is the gear tap. The intermittency matches: it only
misbehaves after an import round-trip.

### Changes

**One sheet modifier, driven by an enum.**

```swift
private enum ActiveSheet: Identifiable {
    case importFlow
    case settings
    var id: Int { ... }
}
@State private var activeSheet: ActiveSheet?
```

`.sheet(item: $activeSheet)` replaces both `.sheet(isPresented:)` modifiers.
`showImport` and `showSettings` are removed. `.fullScreenCover` for capture
stays as its own modifier — it is a different presentation kind and does not
contend with the sheet slot.

**Hand off after dismissal, not during it.** The `.fileImporter` completion
stores the URLs and sets `activeSheet = .importFlow` on the next runloop turn
rather than inline, so the picker's dismissal completes first.

**Preserve the existing `onChange` semantics.** `onChange(of: showImport)` and
`onChange(of: showCapture)` currently kick `syncService.processQueue()` and
`cameraSessionManager.scheduleStop(after: 30)` on dismissal. These move to
`onChange(of: activeSheet)` and the existing capture observer, with identical
behavior: queue processing when the import sheet closes, camera stop scheduling
when the capture cover closes.

**Type-checker budget.** `MainView.body` is already split into stages with a
comment explaining that the single chain exceeded the Swift type checker's
budget. Removing one `.sheet` and one `@State` reduces pressure; the staged
structure stays.

---

## 5. Green camera indicator stays lit for the whole session

### Observed

The iOS camera privacy indicator remains lit the entire time the app is open,
not only during capture.

### Cause

`CameraSessionManager.observeSessionNotifications` registers an
`AVCaptureSession.interruptionEndedNotification` handler that calls
`startRunning()` unconditionally (`CameraSessionManager.swift:45-52`), with no
check that any camera UI is on screen.

Backgrounding the app interrupts the session
(`videoDeviceNotAvailableInBackground`). Foregrounding fires interruption-ended,
which restarts the capture session behind the receipt list. Nothing schedules a
stop, because `scheduleStop(after: 30)` is only reached through
`MainView.onChange(of: showCapture)`. Open the scanner once, background the app,
return, and the camera runs until the process dies.

A sibling bug shares the cause: the `wasInterruptedNotification` handler sets
`state = .failed("Camera is in use by another app")` unconditionally, so an
interruption while no camera UI exists poisons the state the next capture flow
reads.

### Changes

Add ownership tracking to `CameraSessionManager`:

```swift
@ObservationIgnored private var isSessionWanted = false
```

- `startRunning()` sets it true.
- `stopRunning()` sets it false.
- `scheduleStop(after:)` leaves it set until the work item fires and calls
  `stopRunning()`, so a re-entry inside the 30s window still reads as wanted.
- The `interruptionEnded` handler resumes only when `isSessionWanted` is true.
- The `wasInterrupted` handler sets `.failed` only when `isSessionWanted` is
  true.

The runtime-error handler already guards on `isConfigured` and attempts one
restart; it gains the same `isSessionWanted` guard so a media-services reset
does not resurrect an unwanted session.

The flag is main-actor state like the rest of the class's observable surface;
the session-queue work inside `startRunning`/`stopRunning` is unchanged.

---

## Testing

Existing suites that must continue to pass: `ReceiptImageDownloaderTests`,
`ReceiptListServiceTests`, `ReceiptMirrorTests`, `ReceiptRetentionTests`,
`ReceiptRowFormattingTests`.

New coverage:

- **§1** — a receipt whose pages lack both bytes and `serverFilePath` triggers a
  detail re-fetch; a receipt with bytes triggers neither fetch nor download.
- **§2** — `recordThumbnailURLs` merging: a page-0 refresh preserves entries
  recorded for a later page. Age-out: an entry older than the usable window
  reads as absent. `placeholderIcon` returns the PDF glyph for a PDF row with no
  thumbnail.
- **§5** — `interruptionEnded` does not start a session that was never wanted;
  it does resume one that was.

§3 and §4 are presentation behavior and are verified by hand on device: gear
opens first tap after an import round-trip; the picker opens directly to the
last-used directory on the second and subsequent invocations.

Build and test per `CLAUDE.md` — tests need an iOS 26.x runtime, and the log
must be checked for `** TEST SUCCEEDED **` rather than trusting the exit status.

---

## Sequencing

§1, §2 and §5 are independent and can land in any order. §4 should land before
§3 is verified by hand, so that if the presentation race was contributing to the
picker behavior, the remaining jump is attributable to restoration alone.

## Out of scope

- Server-side PDF `thumbnail_ready` generation for iOS uploads (web repo).
- Any change to retention cleanup policy or the `imageRetentionDays` default.
- Replacing `AsyncImage` with a custom cached loader. Age-aware URLs remove the
  doomed requests; a bespoke loader is a larger change than the symptom
  justifies.
