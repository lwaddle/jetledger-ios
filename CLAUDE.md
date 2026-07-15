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
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
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
- Image output: JPEG quality ~0.8, max 4096px long edge, target 1-3MB/page
- Paths in SwiftData are **relative** to Documents directory
- Capture flow: camera → preview (Add Page / Done; Original/Auto toggle + corner adjustment behind an "Adjust" disclosure — no manual exposure control, removed 2026-07 as a data-destroying knob the enhancer obsoleted) → metadata. No separate multi-page prompt screen; metadata has an "Add Page" thumbnail tile, and metadata drafts (note/trip ref) persist on the coordinator across the camera round-trip

---

## Sync & Upload

- `SyncService` manages upload queue (FIFO), status sync, retry with exponential backoff, cleanup
- Upload: get presigned URL → PUT to R2 → create `staged_receipts` record via API
- Status sync on foreground + pull-to-refresh (bulk `GET /api/receipts/status`)
- Auto-cleanup: images deleted after retention period (`@AppStorage("imageRetentionDays")`), SwiftData record at 2x retention
- `R2UploadService` uses custom `URLSession` with 30s timeout
- Dynamic content type per page (`image/jpeg` or `application/pdf`)
- **Trip reference creation is online-only.** `TripReferenceService.createTripReference` throws typed errors: `TripReferenceError.offline` (no connectivity) and `TripReferenceError.conflictWithExisting(TripReferenceSummary)` (server 409 — surfaced as a "Use this one" affordance in the picker). Pickers work offline against the cached list; receipts can be captured without a trip link and tagged later via the detail edit sheet or on the web during review.

---

## Design

- Professional, minimal — "Deep Slate" theme: nav `#0F172A`, accent `#1E3A5F`
- Dark mode supported via iOS system colors
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
