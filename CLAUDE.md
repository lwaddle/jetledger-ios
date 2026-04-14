# JetLedger iOS App — v1 Specification

## Overview

JetLedger iOS is a companion app for the JetLedger web application. Its primary purpose is **receipt acquisition** — allowing pilots and crew to capture receipt images in the field (including while airborne without connectivity) and upload them for review on the web app.

The iOS app is intentionally minimal. Full expense management happens on the web. The iOS app captures, enhances, and uploads receipt images with optional metadata (note, trip reference). That's it.

**Target Platforms:** iPhone and iPad (Universal app)
**Framework:** SwiftUI
**Minimum iOS Version:** iOS 17.0
**Distribution:** App Store (Unlisted)
**Backend:** Go API (shared with web app)
**Storage:** Cloudflare R2 (shared with web app)

---

## Architecture Overview

```
┌─────────────────────┐        ┌──────────────────────┐        ┌──────────────────┐
│     iOS App         │        │    Go Backend API    │        │    Web App       │
│                     │        │                      │        │                  │
│  📸 Capture Receipt │        │  Auth (shared)       │        │  📥 Receipts     │
│  📝 Add Note        │───────▶│  staged_receipts     │◀───────│  "Needs Review"  │
│  🔗 Trip Reference  │  HTTP  │  Cloudflare R2       │  Query │                  │
│  📤 Upload Queue    │        │  trip_references     │        │  ✅ Create Exp.  │
│                     │        │                      │        │  🔗 Link to Exp. │
│  💾 Offline Storage │        │                      │        │  ❌ Reject       │
└─────────────────────┘        └──────────────────────┘        └──────────────────┘
```

### Key Architectural Decisions

- **Offline-first**: All captures are saved locally. Uploads happen when connectivity is available.
- **Shared authentication**: Same Go backend auth as the web app. Same credentials, same MFA.
- **Shared storage**: Receipt images upload to the same Cloudflare R2 bucket used by the web app.
- **Shared database**: Records are written to the same `staged_receipts` table the web app reads from.
- **No expense management**: The iOS app does not create expenses, manage settings, or generate reports.
- **Zero third-party dependencies**: All networking via native `URLSession` through a shared `APIClient`.

---

## Authentication

### Login Flow

1. **Email + Password** — `POST /api/auth/login` to Go backend
2. **TOTP Challenge (if enabled)** — User enters 6-digit TOTP code or recovery code, verified via `POST /api/auth/verify-totp`
3. **Account Selection** — Accounts are returned in the login response and presented on the main screen (not a separate step — see Main Screen below)

### Session Management

- Store the session token (opaque base64, 30-day lifetime) securely in iOS Keychain via `KeychainHelper`
- Token cached in memory on `APIClient` to avoid Keychain reads per request
- On 401 from any API call, `APIClient.onUnauthorized` fires and returns user to login
- If the token expires while offline, the app continues to function for capture — re-authentication is required only when attempting to sync
- "Sign Out" calls `POST /api/auth/logout`, clears the Keychain, and returns to the login screen

### Permissions

Only users with **admin** or **editor** roles in an account can upload receipts. Viewers cannot use the iOS app's capture functionality. The app should check the user's role for the selected account and show an appropriate message if they are a viewer.

---

## Main Screen

The main screen is the hub of the app. It should feel simple and purpose-driven.

### Layout

```
┌─────────────────────────────────────────┐
│  JetLedger              [Settings ⚙️]   │
│                                         │
│  [Account Selector ▼]                   │
│  Smith Aviation                         │
│                                         │
│                                         │
│         ┌───────────────────┐           │
│         │                   │           │
│         │    📸 Scan        │           │
│         │    Receipt        │           │
│         │                   │           │
│         └───────────────────┘           │
│                                         │
│  ─────────────────────────────────────  │
│                                         │
│  Recent Receipts                        │
│                                         │
│  ┌─────┐ Fuel stop KPDX                │
│  │ 📄  │ Jan 15, 2026 · Trip 321004    │
│  │     │ ☁️ Uploaded                    │
│  └─────┘                                │
│                                         │
│  ┌─────┐ Catering LAX                  │
│  │ 📄  │ Jan 15, 2026                  │
│  │     │ ⏳ Waiting to upload           │
│  └─────┘                                │
│                                         │
│  ┌─────┐ FBO Receipt                   │
│  │ 📄  │ Jan 14, 2026 · Trip 321004    │
│  │     │ ✅ Processed                   │
│  └─────┘                                │
│                                         │
└─────────────────────────────────────────┘
```

### Account Selector

- Displayed near the top of the main screen
- If the user belongs to only one account, show it as a static label (not interactive)
- If the user belongs to multiple accounts, show as a tappable dropdown/picker
- Changing accounts filters the receipt list and determines which account new receipts are associated with
- Default to the user's `is_default = true` account on login
- Cache account list locally for offline use

