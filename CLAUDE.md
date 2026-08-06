# JetLedger iOS

Receipt capture companion app for the JetLedger web app. Pilots and crew capture receipt images (including offline/airborne), add optional metadata (note, trip reference), and upload for review on the web. **No expense management** — that's web-only.

Full v1 specification: `docs/v1-specification.md`

---

## Build

- **Xcode 26.2 / Swift 6.2** — `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`
- **Deployment target:** iOS 17.6 (target-level override of project-level 26.2)
- **Universal:** iPhone + iPad
- **Zero third-party dependencies** — all networking via native `URLSession` through shared `APIClient`
- **PBXFileSystemSynchronizedRootGroup** — Xcode auto-syncs new/deleted files, no pbxproj edits needed

```sh
# Build — app target deploys to iOS 17.6
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build

# Test — needs an iOS 26.x runtime: the *test* targets inherit the project's
# 26.2 deployment target, so the 18.4 sim above fails before running anything.
# xcodebuild test exits 0 on that failure — check for "** TEST SUCCEEDED **".
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test
```

API base URL configured via `JETLEDGER_API_URL` in `Secrets.xcconfig` (not checked in).
CI copies `Secrets.xcconfig.example` into place, since a fresh clone has no
`Secrets.xcconfig` and `$(JETLEDGER_API_URL)` would otherwise expand empty —
`AppConstants.WebAPI.baseURL` `fatalError`s on that.

