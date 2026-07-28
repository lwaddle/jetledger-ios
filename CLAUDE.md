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
- `R2UploadService` uses custom `URLSession` with 30s timeout
- Dynamic content type per page (`image/jpeg` or `application/pdf`)
- **Trip reference creation is online-only.** `TripReferenceService.createTripReference` throws typed errors: `TripReferenceError.offline` (no connectivity) and `TripReferenceError.conflictWithExisting(TripReferenceSummary)` (server 409 — surfaced as a "Use this one" affordance in the picker). Pickers work offline against the cached list; receipts can be captured without a trip link and tagged later via the detail edit sheet or on the web during review.

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

## Remaining TODOs

### iOS Phase 4 (Polish)
- [ ] TestFlight distribution for internal testing
- [ ] App Store (Unlisted) submission
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