### Scan Receipt Button

- Large, prominent, and unmissable — this is the app's primary action
- Tapping opens the camera capture flow (see Camera & Capture below)
- Disabled with explanatory text if the user is a viewer role

### Receipt List

- Shows all receipts captured by the current user for the selected account
- Each row shows: thumbnail, note (or "No note"), date, trip reference (if set), sync status
- Sync status indicators:
  - ⏳ **Queued** — Saved locally, waiting for connectivity
  - ☁️ **Uploading** — Currently uploading
  - ✅ **Uploaded** — Successfully synced to server
  - ❌ **Failed** — Upload failed (tap to retry)
  - 🔄 **Processed** — Web reviewer has processed this receipt (created/linked to expense)
  - 🚫 **Rejected** — Web reviewer rejected this receipt
- Tapping a row opens the Receipt Detail view
- Pull-to-refresh triggers a sync attempt

### iPad Layout

On iPad, use a split view:
- **Left panel**: Receipt list (as above, without the scan button header)
- **Right panel**: Receipt detail for the selected receipt
- **Scan Receipt button**: Prominent placement in the toolbar/navigation bar
- Camera capture still opens full-screen

---

## Camera & Capture Flow

This is the core experience of the app. The goal is fast, high-quality receipt capture with minimal friction.

### Capture Flow

```
Camera View → Auto-Detect Edges → Snap → Preview (Cropped + Enhanced) → Accept / Adjust / Retake
                                                                              │
                                                                    ┌─────────┴──────────┐
                                                                    │                    │
                                                              Add Another Page     Done (Save)
                                                                    │                    │
                                                              Camera View          Add Metadata
                                                                                   (Note, Trip)
```

### Step 1: Camera View

- Full-screen camera preview
- **Live edge detection overlay** using Vision framework (`VNDetectRectanglesRequest`)
  - When a rectangle (receipt) is detected, overlay a translucent highlight with corner markers on the detected edges
  - Edge color: subtle blue/white outline that turns green when a stable rectangle is detected
  - Require the rectangle to be stable for ~0.5 seconds before indicating "ready" (prevents jitter)
- **Shutter button** — large, centered at the bottom. Manual tap required (no auto-capture)
- **Flash toggle** — top corner
- **Close/Cancel** — top-left X button to exit capture without saving
- **Gallery picker** — small icon near shutter to select from photo library instead of camera
- If no rectangle is detected, still allow capture — the user can manually adjust corners in the next step

### Step 2: Preview & Crop

After capture (or image selection from gallery):

1. **Perspective correction** applied automatically using the detected rectangle corners (`CIPerspectiveCorrection`)
2. **Image enhancement** applied based on user's default preference (see Image Enhancement below)
3. **Preview** shows the corrected, enhanced result

Three actions available:

- **Accept (✓ checkmark)** — Keeps the image as-is. If multi-page mode, prompts "Add another page?" Otherwise, proceeds to metadata.
- **Adjust (✏️ edit icon)** — Opens the manual corner adjustment view
- **Retake (← back arrow)** — Returns to camera to try again

### Step 3: Manual Corner Adjustment (Optional)

Shown when the user taps "Adjust" or when edge detection confidence is low:

- Displays the **original uncropped image** with four draggable corner handles
- Each corner handle has a **magnification loupe** (like TurboScan) that appears when the user drags a corner, showing a zoomed view of the area under their finger for precise placement
- A semi-transparent overlay shows the area that will be cropped
- **Done** applies the new crop and returns to Preview
- **Reset** restores the auto-detected corners

### Image Enhancement

Three modes, selectable per-capture with a configurable default:

| Mode | Description | Implementation |
|------|-------------|----------------|
| **Original** | No processing, raw photo | Pass-through |
| **Auto** (default) | Contrast boost, white balance, slight sharpening | `CIColorControls` (contrast + brightness) + `CIUnsharpMask` + `CIWhitePointAdjust` |
| **Black & White** | High-contrast grayscale, optimized for thermal paper | `CIColorMonochrome` + `CIColorControls` (high contrast) |

- Enhancement mode selector shown in the Preview step (three small icons/toggles)
- Tapping a mode instantly shows the result (live preview)
- Default mode is configurable in Settings (persisted in `UserDefaults`)
- "Auto" is the recommended and initial default

### Multi-Page Receipts

Multi-page receipts (common for FBO invoices) are supported:

- After accepting a page, the user is prompted: **"Add another page?"** with Yes/No buttons
- If "Yes", the camera reopens for the next page
- A page counter shows progress: "Page 2 of 2"
- All pages are grouped as a single receipt in the system
- The receipt list shows a page count badge on multi-page receipts
- In the Receipt Detail view, pages are shown as a horizontal swipe gallery
- Pages can be reordered via drag-and-drop in the detail view
- Individual pages can be deleted from a multi-page receipt
- **Data model**: A single `staged_receipts` record with multiple images. Options:
  - **Option A**: Multiple `staged_receipt_images` child records (normalized) — recommended
  - **Option B**: Multiple R2 paths stored as a JSON array on the staged_receipt — simpler
  - Decision: Use **Option A** for consistency with the web app's `expense_receipts` pattern (multiple images per parent record)

