# Native In-App Account Deletion — Design

**Date:** 2026-04-21
**Status:** Approved, ready for implementation plan
**Context:** Apple App Store Review Guideline 5.1.1(v) requires apps that support account creation to also support **in-app** account deletion. The web app already has this flow; this design adds a native iOS equivalent.

---

## Goal

Add a self-service "Delete Account" flow accessible from the iOS app's Settings screen that:
- Meets Apple's requirements for an in-app deletion entry point (not a web link-out).
- Mirrors the web app's UX (password + email confirmation, 30-day grace period messaging).
- Reuses the existing `POST /api/user/delete-account` endpoint — no backend changes.
- Fully wipes local data on success so the device is left in a clean state.

---

## Backend (existing, no changes required)

Endpoint: `POST /api/user/delete-account` (`api/auth.go:535`).

- Auth: Bearer token.
- Body: `{password: string, email_confirmation: string}`.
- Success (200): `{message: string, deletion_scheduled_for: string (ISO-8601)}`.
- Behavior: soft-deletes profile, revokes all sessions/trusted devices/device tokens immediately. A background job (`services/deletion_cleanup.go`) hard-deletes after 30 days.
- Last-admin guard: returns an error if the user is the sole admin of a multi-member account.

---

## §1 Entry point — Settings

Add a "Danger Zone" section at the bottom of `SettingsView`, below "Clear Device Data":

- One row: `Button("Delete Account", role: .destructive)`.
- Caption below: "Permanently delete your account and all associated data."
- Tapping presents `DeleteAccountView` as a `.sheet` (not `.fullScreenCover`) so the user can dismiss without consequence before submitting.
- Visible only when `authState == .authenticated` (not during `.offlineReady`).
- Self-deletion is role-independent — viewers, editors, and admins can all delete their own account.

## §2 `DeleteAccountView` — three visual states

**State `.form`**
- Header text: "This will delete your account and all associated data after a 30-day grace period. To cancel during that window, contact support."
- `SecureField` labelled "Password".
- `TextField` labelled "Type your email to confirm" — case-insensitive match against `authService.currentUserEmail`.
- "Delete Account" destructive button — enabled only when both fields non-empty AND email matches.
- Cancel / dismiss available at all times in this state.

**State `.submitting`**
- `ProgressView`, fields disabled, cancel disabled.

**State `.success`**
- Large check icon.
- Headline: "Account scheduled for deletion".
- Body: "Your account and all data will be permanently deleted on [formatted date]." + "Contact support to cancel."
- "Done" button → calls `authService.performFullAccountWipe()` → sheet dismisses as root view swaps to `LoginView`.

**Error display (form state)**
- Inline red text under the button.
- For `LastAdminError`: error text + `Link("Manage accounts on the web", destination: AppConstants.Links.webApp)` below. User resolves on the web, returns, retries.

## §3 `AuthService.deleteAccount(password:emailConfirmation:)`

```swift
func deleteAccount(password: String, emailConfirmation: String) async throws -> Date
```

- POSTs to `/api/user/delete-account`.
- Decodes `{message, deletion_scheduled_for}` into a `Date` using existing ISO-8601 decoder config.
- Throws typed `DeleteAccountError`:
  - `.invalidPassword`
  - `.emailMismatch`
  - `.lastAdmin(message: String)`
  - `.alreadyScheduled(Date?)`
  - `.network(Error)`
- Does NOT mutate `authState` or local storage — keeps the server call pure so the success screen can render before the root view flips.

## §4 `AuthService.performFullAccountWipe()`

```swift
func performFullAccountWipe() async
```

Called from the success screen's "Done" button. Performs, in order:

1. `apiClient.clearSessionToken()` — removes `session_token` from Keychain, nulls in-memory cache.
2. `biometricService?.deleteLocalTokens()` — removes biometric `device_token` and non-biometric `device_token_revocation` from Keychain.
3. `accountService.clearAllData()` — wipes `CachedAccount`, `CachedTripReference`, `LocalReceipt`, `LocalReceiptPage`, and `Documents/receipts/` image files.
4. `OfflineIdentity.clear()`.
5. UserDefaults removal: `currentUserId`, `currentUserEmail`, `selectedAccountId`, `hasPromptedBiometricLogin`, `imageRetentionDays`, `defaultEnhancementMode`.
6. `clearSession()` + `authState = .unauthenticated`.

APNs device-token unregistration is skipped — the server already revokes device tokens as part of the deletion handler.

## §5 Error handling

The server's exact error body shape is not fully inspected in this design. Implementation starts by decoding `{error: String}` and substring-matching for `"admin"`, `"password"`, `"email"` to map to the typed cases above. Verify against `handlers/profile.go:219` and `api/auth.go:535` during implementation and tighten if the server uses a distinct code field. Network errors bubble up as `URLError` wrapped in `.network`.

## §6 Testing

**Unit**
- `AuthService.deleteAccount` error mapping with a mock `APIClient`: 400 invalid password, 400 email mismatch, 403 last admin, 409 already scheduled, URLError.
- `performFullAccountWipe` clears all Keychain entries, all SwiftData models, all image files, and the listed UserDefaults keys.

**Manual UI checklist**
- Happy path: form → submitting → success → Done → LoginView with no residual data.
- Wrong password / wrong email: inline error, form preserved, can retry.
- Last-admin block: inline error + working "Manage on web" link.
- Network loss mid-submit: error shown, user can retry.
- Dismiss sheet before submitting: no server call, no state change.
- Force-quit between success response and Done: relaunch falls through to login (server already revoked session); local data is orphaned but can be wiped via existing "Clear Device Data" row. Accept as known edge case; document.
- VoiceOver read-through of both fields and the destructive button.

## §7 Accessibility & polish

- VoiceOver labels on both fields.
- Destructive button dynamically enabled based on form validity; `.warning` haptic on tap.
- Dynamic Type supported.
- Hardcoded English (no i18n in v1 per `CLAUDE.md`).

---

## Files touched (expected)

- `JetLedger/Services/AuthService.swift` — add `deleteAccount`, `performFullAccountWipe`, `DeleteAccountError`.
- `JetLedger/Views/Settings/SettingsView.swift` — add Danger Zone section + row.
- `JetLedger/Views/Settings/DeleteAccountView.swift` — new.
- `JetLedger/Constants.swift` — add `WebAPI` path if not already present (`/api/user/delete-account`).
- `JetLedgerTests/AuthServiceDeleteAccountTests.swift` — new.

## Out of scope

- Undo from within the app during grace period (web + support only).
- Pre-flight last-admin detection (rely on server error).
- Re-registration flow after deletion (user re-registers via web if they change their mind after 30 days).
