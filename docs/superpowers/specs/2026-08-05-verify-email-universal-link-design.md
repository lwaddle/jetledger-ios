# Verify-email universal link — design

**Date:** 2026-08-05
**Repos:** `jetledger-ios` (this one) and `jetledger` (web/Go API)

## Problem

A user creates an account from the iOS sign-in screen. "Create an account" opens
`https://jetledger.io/signup` in the in-app `SFSafariViewController`. They finish
signup, switch to Mail, and tap the verification link — which opens **Safari**, a
separate app. The user is now outside JetLedger with no path back except the app
switcher.

Nothing is broken. It is a context switch the user did not ask for, at the one
moment they are least oriented in the product.

The stakes are not purely cosmetic: `services.PurgeUnverifiedAccounts`
(`services/signup_purge.go:16`) deletes self-service accounts whose sole member
never verified, after 7 days. A verification step that feels like it went
sideways is a verification step people abandon.

## Why it happens

The link is tapped in Mail, not in the app. The `SFSafariViewController` from
signup is long gone; there is no browser session to return to. The only iOS
mechanism that routes a tapped `https://` URL into an installed app is a
**Universal Link**, and JetLedger claims none:

- `JetLedger/JetLedger.entitlements:7` declares
  `com.apple.developer.associated-domains` with a single entry,
  `webcredentials:jetledger.io` — no `applinks:` entry.
- The web app already serves `/.well-known/apple-app-site-association`
  (`main.go:522`), but the payload carries only a `webcredentials` block.
- The iOS app has no `onOpenURL` or `onContinueUserActivity` handler anywhere.

The registered `jetledger` custom URL scheme (`Info.plist:10`) is not a
substitute: custom schemes cannot be attached to an `https://` link in an email.

## Approach

Claim `/verify-email/*` as a universal link, and verify **natively** — no browser
in the happy path. The user taps the link in Mail, JetLedger opens, shows a brief
"Verifying…" state, and confirms. They are in the app, on the sign-in screen,
ready to sign in.

Verification requires one new unauthenticated JSON endpoint, because the existing
web flow is HTML-form-shaped and CSRF-protected.

### Rejected alternatives

- **Present the existing web verify page in the in-app `SFSafariViewController`.**
  Needs no new endpoint, and does technically keep the user in the app. Rejected
  as the happy path: the user still reads a web page and still taps a web button,
  so the flow that felt like a detour still looks like one. Retained as the
  *error* path, where the web page's copy and resend affordance are genuinely
  worth reaching.
- **Add an unauthenticated resend endpoint** so an expired link could be recovered
  entirely natively. Rejected as scope creep — it adds an email-enumeration
  surface and a second rate-limit decision for a path the web page already covers.

## Web repo (`jetledger`) changes

### 1. AASA gains an `applinks` block