### Photo Library Selection

- Available via the gallery icon on the camera view
- Opens the system photo picker (`PHPickerViewController` via SwiftUI)
- Supports selecting multiple images at once (for multi-page receipts)
- Selected images go through the same edge detection → preview → enhance flow
- If an image has no detectable edges, skip directly to manual corner adjustment

---

## Metadata Entry

After accepting a receipt (single or multi-page), the user is prompted to add optional metadata:

### Metadata Screen

```
┌─────────────────────────────────────────┐
│  ← Back                    Save         │
│                                         │
│  Receipt Details                        │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  📄📄 2 pages                   │    │
│  │  [thumbnail previews]           │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Note                                   │
│  ┌─────────────────────────────────┐    │
│  │ Fuel stop KPDX                  │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Trip Reference (optional)              │
│  ┌─────────────────────────────────┐    │
│  │ 🔍 Search or create new...     │    │
│  └─────────────────────────────────┘    │
│                                         │
│         [Save Receipt]                  │
│                                         │
└─────────────────────────────────────────┘
```

### Fields

**Note** (optional, free text)
- Quick context for the web reviewer: "Fuel stop KPDX", "Catering for 6 pax", "Hangar fee"
- Single-line text field (with option to expand for longer notes)
- Keyboard auto-focuses on this field when the screen appears

**Trip Reference** (optional, combobox)
- Searchable dropdown showing existing trip references for this account
- Shows both `external_id` and `name` (e.g., "321004 — NYC Meeting")
- If the user types something that doesn't match an existing trip reference, offer to create a new one
- "Create new" flow: user enters the external_id, optionally a name → created via Go API (`POST /api/trip-references`)
- Trip reference list is cached locally and refreshed when online
- If offline, show cached list only; new trip reference creation is queued for when connectivity returns

### Save Behavior

- "Save Receipt" saves the receipt locally immediately (no network required)
- If online, upload begins automatically in the background
- If offline, receipt is queued for upload
- After save, the user returns to the main screen with the new receipt visible at the top of the list

---

## Receipt Detail View

Tapping a receipt in the list opens its detail view.

### Layout

```
┌─────────────────────────────────────────┐
│  ← Back                   [⋯ Actions]  │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │                                 │    │
│  │                                 │    │
│  │    [Full-size receipt image]    │    │
│  │    (pinch to zoom, swipe for   │    │
│  │     multi-page)                │    │
│  │                                 │    │
│  │                                 │    │
│  └─────────────────────────────────┘    │
│  ● ○ ○  (page indicators for multi)    │
│                                         │
│  Note: Fuel stop KPDX                   │
│  Trip: 321004 — NYC Meeting             │
│  Date: Jan 15, 2026, 2:34 PM           │
│  Status: ☁️ Uploaded                    │
│  Pages: 2                               │
│                                         │
└─────────────────────────────────────────┘
```

### Features

- **Full-size image viewer**: Pinch-to-zoom, double-tap to zoom in/out
- **Multi-page swipe**: Horizontal swipe between pages with page indicators
- **Metadata display**: Note, trip reference, capture date, sync status, page count
- **Edit metadata**: Tap note or trip reference to edit (only for receipts not yet processed/rejected)

### Actions Menu (⋯)

Available actions depend on the receipt's status:

| Status | Available Actions |
|--------|-------------------|
| **Queued** (local only) | Edit Note, Edit Trip, Delete, Retry Upload |
| **Uploaded** (pending on web) | Edit Note, Edit Trip, Delete |
| **Processed** (linked to expense) | View only (no edit/delete) |
| **Rejected** | View only, shows rejection reason |

### Deletion

- Available for receipts in **queued** or **uploaded** (pending) status
- Confirmation dialog: "Delete this receipt? This cannot be undone."
- If the receipt has been uploaded to the server:
  - Send a delete request to the API
  - API checks if status is still `pending` — if yes, deletes the record and R2 image
  - If status has changed (someone is actively processing it on the web), reject the delete with message: "This receipt is being reviewed and can no longer be deleted."
- If the receipt is local-only (queued), delete immediately from local storage

---

## Offline Support

Offline capability is critical — pilots often capture receipts while airborne without cellular data.

### What Works Offline

- ✅ Capturing receipt photos (camera and gallery)
- ✅ Image enhancement and cropping
- ✅ Adding/editing notes
- ✅ Selecting trip references (from cached list)
- ✅ Viewing previously captured receipts
- ✅ Saving receipts to local storage