**CI** (`.github/workflows/ci.yml`) builds and tests every PR and every push to
`main`. It exists because a branch that did not compile reached a merge request
looking green (PR #1) — the PR status field reports only whether git can merge,
and nothing else verified iOS builds.

Two things the workflow does deliberately, both worth preserving:
- **It asserts `** TEST SUCCEEDED **` in the log rather than trusting the exit
  status.** `xcodebuild test` can exit 0 on failures that occur before any test
  runs. Checking the exit code alone is exactly how a broken branch passes.
- **It resolves the simulator at runtime** (first available iOS 26.x iPhone).
  The UUID above is machine-local and device names vary by runner image, so
  hardcoding either breaks on CI immediately.

---

## Architecture

### Backend
- **Go API** (shared with web app) — auth, receipts CRUD, trip references
- **Cloudflare R2** — receipt image storage via presigned URLs
- **Shared database** — `staged_receipts` + `staged_receipt_images` tables read by both iOS and web

### Key Patterns
- **Offline-first:** All captures saved locally (SwiftData + Documents dir). Uploads queued for connectivity.
- **`@Observable` services** (not `ObservableObject`) — `AuthService`, `AccountService`, `SyncService`, `TripReferenceService`, `BiometricAuthService`, `NetworkMonitor`, `PushNotificationService`
- **`AuthService`** held as `@State` on `JetLedgerApp`, passed via `.environment()`. Owns `APIClient`. Drives root view routing via `switch authService.authState`.
- **`APIClient`** shared with all services via `authService.apiClient`. Injects `Bearer` token + `X-Account-ID` header. On 401: attempts biometric re-auth, then falls back to login.
- **SwiftData** for local persistence. `ModelContainer` created in `JetLedgerApp.init()` with explicit `Schema`.
- **JSON DTOs** use explicit `CodingKeys` for snake_case mapping.

### SwiftData Gotchas
- `#Predicate` cannot use `.rawValue` on enums or `.uuidString` on UUIDs — both crash at runtime
- Workaround: store as raw `String` (`syncStatusRaw`, `serverStatusRaw`, `contentTypeRaw`), add `@Transient` computed property for the typed enum
- For UUID filtering: fetch all, filter in-memory with `where`
- `@Attribute(.unique)` instead of `#Unique` macro (requires iOS 18+)

### Concurrency
- All types implicitly `@MainActor` (build setting) — no need to annotate explicitly
- `nonisolated` functions can't use MainActor-isolated constants as default params — use literals
- `Task.detached` must capture `self` explicitly; hop back via `await MainActor.run { ... }`
- AVFoundation delegates are `nonisolated` — dispatch to main via `DispatchQueue.main.async`
- `ImageProcessor` is `Sendable` (nonisolated let + nonisolated methods)

---

## Auth Flow

1. Email + password → `POST /api/auth/login`. Response includes `mfa_methods: { totp, webauthn }` when 2FA is required.
2. Second factor, in priority order:
   - **Passkey** (`mfa_methods.webauthn`): `POST /api/auth/webauthn/begin` → `ASAuthorizationController` platform passkey prompt → `POST /api/auth/webauthn/finish`. Runs in `PasskeyAuthService`; registration is web-only.
   - **TOTP** (`mfa_methods.totp`): `POST /api/auth/verify-totp`, supports recovery codes.
   - If both are enrolled, the passkey prompt fires automatically; a "Use authenticator app instead" affordance reveals the TOTP UI.
3. Accounts returned in the login response, presented on the main screen.
4. Every session-creating response (login without MFA, verify-totp, webauthn/finish,
   passkey/finish, device-login) and `GET /api/accounts` carries a top-level `terms`
   object — see Terms Re-acceptance below. Absent from the intermediate
   `mfa_required` response (no session yet).

**Biometric re-auth (Face ID / Touch ID):**
- `POST /api/auth/trust-device` → long-lived device token in biometric-protected Keychain
- On session expiry: Face ID unlocks token → `POST /api/auth/device-login` → new session
- Device token stored in **two** Keychain entries: biometric-protected (for re-auth) + non-biometric (for revocation)
- `KeychainHelper.biometricItemExists()` checks without triggering Face ID prompt

**Permissions:** Only admin/editor roles can upload. Viewers see disabled capture with explanatory text.

---

## Camera & Image Processing

- `CameraSessionManager` pre-warms `AVCaptureSession` on `MainView` appear; reused across capture flows
- Camera device: `.builtInDualWideCamera` virtual device (falls back to wide) — enables automatic ultra-wide macro switch for close-up receipts; zoom set to switch-over factor (1x wide framing), `autoFocusRangeRestriction = .near`
- `CameraViewController` (UIKit) → live edge detection via `VNDetectDocumentSegmentationRequest` (ML document model, not `VNDetectRectanglesRequest`) → `CAShapeLayer` overlay. Last live rect snapshotted at shutter press as fallback corners when still-image detection fails
- `ImageProcessor` — `CIContext` reuse, perspective correction, enhancement: Original or Auto (`CIDocumentEnhancer` — shadow removal/background whitening, keeps color). `EnhancementMode.blackAndWhite` is a legacy case kept only so old SwiftData records decode; hidden from UI (`allCases` is custom), enhances as Auto via `.normalized`
- Low-light: `.quality` photo prioritization, +0.5 EV bias, `CINoiseReduction`
- Flash: `FlashMode` enum (auto/on/off), default `.auto`
- Hardware shutter: `AVCaptureEventInteraction` (AVKit) on the camera view — volume buttons, Action button, Camera Control all capture; only routes presses while the capture UI is visible
- Image output: JPEG quality ~0.8, max 4096px long edge, target 1-3MB/page
- Paths in SwiftData are **relative** to Documents directory
- Capture flow: camera → preview (Add Page / Done; Original/Auto toggle + corner adjustment behind an "Adjust" disclosure — no manual exposure control, removed 2026-07 as a data-destroying knob the enhancer obsoleted) → metadata. No separate multi-page prompt screen; metadata has an "Add Page" thumbnail tile, and metadata drafts (note/trip ref) persist on the coordinator across the camera round-trip
- `CameraSessionManager.isSessionWanted` means "capture UI is on screen," not "the
  session is running" — every interruption handler gates on it. `scheduleStop(after:)`
  clears it immediately, at **schedule** time, not when the deferred work item fires
  30s later; the session itself keeps coasting through that grace window so a quick
  re-open stays warm, and re-entering the flow calls `startRunning()`, which sets the
  flag back to `true` and cancels the pending stop. The clear cannot be deferred to
  fire time: an interruption landing inside the window (e.g. backgrounding) would
  still read as "wanted," `handleInterruptionEnded` would call `startRunning()` on
  return, that cancels the pending stop, and nothing re-arms it — `MainView` only
  reschedules on a *transition* of `showCapture` — leaving the camera running behind
  the receipt list with the indicator lit for the life of the process. Fixed
  2026-08-05.

---

## Sync & Upload

- `SyncService` manages upload queue (FIFO), status sync, retry with exponential backoff, cleanup
- Upload: get presigned URL → PUT to R2 → create `staged_receipts` record via API
- **An upload URL is a 24h lease, not a reservation.** The server reaps any granted-but-unclaimed
  object 24h after issuing the URL, so a stored `file_path` expires. `LocalReceiptPage.r2GrantedAt`
  records the grant time; `SyncService.isGrantUsable` re-uploads anything older than
  `AppConstants.Sync.uploadGrantUsableFor` (20h, a margin under the reap) instead of claiming a path
  the server has deleted. `r2GrantedAt == nil` (rows predating this) counts as expired — re-uploading
  costs one request, claiming a reaped path strands the receipt forever. Added 2026-07-26 after a
  storage audit found orphaned uploads.
- Create-time failures are classified by response body, not just status: `POST /api/receipts` returns
  **400** (not 413) for both "uploaded image not found" and "... exceeds max size". Both mean the
  stored path names nothing, so both clear the receipt's grants; only the oversize case parks
  permanently. `POST /api/receipts/upload-url` can return 500 "failed to prepare upload" — retryable,
  and the PUT must not run because no URL was issued.
- `LocalReceipt.firstFailedAt` stamps the first failure (cleared on success) so `isStalled` can
  escalate a receipt failing >24h into a list banner. A red "Failed" badge alone reads identically on
  day one and day eleven, which is how the audited orphans went unnoticed.
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
  `ServerDateFormatter`, never `ISO8601DateFormatter`. `expense_id` / `trip_reference_id` arrive as
  `""` as well as absent, so they decode leniently — strict `UUID?` decoding fails the whole page.
- Status sync on foreground + pull-to-refresh (bulk `GET /api/receipts/status`)
- Auto-cleanup reclaims **disk, not records**: local images are deleted after the retention period
  (`@AppStorage("imageRetentionDays")`) and the pages marked `imageDownloaded = false` so the
  detail view re-downloads them. Downloaded images have their own clock keyed on
  `imageDownloadedAt` — a pending email receipt never reaches terminal status, so nothing else
  would ever reclaim them. SwiftData records are no longer deleted: the row is a mirror of one the
  server owns, and deleting it destroyed the local-only `dismissedAt`, resurrecting receipts the
  user had dismissed.
- Rejected receipts can be swiped away in the list — **local hide only**
  (`dismissRejectedReceipt` sets `dismissedAt`), no API call: permanently deleting a rejected
  receipt is an admin decision made on the web. The flag is persisted rather than the row deleted,
  because the list is now a server mirror and a deleted row returns on the next page fetch.
  Decided 2026-07-18, reworked 2026-07-27.
- A `terms_acceptance_required` 403 on any queue work **parks, never fails**: the
  receipt reverts to `.queued` (mirroring the 401 path), the pass stops, `firstFailedAt`
  is not stamped and grants are untouched. See Terms Re-acceptance.
- `R2UploadService` uses custom `URLSession` with 30s timeout
- Dynamic content type per page (`image/jpeg` or `application/pdf`)
- **Trip reference creation is online-only.** `TripReferenceService.createTripReference` throws typed errors: `TripReferenceError.offline` (no connectivity) and `TripReferenceError.conflictWithExisting(TripReferenceSummary)` (server 409 — surfaced as a "Use this one" affordance in the picker). Pickers work offline against the cached list; receipts can be captured without a trip link and tagged later via the detail edit sheet or on the web during review.
- **A receipt's image is fetched whenever the device is online.** Retention still
  reclaims disk (`imageRetentionDays`, default 7), but the detail view treats an
  image-less receipt as a fetch to perform, not a fact to report.
  `ReceiptDetailContent.needsDetailFetch` refetches detail when a page lacks both
  bytes and a `serverFilePath` — keying only on `detailFetchedAt == nil` left a
  dead end where a row could never learn where its bytes lived, and showed
  "Images Removed" permanently with the object sitting in R2. The empty state
  now reads connectivity: offline says so, online offers a retry. Fixed
  2026-08-05.
- **Row thumbnail grants merge and expire on their own clock.**
  `recordThumbnailURLs` merges each fetched thumbnail into `thumbnailGrants`
  rather than replacing the map — replacing on every offset-0 fetch (a refresh
  is always offset 0) discarded the thumbnail of every row paged in below the
  first page, on every foreground. `ReceiptListService.thumbnailURL(for:)` then
  ages each grant out independently at `AppConstants.ReceiptList
  .thumbnailURLUsableFor` (14m, under the server's 15m signature), so a row the
  user hasn't paged back to loses its thumbnail on schedule instead of the map
  being kept forever.
- **A view's `.task(id:)` is not a safe owner for a fetch that must complete.**
  SwiftUI fires `onDisappear` on `ReceiptDetailView` during the
  `NavigationSplitView` push — while the view is still on screen — cancelling
  `.task(id:)` and its in-flight `URLSession` request, and it never re-runs.
  Every receipt opened after the first in a session died that way, stranding the
  detail view on a load that had been killed. The load therefore runs in an
  unstructured `Task`, which the transition cannot cancel; that in turn makes a
  second request for an already-loading receipt reachable, so
  `ReceiptImageDownloader` dedupes on `inFlightDownloads` (it had been recording
  `inFlightReceiptIds` without ever consulting them). `ReceiptDetailContent
  .emptyState` also gained `.pending`: "online, server has a copy, no bytes on
  disk" is equally true before an attempt finishes, so reporting it as a failure
  announced a verdict the app never observed. Found on device 2026-08-06.
- **The server withholds `thumbnail_url` for a PDF until its page-1 JPEG exists**,
  and that render only happens at OCR ingest or when the card is opened on the
  web. An iOS-uploaded PDF with neither has no thumbnail indefinitely; the row
  shows `doc.richtext` rather than pretending an image failed. It replaces only
  the generic glyph — an email or web-upload PDF keeps its source glyph, which
  is the sole cue for where a receipt the pilot doesn't remember came from. The
  real fix is server-side (web repo).

---

## Design

- Professional, minimal — **Meridian** brand theme, shared with the web app (web repo `docs/design.md` § Theming is the palette source of truth)
- Colorsets in `Assets.xcassets` carry light/dark variants: `AccentColor` (navy `#1E3A5F` light / readable tint blue `#8FB4E3` dark), `BrandPrimary` (`#1E3A5F`/`#3D608F` — fills for prominent buttons + avatar, white content, like web `btn-primary`), `StatusInfo`/`StatusSuccess`/`StatusWarning`(+`Content`)/`StatusError`, `LaunchBackground` (base-100)
- Two-token rule: global tint (links, text buttons, toggles) uses `AccentColor`; filled surfaces under white text use `BrandPrimary` — the dark accent is too bright for white-on-blue
- Champagne accent (`#A98B4F`/`#C9A96A`) is web-side garnish only; not used on iOS yet
- Surfaces stay iOS system colors (deliberate: native feel over exact web match); dark mode via system appearance
- SF Pro (system font), Dynamic Type, monospace for trip reference IDs
- Haptics: light on shutter, success on save, subtle on edge detection lock
- iPad: `NavigationSplitView` with sidebar/detail, scan button in toolbar
- File protection: `.completeFileProtectionUnlessOpen` on all file writes
- VoiceOver accessibility labels on camera controls

---

## App Store Review

**v1.0.0 build 11 was rejected under Guideline 3.2 (Business).** The app was
originally aimed at Unlisted distribution and the only way onto the platform was an
admin-reviewed "Request Access" form, so a reviewer could not use the app "without
invitation, pre-approved registration, or affiliation with a specific organization."

**The remediation was to open the platform to the general public, not to pursue
Unlisted distribution** — hence self-service signup on the web (jetledger repo, roadmap
item 18, shipped 2026-07-29), free-tier metering to make public signup safe (item 19),
and the public-launch legal pages (item 20). The target is a normal searchable App Store
listing. Anything in this repo still implying Unlisted is stale.

Build 12 is the response: it answers 3.2 *in the binary* rather than in prose, by putting
"Create an account" on the sign-in screen. Build 11 had no in-app path to an account at
all, only untappable text naming jetledger.io — replying to the rejection with that
binary unchanged would have asked the reviewer to accept an out-of-app remedy for an
in-app complaint. It also would have shipped a 5.1.1(i) violation (see Legal Links).
A new build goes to the same app record: same version, same review thread, no reset.

**App Review Information gotchas:**
- Supply a demo account even though signup is public — it removes review friction.
- The demo account must be **admin or editor**. Viewers get capture disabled with
  explanatory text, which a reviewer will read as the core feature being broken.
- Seed it with receipts in a few states so the list isn't empty.
- The web app must be deployed before submitting: `/terms` and `/signup` are linked
  from inside the app, and a reviewer tapping into a 404 is worse than no link.

**App Privacy nutrition label** (App Store Connect) and `PrivacyInfo.xcprivacy` are
separate artifacts that must agree — Apple validates the manifest and publishes the
label. Both declare: Photos or Videos, Other User Content (the receipt `note` field),
Email Address, Name, User ID, Device ID (the APNs token). Label edits publish without
a build or a review.

---

## Legal Links

`/privacy` and `/terms` are linked from the sign-in screen footer and Settings →
About → Legal, opened in an in-app `SFSafariViewController` (`Components/SafariView.swift`)
rather than handed off to Safari — App Store Review Guideline 5.1.1(i) requires the
privacy policy to be reachable *within* the app, not only from the App Store Connect
metadata field. All jetledger.io paths derive from one base in `AppConstants.Links`,
and `LegalLinksTests` pins each to the web app's published route.

**Account creation stays web-only.** The Terms clickwrap lives on the web signup and
invite-accept forms, and acceptance is recorded per user in `profiles.terms_accepted_at`
/ `terms_version`. The sign-in screen links out to `/signup`; if the app ever grows its
own signup it must present the same clickwrap and record acceptance the same way.
Added 2026-07-31 alongside the web app's public-launch legal pages. Acceptance is no
longer signup-only — when the published version changes, the app participates in
re-acceptance (next section).

---

## Terms Re-acceptance

Users whose accepted Terms version doesn't match the published one must accept before
the API serves them. Contract: web repo `docs/ios-api.md` § "Terms re-acceptance
(2026-07-31)"; design record `docs/plans/2026-07-31-terms-reacceptance-design.md`
there. Client half added 2026-08-01.

- **Signal:** top-level `terms` object (`current_version`, `accepted_version`,
  `acceptance_required`, `terms_url`, `privacy_url`) on `GET /api/accounts` and every
  session-creating auth response. **Key off `acceptance_required` only** — the server
  owns the version comparison. `accepted_version: null` = pre-clickwrap user, gate
  copy says first acceptance rather than "updated". An absent `terms` object (older
  server) clears the gate.
- **State is `AuthService.termsStatus`, in-memory only — deliberately not persisted.**
  The gate fails OPEN offline: only a fresh successful response with
  `acceptance_required: true` or the typed 403 may block UI; a transport error never
  does. An online cold launch re-learns the state from the accounts fetch it already
  performs; an offline launch never gates, so airborne capture keeps working.
  `AccountService.onTermsStatus` (wired in `JetLedgerApp`) routes accounts-refresh
  signals in; `clearSession()` wipes the state on sign-out.
- **403 backstop:** every non-allowlisted authenticated endpoint returns
  `{"error": "terms_acceptance_required", ...}` for a behind user.
  `APIClient.termsRequiredPayload` matches the error string **exactly** (contract,
  like the drain middleware's `"maintenance"` — not a substring match), throws typed
  `APIError.termsAcceptanceRequired`, and fires `onTermsAcceptanceRequired` so the
  gate goes up regardless of which service tripped it first — a landing-time upload
  burst can beat the foreground accounts refresh. Allowlisted (never 403 for terms):
  `GET /api/accounts`, `POST /api/terms/accept`, logout, delete-account.
- **A terms 403 parks queue work, never fails it** (see Sync & Upload): receipts
  revert to `.queued`, so no "Failed" badge and no stalled banner for a condition one
  tap resolves; grant expiry still runs on its own clock (`isGrantUsable` re-uploads
  if acceptance comes late); no `lastError`, because the gate is the report. Status
  sync stops quietly the same way.
- **Presentation:** `TermsGateView` (`Views/Terms/`) renders as an opaque ZStack layer
  over `MainView` in `JetLedgerApp.rootView` — `.authenticated` only, never
  `.offlineReady`. A layer, not a replacement or a sheet: services and in-progress UI
  survive (an already-open capture sheet sits above it and can finish; its upload
  parks), and it can't be swiped away or collide with other presentations. `MainView`
  is `.accessibilityHidden` while gated. The document opens via the signal's
  `terms_url` in the existing `SafariView` pattern — there is no content API.
- **Accept:** `POST /api/terms/accept` echoes the displayed `current_version` (proves
  what the user was shown; `AuthService.acceptCurrentTerms`, raw request so the 409
  body is readable). 200 → refreshed signal clears the gate, and `MainView`'s
  `onChange(of: termsAcceptanceRequired)` kicks `processQueue` + status sync + list
  refresh. 409 → the published version moved mid-review: adopt the new version and
  re-present — never silently retry with a version the user wasn't shown. Declining:
  Sign Out (keeps offline identity + queued captures) or Delete Account — both
  reachable from the gate, both allowlisted server-side.

---

## Remaining TODOs

### iOS Phase 4 (Polish)
- [ ] TestFlight distribution for internal testing
- [ ] App Store submission — **public listing, not Unlisted** (see App Store Review below)
  - Screenshots: `scripts/appstore-screenshots.sh [iphone|ipad|both]` boots the two
    App Store-required sims (iPhone 17 Pro Max 6.9", iPad Pro 13" M5), overrides the
    status bar to the clean 9:41 / full-battery / full-signal state, and captures
    interactively to `~/Desktop/JetLedger-Screenshots/`. Install + launch the build first.

### iOS Phase 6 (Push Notifications — infra)
- [ ] Apple Developer Portal: Create APNs Key, enable Push Notifications on App ID
- [ ] Production: Set `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`, `APNS_BUNDLE_ID` env vars

### Post-v1 (after TestFlight)
- [ ] Visible push on membership change — "You've been added to \<org\>" alert notification
      (Go backend: hook invite-acceptance + admin membership handlers into the existing
      APNs fan-out). Deliberately NOT a silent `content-available` sync push — those are
      throttled/unreliable; tapping the alert opens the app, whose foreground account
      refresh (2026-07-15) makes the new membership appear. Decided 2026-07-15.

---

## Out of Scope (v1)

- AI OCR (server-side future enhancement)
- Email receipt forwarding
- Receipt amount field
- Expense creation on iOS
- Apple Watch