`main.go:522`, replacing the single-line payload:

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["6KA5FYDT3Q.io.jetledger.JetLedger"],
        "components": [{ "/": "/verify-email/*" }]
      }
    ]
  },
  "webcredentials": { "apps": ["6KA5FYDT3Q.io.jetledger.JetLedger"] }
}
```

**The path scope is load-bearing.** Only `/verify-email/*` is claimed. `/signup`,
`/forgot-password`, `/terms` and `/privacy` must keep resolving as ordinary web
pages — the app opens those itself in `SafariView`, and claiming them would put
the app in a fight with its own links.

Serving requirements that already hold and must keep holding: HTTPS, no redirect,
`Content-Type: application/json`, no authentication.

### 2. `POST /api/auth/verify-email`

Registered with the **unauthenticated** `/api/auth/*` routes — above the
`apiAuth := mw.RequireAPIAuth()` block in `main.go`, wrapped in
`apiRL.RateLimitJSON` like `login` and `device-login`. It must not sit behind
`apiAuth`: the user tapping the link has no session, which is the whole point.

Request:

```json
{ "token": "<raw token from the link path>" }
```

Responses:

| Status | Body | Meaning |
|--------|------|---------|
| 200 | `{"verified": true}` | Token resolved; email is now verified |
| 400 | `{"error": "invalid_or_expired"}` | Token not found, already consumed, or expired |
| 400 | `{"error": "invalid_request"}` | Missing or malformed body |
| 500 | `{"error": "internal"}` | `SetEmailVerified` failed |

Handler logic mirrors `handlers.VerifyEmailSubmit` (`handlers/verify_email.go:46`)
exactly — `GetEmailVerificationByTokenHash(services.HashToken(raw))` →
`SetEmailVerified` → `InvalidateEmailVerificationsForUser` →
`adminAuditLogSystemless(ctx, userID, "email_verified")`. Identical side effects,
JSON instead of a rendered template.

This is a POST, so the reason `GET /verify-email/{token}` deliberately does not
mutate (email scanners prefetch links, and a prefetch must not burn the token —
`handlers/verify_email.go:22`) is preserved rather than worked around.

Not distinguishing "expired" from "already verified" is deliberate: both are a
token that no longer resolves, and splitting them would let an unauthenticated
caller probe token state.

### 3. Docs and tests

- `docs/ios-api.md` — a section for the new endpoint, matching the format of the
  existing entries.
- A handler test alongside `handlers/verify_email_test.go`: valid token verifies
  and consumes; reused token returns 400; unknown token returns 400.

### 4. Explicitly unchanged

`GET`/`POST /verify-email/{token}` and the email template keep working exactly as
they do today. Desktop users, users without the app installed, and mail clients
that rewrite links all get the current experience.

## iOS repo (`jetledger-ios`) changes

### 1. Entitlement

`JetLedger/JetLedger.entitlements` — add `applinks:jetledger.io` alongside the
existing `webcredentials:jetledger.io`.

### 2. Constants

`JetLedger/Utilities/Constants.swift`:

- `AppConstants.WebAPI.authVerifyEmail = "/api/auth/verify-email"`, following the
  existing `authX` naming.
- The universal-link matcher needs the host and the `/verify-email/` path prefix.
  Derive both from the existing `AppConstants.Links.site` so the domain stays a
  one-line change, consistent with the comment already on that constant.

### 3. `AuthService.verifyEmail(token:)`

Follows the `acceptCurrentTerms` shape (`Services/AuthService.swift:129`):
`apiClient.performRawRequest(.post, …)` with an encoded body, switching on the
returned HTTP status so the error body is readable. Returns a small outcome enum
— `.verified`, `.invalidOrExpired`, `.failed(message:)` — rather than throwing,
matching `TermsAcceptOutcome`.

No session is created and no auth state changes. Verification is a token
redemption, not a sign-in.

### 4. `Views/Auth/EmailVerificationView.swift`

Three states:

- **verifying** — progress indicator, "Verifying your email…"
- **verified** — success mark, "Email verified", "You can sign in now", Continue
- **expired/failed** — "This link has expired or was already used", with
  **Open in browser** (the same `https://jetledger.io/verify-email/<token>` URL
  in the existing `SafariView`, where the web page carries the real error copy
  and the resend path) and **Dismiss**

Transport failure is a `.failed` state with retry-friendly copy, distinct from
`invalid_or_expired` — a user offline in a hotel should not be told their link
is dead.

### 5. Link routing in `JetLedgerApp`

`.onOpenURL` on `rootView`. Match `url.host == <site host>` and
`url.path.hasPrefix("/verify-email/")`, take the remaining path component as the
token, reject anything else (including an empty token) by ignoring it. Store it
in `@State` and present `EmailVerificationView` as a sheet.

A sheet, not a root-view replacement, so it works identically from every
`authState` — `.unauthenticated`, `.authenticated`, `.offlineReady` — and cannot
strand a user whose app was mid-capture. It also composes correctly with
`TermsGateView`, which renders as an opaque `ZStack` layer over `MainView`: a
sheet presents above that layer without bypassing the gate, and verification is
not a gated action.

The app uses a `UIApplicationDelegateAdaptor` for push, but `AppDelegate` does
not implement `application(_:continue:restorationHandler:)` (verified — no
`continueUserActivity` reference exists in the repo), so SwiftUI's `onOpenURL`
receives universal links without interference.

### 6. Tests

`JetLedgerTests` — URL parsing, in the style of `LegalLinksTests`:

- a well-formed verify URL yields the expected token
- a wrong host is rejected
- a non-`/verify-email/` path is rejected
- a `/verify-email/` URL with no token is rejected
- the constructed `authVerifyEmail` path pins to `/api/auth/verify-email`

The sheet presentation and the live universal-link handoff are not unit-testable
and are covered by the manual checklist below.

## Deployment order

The AASA change must be live **before** a build claiming `applinks:` reaches a
device, otherwise the association fails and the link keeps opening Safari — the
current behavior, so the failure is silent and back-compatible, but it wastes a
build. Order: deploy web (AASA + endpoint) → build iOS → test.

## Known limits

These are accepted, not open questions.

- **Apple CDN-caches the AASA.** Devices fetch it via
  `app-site-association.cdn-apple.com`, which can lag a deploy. For immediate
  testing on a development build, `applinks:jetledger.io?mode=developer` bypasses
  the CDN. It must not ship in the release entitlement.
- **The association is fetched at install/first launch.** An already-installed
  build does not pick up a newly published AASA without a reinstall.
- **Link-rewriting email security scanners break the match.** The rewritten
  domain is not `jetledger.io`, so iOS does not route it to the app.
- **Not every mail client honors universal links.** Apple Mail does.
- **No app installed** — the link opens the web page, which is correct.

Every one of these degrades to today's behavior: the web verify page in Safari.
None of them can leave a user unable to verify.

## Manual verification checklist

1. Deploy web; confirm `curl -sI https://jetledger.io/.well-known/apple-app-site-association`
   returns 200, `application/json`, no redirect, and that the body contains both
   `applinks` and `webcredentials`.
2. Install a build with the `?mode=developer` entitlement on a device.
3. Sign up with a fresh address; tap the link in Apple Mail → JetLedger opens to
   the verifying state, then verified.
4. Tap the same link again → expired state; **Open in browser** shows the web
   page inside the app.
5. Tap the link with the app in each auth state (signed out, signed in, offline
   mode) → sheet presents correctly in all three.
6. Open the link on a device without the app → web page, unchanged.
7. Confirm `/signup`, `/forgot-password`, `/terms`, `/privacy` still open in the
   in-app browser and do **not** trigger the app-open path.

## Out of scope

- **Sign-in screen tap targets.** "Create an account" and "Forgot password?"
  (`Views/Login/LoginView.swift:105`) are `.font(.caption)` with hit areas the
  size of their text, below the 44×44pt HIG minimum. Reviewed on 2026-08-05 and
  deliberately left alone — small but usable. Revisit if it ever becomes an
  actual complaint rather than an observation.
- **An in-app resend affordance.** The web page's resend path is reachable from
  the error state.
- **Claiming any other jetledger.io path as a universal link.**