### What Requires Connectivity

- 🌐 Login / authentication
- 🌐 Uploading receipts to server
- 🌐 Creating new trip references
- 🌐 Deleting server-side receipts
- 🌐 Refreshing trip reference list
- 🌐 Checking receipt status updates (processed/rejected)

### Local Storage

**Images**: Saved to the app's Documents directory (not the photo library). Organized by receipt ID.

**Metadata**: Stored using SwiftData (or Core Data). Schema:

```swift
@Model
class LocalReceipt {
    var id: UUID
    var accountId: UUID
    var note: String?
    var tripReferenceId: UUID?
    var tripReferenceExternalId: String?  // cached for display
    var tripReferenceName: String?        // cached for display
    var capturedAt: Date
    var enhancementMode: EnhancementMode  // original, auto, blackAndWhite
    var syncStatus: SyncStatus            // queued, uploading, uploaded, failed
    var serverReceiptId: UUID?            // set after successful upload
    var serverStatus: ServerStatus?       // pending, processed, rejected (synced from server)
    var rejectionReason: String?          // if rejected
    var pages: [LocalReceiptPage]         // ordered list of page images
}

@Model
class LocalReceiptPage {
    var id: UUID
    var sortOrder: Int
    var localImagePath: String  // path in Documents directory
    var r2ImagePath: String?    // set after upload
}
```

**Cached Data**: Trip references and account info cached in SwiftData, refreshed when online.

### Sync Engine

**Upload queue**: Background upload manager that processes queued receipts when connectivity is available.

1. Monitor network reachability (`NWPathMonitor`)
2. When connectivity is restored, process the upload queue in FIFO order
3. For each receipt:
   a. Upload image(s) to R2 via presigned URL (obtained from `/api/receipts/upload-url` endpoint)
   b. Create `staged_receipts` record in Supabase
   c. If trip reference creation was queued, create that first
   d. Update local `syncStatus` to `uploaded`
   e. If upload fails, mark as `failed` with retry capability
4. Use `URLSession` background upload tasks so uploads continue if the app is backgrounded

**Status sync**: When the app comes to the foreground or on pull-to-refresh, fetch updated status for uploaded receipts (check if any have been processed or rejected on the web).

### Conflict Handling

- **Receipt deleted on iOS while being reviewed on web**: API rejects the delete. iOS shows "This receipt is being reviewed." Receipt remains.
- **Receipt processed on web while user edits metadata on iOS**: Metadata edits are rejected for processed receipts. iOS updates status to "Processed" on next sync.
- **Token expired while offline**: On next sync attempt, prompt re-authentication. Captured receipts are safe in local storage.

---

## Settings

Minimal settings screen, accessible from the gear icon on the main screen.

### Settings Options

```
┌─────────────────────────────────────────┐
│  ← Settings                             │
│                                         │
│  ACCOUNT                                │
│  ┌─────────────────────────────────┐    │
│  │ Profile                     →   │    │
│  │ Loren Waddle                    │    │
│  │ loren@jetledger.io              │    │
│  └─────────────────────────────────┘    │
│                                         │
│  CAPTURE                                │
│  ┌─────────────────────────────────┐    │
│  │ Default Enhancement         →   │    │
│  │ Auto                            │    │
│  └─────────────────────────────────┘    │
│                                         │
│  APP                                    │
│  ┌─────────────────────────────────┐    │
│  │ About JetLedger             →   │    │
│  │ Version 1.0.0 (Build 1)        │    │
│  └─────────────────────────────────┘    │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │ Sign Out                        │    │
│  └─────────────────────────────────┘    │
│                                         │
└─────────────────────────────────────────┘
```

### Profile (Read-Only for v1)

- Display name, email
- Profile picture (if set on web)
- No editing in v1 — direct users to the web app for profile changes

### Default Enhancement

- Picker: Original / Auto / Black & White
- Persisted in `UserDefaults`
- Applied automatically during capture; user can still change per-capture in the preview step

### About

- App version and build number
- Link to JetLedger web app
- Link to support/contact email

---

## API Endpoints (New / Modified)

The iOS app requires these API endpoints on the web app's backend:

### `POST /api/receipts/upload-url`

Get a presigned URL for uploading a receipt image to R2.

```
POST /api/receipts/upload-url
Authorization: Bearer <session_token>
Content-Type: application/json

Body:
{
  "account_id": "uuid",
  "staged_receipt_id": "uuid",
  "file_name": "receipt_001.jpg",
  "content_type": "image/jpeg",
  "file_size": 1048576  // bytes
}

Response 200:
{
  "upload_url": "https://r2.cloudflarestorage.com/...",
  "file_path": "staged-receipts/{account_id}/{uuid}/{file_name}"
}

Errors:
- 401: Unauthorized
- 403: User is viewer role (not permitted)
- 413: File too large (>10MB)
```

### `POST /api/receipts`

Create a staged receipt record after images are uploaded to R2.

```
POST /api/receipts
Authorization: Bearer <session_token>
Content-Type: application/json

Body:
{
  "account_id": "uuid",
  "note": "Fuel stop KPDX",                    // optional
  "trip_reference_id": "uuid",                  // optional
  "images": [                                    // at least 1
    {
      "file_path": "staged-receipts/...",
      "file_name": "page1.jpg",
      "file_size": 1048576,
      "sort_order": 0,
      "content_type": "image/jpeg"              // optional
    },
    {
      "file_path": "staged-receipts/...",
      "file_name": "page2.pdf",
      "file_size": 524288,
      "sort_order": 1,
      "content_type": "application/pdf"         // optional
    }
  ]
}

Response 201:
{
  "id": "uuid",
  "status": "pending",
  "created_at": "2026-01-15T14:30:00Z"
}

Errors:
- 401: Unauthorized
- 403: Viewer role
- 422: Validation error
```

### `DELETE /api/receipts/{id}`

Delete a pending staged receipt.

```
DELETE /api/receipts/{id}
Authorization: Bearer <session_token>

Response 200: { "deleted": true }

Errors:
- 401: Unauthorized
- 403: Not the uploader, or viewer role
- 409: Receipt is no longer pending (being processed or already processed)
- 404: Receipt not found
```

### `PATCH /api/receipts/{id}`

Update metadata on a pending staged receipt.

```
PATCH /api/receipts/{id}
Authorization: Bearer <session_token>
Content-Type: application/json

Body:
{
  "note": "Updated note",              // optional
  "trip_reference_id": "uuid" | null   // optional
}

Response 200: { "id": "uuid", "note": "...", "trip_reference_id": "..." }

Errors:
- 401: Unauthorized
- 403: Not the uploader, or viewer role
- 409: Receipt is no longer pending
- 404: Receipt not found
```

### `GET /api/receipts/status`

Bulk check status of uploaded receipts (for sync).

```
GET /api/receipts/status?ids=uuid1,uuid2,uuid3
Authorization: Bearer <session_token>

Response 200:
{
  "receipts": [
    { "id": "uuid1", "status": "pending" },
    { "id": "uuid2", "status": "processed", "expense_id": "uuid" },
    { "id": "uuid3", "status": "rejected", "rejection_reason": "duplicate" }
  ]
}
```

### `POST /api/user/device-tokens`

Register a device token for push notifications.

```
POST /api/user/device-tokens
Authorization: Bearer <session_token>
Content-Type: application/json

Body:
{
  "token": "hex-device-token",
  "platform": "ios"
}

Response 200: { "registered": true }

Errors:
- 401: Unauthorized
- 422: Missing token or invalid platform
```

### `DELETE /api/user/device-tokens`

Unregister a device token (on sign-out).

```
DELETE /api/user/device-tokens
Authorization: Bearer <session_token>
Content-Type: application/json

Body:
{
  "token": "hex-device-token",
  "platform": "ios"
}

Response 200: { "unregistered": true }
```

### Trip Reference Endpoints

- `GET /api/trip-references` — List trip references for the account (via `X-Account-ID` header)
- `POST /api/trip-references` — Create new trip reference
- `PUT /api/trip-references/{id}` — Update existing trip reference

---

## Database Changes

### New Table: `staged_receipt_images`

Stores individual page images for staged receipts (multi-page support).

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| id | uuid | PK, DEFAULT gen_random_uuid() | |
| staged_receipt_id | uuid | FK → staged_receipts, ON DELETE CASCADE, NOT NULL | Parent receipt |
| file_path | text | NOT NULL | Cloudflare R2 path |
| file_name | text | NOT NULL | Original filename |
| file_size | integer | | File size in bytes |
| sort_order | integer | DEFAULT 0 | Page order |
| content_type | text | | MIME type (e.g. `image/jpeg`, `application/pdf`) |
| created_at | timestamptz | DEFAULT now() | |

### Modified Table: `staged_receipts`

Update the existing `staged_receipts` design:

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| id | uuid | PK, DEFAULT gen_random_uuid() | |
| account_id | uuid | FK → accounts, NOT NULL | Owning account |
| trip_reference_id | uuid | FK → trip_references, ON DELETE SET NULL | Pre-assigned trip (optional) |
| note | text | | Quick note from uploader |
| status | text | CHECK (pending, processed, rejected), DEFAULT 'pending' | |
| rejection_reason | text | | Why rejected (duplicate, unreadable, not_business, other) |
| expense_id | uuid | FK → expenses | Linked expense after processing |
| uploaded_by | uuid | FK → profiles, NOT NULL | User who uploaded |
| processed_by | uuid | FK → profiles | User who processed/rejected |
| processed_at | timestamptz | | When processed/rejected |
| created_at | timestamptz | DEFAULT now() | |

**Changes from original design:**
- Replaced `image_path`, `file_name`, `file_size` with the `staged_receipt_images` child table (multi-page support)
- Changed `trip_id` to `trip_reference_id` (matches current schema)
- Removed `mime_type` from parent — tracked on individual images via `content_type`

### R2 Storage Path

```
staged-receipts/{account_id}/{staged_receipt_id}/page-001.jpg
staged-receipts/{account_id}/{staged_receipt_id}/page-002.jpg
```

Separate from existing expense receipt storage (`receipts/{account_id}/{expense_id}/...`).

When a staged receipt is processed into an expense, the images are **copied** (not moved) to the expense receipts path, and the staged receipt images are retained until the staged_receipt is cleaned up.

---

## App Structure (Xcode Project)

```
JetLedger/
├── JetLedgerApp.swift              # App entry point
├── Info.plist
├── Assets.xcassets                  # App icon, colors, images
│
├── Models/
│   ├── LocalReceipt.swift           # SwiftData model for local receipts
│   ├── LocalReceiptPage.swift       # SwiftData model for receipt pages
│   ├── CachedTripReference.swift    # SwiftData model for cached trip refs
│   ├── CachedAccount.swift          # SwiftData model for cached account info
│   └── Enums.swift                  # SyncStatus, EnhancementMode, etc.
│
├── Services/
│   ├── APIClient.swift              # Shared HTTP client, token management, auth headers
│   ├── AuthService.swift            # Go backend auth (login, MFA, session restore)
│   ├── SyncService.swift            # Upload queue, background sync
│   ├── R2UploadService.swift        # Presigned URL upload to R2
│   ├── ReceiptAPIService.swift      # staged_receipts CRUD (wraps APIClient)
│   ├── TripReferenceService.swift   # Fetch/create trip references (wraps APIClient)
│   ├── ImageProcessor.swift         # Edge detection, enhancement, cropping
│   ├── NetworkMonitor.swift         # Reachability monitoring
│   └── SharedImportService.swift    # Process imports from Share Extension
│
├── Views/
│   ├── Login/
│   │   ├── LoginView.swift
│   │   ├── MFAVerifyView.swift          # TOTP + recovery code support
│   │   └── AuthFlowView.swift           # Navigation between login and MFA
│   ├── Main/
│   │   ├── MainView.swift           # Primary screen with scan button + list
│   │   ├── ReceiptListView.swift    # Receipt list component
│   │   └── ReceiptRowView.swift     # Individual receipt row
│   ├── Capture/
│   │   ├── CameraView.swift         # Camera with edge detection overlay
│   │   ├── PreviewView.swift        # Post-capture preview with enhance
│   │   ├── CropAdjustView.swift     # Manual corner adjustment
│   │   └── MetadataView.swift       # Note + trip reference entry
│   ├── Import/
│   │   ├── ImportFlowCoordinator.swift  # Import state machine
│   │   ├── ImportFlowView.swift         # Import flow container + file picker
│   │   ├── ImportPreviewView.swift      # File thumbnail preview grid
│   │   └── ImportMetadataView.swift     # Note + trip reference for imports
│   ├── Detail/
│   │   ├── ReceiptDetailView.swift  # Full receipt viewer
│   │   ├── ImageGalleryView.swift   # Multi-page swipe viewer
│   │   └── EditMetadataSheet.swift  # Metadata editing sheet
│   └── Settings/
│       ├── SettingsView.swift
│       └── AboutView.swift
│
├── Shared/
│   ├── PendingImport.swift          # Codable model for shared import manifest
│   └── SharedContainerHelper.swift  # App Group container file I/O
│
├── Components/
│   ├── AccountSelectorView.swift
│   ├── TripReferencePicker.swift    # Searchable combobox
│   ├── SyncStatusBadge.swift
│   ├── EnhancementModePicker.swift
│   ├── MagnifyingLoupe.swift        # Corner drag loupe for crop adjust
│   ├── ZoomableImageView.swift      # UIScrollView pinch-to-zoom wrapper
│   └── PDFPageView.swift            # PDFKit viewer wrapper
│
└── Utilities/
    ├── KeychainHelper.swift
    ├── ImageUtils.swift              # Compression, format conversion, PDF thumbnails
    └── Constants.swift               # API URLs, limits, etc.

JetLedgerShare/                       # Share Extension target
├── ShareViewController.swift         # Extension entry point (UIViewController + SwiftUI)
├── ShareView.swift                   # Extension UI (process attachments, save to shared container)
└── Info.plist                        # Activation rules (files + images, max 10)
```

---

## Dependencies

**Zero third-party dependencies.** All networking via native `URLSession` through a shared `APIClient`.

**Framework Dependencies (Apple-provided):**
- `Security` — Keychain token storage (`KeychainHelper`)
- `Vision` — Rectangle detection for edge detection
- `CoreImage` — Image enhancement and perspective correction
- `AVFoundation` — Camera capture
- `PhotosUI` — Photo library picker
- `PDFKit` — PDF rendering in receipt detail view
- `SwiftData` — Local persistence
- `Network` — Reachability monitoring (`NWPathMonitor`)

---

## Design Guidelines (iOS)

### Visual Style

- Match the web app's professional, minimal aesthetic
- Use the same color palette as the web app's "Deep Slate" theme where appropriate:
  - Navigation/chrome: Dark navy (`#0F172A`) or iOS system navigation
  - Primary accent: `#1E3A5F` (dark navy blue)
  - Use iOS system colors for standard controls (respecting Dynamic Type and accessibility)
- **Dark mode supported**: The app uses iOS system colors and adapts to the user's Light/Dark appearance setting automatically

### Typography

- Use iOS system font (SF Pro) — do not attempt to match the web app's font
- Support Dynamic Type for accessibility
- Monospace for trip reference IDs (e.g., "321004")

### Haptics

- Light haptic on shutter tap (capture)
- Success haptic on receipt save
- Subtle haptic when edge detection locks onto a receipt

### Animations

- Smooth transition from camera to preview
- Page curl or slide for multi-page receipt viewing
- Fade transition on enhancement mode change

---

## Testing & QA Considerations

### Critical Paths to Test

1. **Offline capture → online upload**: Capture 5 receipts offline, restore connectivity, verify all upload successfully
2. **Multi-page receipt**: Capture a 3-page receipt, verify page order, verify all pages upload
3. **Token expiry**: Let session expire while offline, capture a receipt, verify re-auth flow on sync
4. **Account switching**: Switch accounts, verify receipt list filters correctly, verify new captures go to correct account
5. **Deletion conflict**: Upload a receipt, start processing it on web, try to delete from iOS
6. **Large images**: Capture a high-resolution image, verify compression keeps it under 10MB
7. **Edge detection failure**: Capture a crumpled receipt on a cluttered background, verify manual crop works
8. **MFA login**: Verify TOTP challenge works correctly for users with 2FA enabled
9. **Viewer role**: Verify a viewer cannot capture or upload receipts

### Image Quality

- Compressed JPEG output (quality ~0.8) to balance quality and upload size
- Maximum dimension: 4096px on the long edge (downscale if larger)
- Target file size: 1-3MB per page after compression
- Enhanced images should be visually superior to raw photos for receipt readability

---

## Future Considerations (Not in v1)

These items are explicitly out of scope for v1 but are noted for future planning:

- **AI OCR integration**: When Phase 7 OCR is built on the server, receipts will be processed automatically after upload. No iOS changes required — it's a server-side enhancement.
- **Push notifications**: Notify pilot when receipt is processed/rejected. Requires APNs setup.
- **Email receipt forwarding**: Cloudflare Email Workers can also feed into `staged_receipts`. Same web review queue, different input channel.
- **Receipt amount field**: If AI OCR isn't performing well, consider adding an optional amount field on iOS.
- **Expense creation on iOS**: Not planned. Expense management is a web-only activity.
- ~~**Biometric authentication**: Face ID / Touch ID for quick re-authentication after session expiry.~~ (Implemented in Phase 7)
- **Apple Watch**: Quick-capture from wrist (extreme future).

---

## Development Phases (iOS)

### iOS Phase 1: Foundation
- [x] Xcode project setup (SwiftUI, iOS 17+, Universal)
- [x] Go backend API integration via shared APIClient
- [x] Login screen (email + password)
- [x] MFA/TOTP verification screen (with recovery code support)
- [x] Keychain session storage (via KeychainHelper, cached in APIClient)
- [x] Account fetching and selection
- [x] Basic main screen layout with account selector
- [x] SwiftData models for local storage
- [x] Settings screen (sign out, about)

### iOS Phase 2: Camera & Capture
- [x] Camera view with AVFoundation
- [x] Vision framework edge detection with live overlay
- [x] Photo capture and perspective correction
- [x] Image enhancement (Original / Auto / B&W modes)
- [x] Preview screen with accept/retake/adjust
- [x] Manual corner adjustment with magnifying loupe
- [x] Photo library import
- [x] Multi-page capture flow
- [x] Local storage of captured receipts
- [x] Default enhancement preference in Settings

### iOS Phase 3: Metadata & Sync
- [x] Metadata entry screen (note + trip reference)
- [x] Trip reference picker (search existing / create new)
- [x] Trip reference local caching
- [x] Network monitoring (NWPathMonitor)
- [x] Upload queue with background URLSession
- [x] Presigned URL workflow for R2 upload
- [x] Staged receipt API integration (create, update, delete)
- [x] Sync status indicators on receipt list
- [x] Status sync on foreground / pull-to-refresh
- [x] Retry failed uploads

### iOS Phase 4: Polish
- [x] Receipt detail view with pinch-to-zoom
- [x] Multi-page swipe gallery
- [x] iPad split view layout
- [x] Haptic feedback
- [x] Error handling and user-facing messages
- [x] Empty states
- [x] App icon and launch screen
- [x] App Store listing assets (screenshots, description)
- [ ] TestFlight distribution for internal testing
- [ ] App Store (Unlisted) submission

### iOS Phase 5: PDF/File Import & Share Extension
- [x] `PageContentType` enum and `contentTypeRaw` on `LocalReceiptPage`
- [x] PDF save/thumbnail/render utilities in `ImageUtils`
- [x] Dynamic content type in `SyncService` upload pipeline
- [x] `PDFPageView` component (PDFKit wrapper) for PDF rendering
- [x] PDF rendering in `ImageGalleryView`, `ReceiptRowView`, `ReceiptDetailView`
- [x] In-app file import flow (`ImportFlowCoordinator`, preview, metadata)
- [x] "Import from Files" button on main screen (iPhone + iPad)
- [x] Share Extension target (`JetLedgerShare`) with App Group shared container
- [x] `SharedImportService` processes pending imports on app foreground
- [x] Backend: accept `application/pdf` in `POST /api/receipts/upload-url`, increase max size to 20MB
- [x] Backend: add `content_type` column to `staged_receipt_images` table
- [x] Web app: PDF rendering in receipt viewer

### iOS Phase 6: Push Notifications
- [x] `AppDelegate.swift` — APNs token handling + notification tap deep-link
- [x] `PushNotificationService.swift` — Permission, token registration/unregistration
- [x] `JetLedgerApp.swift` — Wire up delegate adaptor + push service lifecycle
- [x] `ReceiptAPIService.swift` — `registerDeviceToken` / `unregisterDeviceToken` methods
- [x] `JetLedger.entitlements` — `aps-environment` capability
- [x] `MainView.swift` — Deep-link navigation from notification tap
- [x] Backend: `device_tokens` table + RLS + migration
- [x] Backend: `POST /api/user/device-tokens` + `DELETE /api/user/device-tokens`
- [x] Backend: `src/lib/apns.ts` — APNs HTTP/2 + JWT token auth + push sending
- [x] Backend: Rejection handler hooks (`notifyReceiptRejected`)
- [ ] Apple Developer Portal: Create APNs Key, enable Push Notifications on App ID
- [ ] Production: Set `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`, `APNS_BUNDLE_ID` env vars

### iOS Phase 7: Biometric Authentication
- [x] `BiometricAuthService.swift` — Face ID/Touch ID availability, enable/disable, re-auth flow
- [x] `KeychainHelper.swift` — Biometric-protected Keychain methods (`.biometryCurrentSet`)
- [x] `AuthService.swift` — Async `restoreSession()` with biometric re-auth, 401 re-auth guard
- [x] `JetLedgerApp.swift` — BiometricAuthService lifecycle, post-login prompt alert
- [x] `SettingsView.swift` — Face ID toggle in Security section
- [x] `Info.plist` — `NSFaceIDUsageDescription`
- [x] Backend: `trusted_devices` table + migration
- [x] Backend: `POST /api/auth/trust-device` — Register device for biometric login
- [x] Backend: `POST /api/auth/device-login` — Authenticate with device token (no MFA)
- [x] Backend: `POST /api/auth/revoke-device` — Revoke device without ending session

---

## Web App Changes Required

The following changes to the JetLedger web app are needed to support the iOS app:

### API Endpoints (New)
- [x] `POST /api/receipts/upload-url` — Presigned R2 upload URL
- [x] `POST /api/receipts` — Create staged receipt record
- [x] `DELETE /api/receipts/{id}` — Delete pending receipt
- [x] `PATCH /api/receipts/{id}` — Update receipt metadata
- [x] `GET /api/receipts/status` — Bulk status check
- [x] `POST /api/user/device-tokens` — Register APNs device token
- [x] `DELETE /api/user/device-tokens` — Unregister APNs device token

### Database Migration
- [x] Create `staged_receipts` table
- [x] Create `staged_receipt_images` table
- [x] Create `device_tokens` table (push notifications)
- [x] RLS policies for all tables (account isolation, role checks)
- [x] Index on `staged_receipts(account_id, status)` for queue queries

### Web UI (Phase 6 — existing plan)
- [x] Receipts nav item with pending count badge
- [x] Receipt queue page (pending/processed/rejected tabs)
- [x] Receipt detail page with multi-page image viewer
- [x] "Create Expense" action (opens form with receipt images attached)
- [x] "Link to Existing" action (search expenses, attach images)
- [x] "Reject" action with reason selection
- [x] Bulk select for linking multiple receipts to one expense
