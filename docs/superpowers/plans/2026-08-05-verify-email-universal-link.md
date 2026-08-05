# Verify-Email Universal Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a tapped verification link in Mail open JetLedger and verify the email natively, instead of switching the user to Safari.

**Architecture:** The web app claims `https://jetledger.io/verify-email/*` as an iOS Universal Link by adding an `applinks` block to the Apple App Site Association payload it already serves. A new unauthenticated `POST /api/auth/verify-email` performs the same three mutations as the existing HTML form handler, in JSON. The iOS app declares the `applinks:` entitlement, parses the incoming URL to a token, and presents a sheet that calls the endpoint and reports the result. The existing web verify page is untouched and remains the path for desktop, for users without the app, and for the app's own expired-link fallback.

**Tech Stack:** Go 1.x + `net/http` `ServeMux` + sqlc-generated `shareddb` queries + testify (web); Swift 6.2 / SwiftUI / Swift Testing (iOS).

**Spec:** `docs/superpowers/specs/2026-08-05-verify-email-universal-link-design.md` (this repo).

## Global Constraints

- **Two repos.** Web tasks run in `~/dev/jetledger`. iOS tasks run in `~/dev/jetledger-ios/JetLedger`. Each task states which. Never mix the two in one commit.
- **Deploy order:** the web AASA change must be live before an iOS build carrying `applinks:` is installed. Task order in this plan already reflects that.
- **Apple Team ID / app ID:** `6KA5FYDT3Q.io.jetledger.JetLedger` — copy verbatim, it must match the existing `webcredentials` entry.
- **Claimed path is exactly `/verify-email/*`.** `/signup`, `/forgot-password`, `/terms` and `/privacy` must NOT be claimed — the app opens those itself in `SafariView`.
- **API error strings are contract, matched exactly** (the codebase already does this for `terms_acceptance_required`): `invalid_or_expired`, `invalid_request`, `internal`.
- **iOS deployment target is 17.6.** No iOS 18+ API, no renamed-in-18 SF Symbols.
- **All Swift types are implicitly `@MainActor`** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
- **Web test command:** `go test ./...` from `~/dev/jetledger`. No secrets or Docker needed.
- **iOS test command:** must use an iOS 26.x runtime, and `xcodebuild test` exits 0 on failures that happen before any test runs — always assert on the log:
  ```sh
  xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tail -40
  ```
  Success means the string `** TEST SUCCEEDED **` appears. Exit code alone proves nothing.

## File Structure

**Web repo (`~/dev/jetledger`):**

| File | Responsibility |
|------|----------------|
| `api/verify_email.go` (create) | The JSON endpoint handler. One exported method, `(*API).VerifyEmail`. |
| `api/verify_email_test.go` (create) | Handler tests: happy path, reuse, unknown token, malformed body. |
| `main.go` (modify) | AASA payload as a testable const; route registration. |
| `main_test.go` (create) | Pins the AASA payload's shape and path scope. |
| `docs/ios-api.md` (modify) | Contract documentation for the new endpoint. |

**iOS repo (`~/dev/jetledger-ios/JetLedger`):**

| File | Responsibility |
|------|----------------|
| `JetLedger/Utilities/VerificationLink.swift` (create) | Parses a tapped URL into a validated token. Pure, no dependencies, fully testable. |
| `JetLedger/Utilities/Constants.swift` (modify) | `WebAPI.authVerifyEmail` path; `Links.siteHost`. |
| `JetLedger/Services/AuthService.swift` (modify) | `verifyEmail(token:)` + the pure status→outcome mapper it delegates to. |
| `JetLedger/Views/Auth/EmailVerificationView.swift` (create) | The three-state sheet. |
| `JetLedger/JetLedgerApp.swift` (modify) | `.onOpenURL` routing and sheet presentation. |
| `JetLedger/JetLedger.entitlements` (modify) | `applinks:jetledger.io`. |
| `JetLedgerTests/VerificationLinkTests.swift` (create) | Parser and outcome-mapper tests. |

`VerificationLink` is deliberately its own file rather than a helper inside `Constants` or the view: it is the only piece of this feature with branching logic that can be tested without a simulator interaction, and both the app entry point and the tests consume it.

---

## Task 1: `POST /api/auth/verify-email` endpoint

**Repo:** `~/dev/jetledger` (web)

**Files:**
- Create: `api/verify_email.go`
- Create: `api/verify_email_test.go`
- Modify: `main.go:948` area (route registration)
- Modify: `docs/ios-api.md`

**Interfaces:**
- Consumes: `(*API).Shared` (`*shareddb.Queries`), `services.HashToken(string) string`, `writeJSON`, `writeError`, `nullStr` (all existing in package `api`).
- Produces: `func (a *API) VerifyEmail(w http.ResponseWriter, r *http.Request)`. Wire contract: request `{"token": "..."}`; `200 {"verified": true}`; `400 {"error":"invalid_or_expired"}`; `400 {"error":"invalid_request"}`; `500 {"error":"internal"}`. Task 4 (iOS) matches these strings exactly.

**Background the implementer needs:**

`GetEmailVerificationByTokenHash` already filters on `expires_at > datetime('now')` (`internal/db/shareddb/email_verifications.sql.go:46`). An expired token, a consumed token, and a nonexistent token are therefore all the same `sql.ErrNoRows`. Collapsing them into one 400 is not laziness — distinguishing them would let an unauthenticated caller probe token state.

This is a POST because `GET /verify-email/{token}` deliberately does not mutate: mail scanners prefetch links, and a prefetch must not burn the token (see the comment at `handlers/verify_email.go:22`). Do not add a GET variant.

- [ ] **Step 1: Write the failing test**

Create `api/verify_email_test.go`:

```go
package api

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"jetledger/internal/db/shareddb"
	"jetledger/services"
)

// seedAPIVerificationToken creates an email verification row and returns the
// raw token that would have been mailed to the user.
func seedAPIVerificationToken(t *testing.T, ts *testSetup, userID string, expiresIn time.Duration) string {
	t.Helper()
	raw, hashed, err := services.GenerateToken()
	require.NoError(t, err)
	require.NoError(t, ts.API.Shared.CreateEmailVerification(context.Background(), shareddb.CreateEmailVerificationParams{
		ID:        uuid.New().String(),
		UserID:    userID,
		TokenHash: hashed,
		ExpiresAt: time.Now().UTC().Add(expiresIn).Format("2006-01-02 15:04:05"),
	}))
	return raw
}

func apiEmailVerifiedAt(t *testing.T, ts *testSetup, userID string) sql.NullString {
	t.Helper()
	var v sql.NullString
	require.NoError(t, ts.SharedDB.QueryRow(
		`SELECT email_verified_at FROM profiles WHERE user_id = ?`, userID).Scan(&v))
	return v
}

func TestVerifyEmail_HappyPath(t *testing.T) {
	ts := newTestAPI(t)
	userID, _ := createTestUser(t, ts.SharedDB, "verify@example.com", "admin")
	raw := seedAPIVerificationToken(t, ts, userID, time.Hour)

	w := httptest.NewRecorder()
	r := jsonReq(t, http.MethodPost, "/api/auth/verify-email", verifyEmailRequest{Token: raw})
	ts.API.VerifyEmail(w, r)

	assert.Equal(t, http.StatusOK, w.Code)

	var resp map[string]bool
	parseJSON(t, w, &resp)
	assert.True(t, resp["verified"])

	assert.True(t, apiEmailVerifiedAt(t, ts, userID).Valid)

	// Token consumed, so the link cannot be replayed.
	var remaining int
	require.NoError(t, ts.SharedDB.QueryRow(
		`SELECT COUNT(*) FROM email_verifications WHERE user_id = ?`, userID).Scan(&remaining))
	assert.Equal(t, 0, remaining)
}

// A second tap on the same link is the single most likely error the iOS app
// will show, so it must produce the contract string the client matches on.
func TestVerifyEmail_ReusedTokenIsInvalid(t *testing.T) {
	ts := newTestAPI(t)
	userID, _ := createTestUser(t, ts.SharedDB, "reuse@example.com", "admin")
	raw := seedAPIVerificationToken(t, ts, userID, time.Hour)

	first := httptest.NewRecorder()
	ts.API.VerifyEmail(first, jsonReq(t, http.MethodPost, "/api/auth/verify-email", verifyEmailRequest{Token: raw}))
	require.Equal(t, http.StatusOK, first.Code)

	second := httptest.NewRecorder()
	ts.API.VerifyEmail(second, jsonReq(t, http.MethodPost, "/api/auth/verify-email", verifyEmailRequest{Token: raw}))

	assert.Equal(t, http.StatusBadRequest, second.Code)
	assert.Equal(t, "invalid_or_expired", parseErrorJSON(t, second))
}

func TestVerifyEmail_ExpiredTokenIsInvalid(t *testing.T) {
	ts := newTestAPI(t)
	userID, _ := createTestUser(t, ts.SharedDB, "expired@example.com", "admin")
	raw := seedAPIVerificationToken(t, ts, userID, -time.Hour)

	w := httptest.NewRecorder()
	ts.API.VerifyEmail(w, jsonReq(t, http.MethodPost, "/api/auth/verify-email", verifyEmailRequest{Token: raw}))

	assert.Equal(t, http.StatusBadRequest, w.Code)
	assert.Equal(t, "invalid_or_expired", parseErrorJSON(t, w))
	assert.False(t, apiEmailVerifiedAt(t, ts, userID).Valid)
}

func TestVerifyEmail_UnknownTokenIsInvalid(t *testing.T) {
	ts := newTestAPI(t)
	_, _ = createTestUser(t, ts.SharedDB, "unknown@example.com", "admin")

	w := httptest.NewRecorder()
	ts.API.VerifyEmail(w, jsonReq(t, http.MethodPost, "/api/auth/verify-email", verifyEmailRequest{Token: "not-a-real-token"}))

	assert.Equal(t, http.StatusBadRequest, w.Code)
	assert.Equal(t, "invalid_or_expired", parseErrorJSON(t, w))
}

// A missing token is a client bug, not a dead link — it must NOT return
// invalid_or_expired, or the app would tell a user their link expired when
// the app itself sent a malformed request.
func TestVerifyEmail_EmptyTokenIsInvalidRequest(t *testing.T) {
	ts := newTestAPI(t)

	w := httptest.NewRecorder()
	ts.API.VerifyEmail(w, jsonReq(t, http.MethodPost, "/api/auth/verify-email", verifyEmailRequest{Token: ""}))

	assert.Equal(t, http.StatusBadRequest, w.Code)
	assert.Equal(t, "invalid_request", parseErrorJSON(t, w))
}
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
cd ~/dev/jetledger && go test ./api/ -run TestVerifyEmail -v
```

Expected: compile failure — `undefined: verifyEmailRequest` and `ts.API.VerifyEmail undefined`.

- [ ] **Step 3: Write the handler**

Create `api/verify_email.go`:

```go
package api

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/google/uuid"

	"jetledger/internal/db/shareddb"
	"jetledger/services"
)

type verifyEmailRequest struct {
	Token string `json:"token"`
}

// VerifyEmail handles POST /api/auth/verify-email — the iOS half of the
// email-verification link. The app receives the link as a universal link
// (see the applinks block in the AASA payload) and redeems the token here
// instead of handing the user to Safari.
//
// Unauthenticated by design: the link may be tapped on a device that never
// had a session, and it is the token itself that authorizes the mutation.
//
// The mutations mirror handlers.VerifyEmailSubmit exactly. This is a POST,
// so the reason GET /verify-email/{token} does not mutate — mail scanners
// prefetch links and a prefetch must not burn the token — is preserved.
//
// A nonexistent, expired, or already-consumed token are one response:
// GetEmailVerificationByTokenHash already filters on expires_at, and
// distinguishing them would let an unauthenticated caller probe token state.
func (a *API) VerifyEmail(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	var req verifyEmailRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Token == "" {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}

	verification, err := a.Shared.GetEmailVerificationByTokenHash(ctx, services.HashToken(req.Token))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_or_expired")
		return
	}

	if err := a.Shared.SetEmailVerified(ctx, verification.UserID); err != nil {
		slog.ErrorContext(ctx, "marking email verified failed", "user_id", verification.UserID, "err", err)
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	if err := a.Shared.InvalidateEmailVerificationsForUser(ctx, verification.UserID); err != nil {
		slog.ErrorContext(ctx, "consuming verification tokens failed", "user_id", verification.UserID, "err", err)
	}

	if err := a.Shared.CreateAdminAuditLog(ctx, shareddb.CreateAdminAuditLogParams{
		ID:         uuid.New().String(),
		UserID:     verification.UserID,
		Action:     "email_verified",
		TargetType: nullStr("user"),
		TargetID:   nullStr(verification.UserID),
	}); err != nil {
		slog.ErrorContext(ctx, "audit log failed", "action", "email_verified", "err", err)
	}

	writeJSON(w, http.StatusOK, map[string]bool{"verified": true})
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```sh
cd ~/dev/jetledger && go test ./api/ -run TestVerifyEmail -v
```

Expected: all five tests PASS.

- [ ] **Step 5: Register the route**

In `main.go`, immediately after the `POST /api/auth/device-login` registration (currently line 954, the last of the unauthenticated `/api/auth/*` routes, just above the `// iOS API routes (Bearer token auth, JSON, no CSRF).` comment), add:

```go
	// Unauthenticated: the verify-email universal link may be tapped on a
	// device with no session. The token is the authorization.
	mux.Handle("POST /api/auth/verify-email", apiRL.RateLimitJSON(http.HandlerFunc(apiHandler.VerifyEmail)))
```

It must go **above** `apiAuth := mw.RequireAPIAuth()`. Registering it below would put it behind Bearer auth and break the whole feature.

- [ ] **Step 6: Document the contract**

Append to `docs/ios-api.md`, following the format of the existing endpoint sections:

```markdown
## Email verification from the app (2026-08-05)

`https://jetledger.io/verify-email/{token}` is claimed as an iOS universal
link (see the `applinks` block in `/.well-known/apple-app-site-association`),
so tapping the link in Mail opens the app rather than Safari. The app redeems
the token here.

### `POST /api/auth/verify-email`

**Unauthenticated** — the link may be tapped on a device that never had a
session, and the token itself is the authorization. Rate limited like login.

Request:

```json
{ "token": "<the {token} path segment from the link>" }
```

| Status | Body | Meaning |
|--------|------|---------|
| 200 | `{"verified": true}` | Token redeemed; the email is now verified |
| 400 | `{"error": "invalid_or_expired"}` | Token unknown, expired, or already consumed |
| 400 | `{"error": "invalid_request"}` | Missing or malformed body |
| 500 | `{"error": "internal"}` | Server failed to record verification |

The three "dead token" cases are deliberately one response: the lookup query
already filters on expiry, and splitting them would let an unauthenticated
caller probe token state. Clients match `invalid_or_expired` **exactly** and
must not treat `invalid_request` as a dead link — that one is a client bug.

Side effects are identical to the web form at `POST /verify-email/{token}`:
`email_verified_at` is set, all of the user's outstanding verification tokens
are invalidated, and an `email_verified` audit entry is written. The web page
is unchanged and remains the flow for desktop and for devices without the app.
```

- [ ] **Step 7: Run the full suite**

```sh
cd ~/dev/jetledger && go test ./...
```

Expected: all packages PASS. If `go vet` runs in CI, run `go vet ./...` too.

- [ ] **Step 8: Commit**

```bash
cd ~/dev/jetledger
git add api/verify_email.go api/verify_email_test.go main.go docs/ios-api.md
git commit -m "$(cat <<'EOF'
feat(api): add POST /api/auth/verify-email for the iOS app

The verification link is tapped in Mail, so the iOS app needs to redeem the
token itself rather than hand the user to Safari. Same three mutations as the
HTML form handler, in JSON, unauthenticated because the link may open on a
device that never had a session.

Kept as a POST so the reason the GET page does not mutate — mail scanners
prefetch links and must not burn the token — still holds.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Claim `/verify-email/*` in the AASA payload

**Repo:** `~/dev/jetledger` (web)

**Files:**
- Modify: `main.go:521-525` (the `/.well-known/apple-app-site-association` handler)
- Create: `main_test.go`

**Interfaces:**
- Produces: `const appSiteAssociation string` in package `main` — the served JSON payload. Nothing else consumes it in Go; iOS consumes it over HTTPS.

**Background the implementer needs:**

The endpoint already exists and currently serves only a `webcredentials` block (Apple Passwords autofill). That block must survive verbatim — removing it silently breaks password autofill on the sign-in screen.

The payload is currently an inline byte-slice literal inside a closure, which is untestable. Extracting it to a package-level const is the change that makes the path scope assertable, which is the part worth guarding: claiming `/signup` or `/terms` would make the app hijack links it opens in its own in-app browser.

- [ ] **Step 1: Write the failing test**

Create `main_test.go`:

```go
package main

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const jetLedgerAppID = "6KA5FYDT3Q.io.jetledger.JetLedger"

type aasaPayload struct {
	Applinks struct {
		Details []struct {
			AppIDs     []string            `json:"appIDs"`
			Components []map[string]string `json:"components"`
		} `json:"details"`
	} `json:"applinks"`
	Webcredentials struct {
		Apps []string `json:"apps"`
	} `json:"webcredentials"`
}

func parseAASA(t *testing.T) aasaPayload {
	t.Helper()
	var p aasaPayload
	require.NoError(t, json.Unmarshal([]byte(appSiteAssociation), &p),
		"AASA payload must be valid JSON — iOS silently ignores a malformed one")
	return p
}

// Apple Passwords autofill on the iOS sign-in screen depends on this block.
// Adding applinks must not disturb it.
func TestAASAKeepsWebcredentials(t *testing.T) {
	p := parseAASA(t)
	assert.Equal(t, []string{jetLedgerAppID}, p.Webcredentials.Apps)
}

func TestAASAClaimsVerifyEmail(t *testing.T) {
	p := parseAASA(t)
	require.Len(t, p.Applinks.Details, 1)
	assert.Equal(t, []string{jetLedgerAppID}, p.Applinks.Details[0].AppIDs)
	require.Len(t, p.Applinks.Details[0].Components, 1)
	assert.Equal(t, "/verify-email/*", p.Applinks.Details[0].Components[0]["/"])
}

// The path scope is load-bearing. The iOS app opens /signup,
// /forgot-password, /terms and /privacy in its own SFSafariViewController;
// claiming them here would make the app fight its own links.
func TestAASADoesNotClaimInAppBrowserPages(t *testing.T) {
	p := parseAASA(t)
	for _, detail := range p.Applinks.Details {
		for _, component := range detail.Components {
			pattern := component["/"]
			for _, forbidden := range []string{"/signup", "/forgot-password", "/terms", "/privacy", "*"} {
				assert.NotEqual(t, forbidden, pattern,
					"AASA must not claim %s — the app opens it in SafariView", forbidden)
			}
		}
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
cd ~/dev/jetledger && go test . -run TestAASA -v
```

Expected: compile failure — `undefined: appSiteAssociation`.

- [ ] **Step 3: Extract and extend the payload**

In `main.go`, add above the `main` function (or beside the other package-level declarations):

```go
// appSiteAssociation is served at /.well-known/apple-app-site-association.
//
// applinks claims https://jetledger.io/verify-email/* as an iOS universal
// link, so tapping a verification link in Mail opens JetLedger instead of
// Safari. The path scope is deliberately narrow: the app opens /signup,
// /forgot-password, /terms and /privacy in its own SFSafariViewController,
// and claiming those would make it hijack links it is already showing.
//
// webcredentials backs Apple Passwords autofill on the iOS sign-in screen
// and predates applinks — do not drop it.
//
// Shape is pinned by main_test.go. Apple CDN-caches this file, so a change
// here does not reach installed devices immediately.
const appSiteAssociation = `{"applinks":{"details":[{"appIDs":["6KA5FYDT3Q.io.jetledger.JetLedger"],"components":[{"/":"/verify-email/*"}]}]},"webcredentials":{"apps":["6KA5FYDT3Q.io.jetledger.JetLedger"]}}`
```

Then replace the handler body at `main.go:522-525` with:

```go
	// Apple app-site association: universal links (applinks) + Passwords
	// autofill (webcredentials). Must be HTTPS, unauthenticated, no redirect.
	mux.HandleFunc("GET /.well-known/apple-app-site-association", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(appSiteAssociation))
	})
```

- [ ] **Step 4: Run the tests to verify they pass**

```sh
cd ~/dev/jetledger && go test . -run TestAASA -v && go test ./...
```

Expected: the three AASA tests PASS and the full suite stays green.

- [ ] **Step 5: Commit**

```bash
cd ~/dev/jetledger
git add main.go main_test.go
git commit -m "$(cat <<'EOF'
feat: claim /verify-email/* as an iOS universal link

Adds an applinks block to the AASA payload so a verification link tapped in
Mail opens the app instead of Safari. Scope is exactly /verify-email/* —
/signup, /forgot-password, /terms and /privacy are opened by the app in its
own SFSafariViewController and must not be claimed.

Payload extracted to a const so the path scope and the surviving
webcredentials block are covered by tests.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: Deploy the web app and verify the live payload**

Deploy however this repo normally deploys, then:

```sh
curl -sI https://jetledger.io/.well-known/apple-app-site-association
curl -s  https://jetledger.io/.well-known/apple-app-site-association
```

Expected: `HTTP/2 200`, `content-type: application/json`, **no redirect** (no 301/302 in the headers), and a body containing both `applinks` and `webcredentials`. iOS rejects a redirected or non-JSON AASA silently.

**Do not start Task 6 until this step passes** — an iOS build claiming `applinks:` against an AASA without the block will simply keep opening Safari.

---

## Task 3: `VerificationLink` URL parser (iOS)

**Repo:** `~/dev/jetledger-ios/JetLedger`

**Files:**
- Create: `JetLedger/Utilities/VerificationLink.swift`
- Create: `JetLedgerTests/VerificationLinkTests.swift`
- Modify: `JetLedger/Utilities/Constants.swift`

**Interfaces:**
- Consumes: `AppConstants.Links` (existing).
- Produces:
  - `AppConstants.WebAPI.authVerifyEmail: String` = `"/api/auth/verify-email"` — used by Task 4.
  - `AppConstants.Links.siteHost: String?` — the host of the canonical site URL.
  - `nonisolated struct VerificationLink: Identifiable` with `let token: String`, `let url: URL`, `var id: String`, and failable `init?(url: URL)` — used by Tasks 5 and 6.

**Background the implementer needs:**

`AppConstants.Links.site` is `private static let site = URL(string: "https://jetledger.io")!` at `Constants.swift:83`. Every other link derives from it so a domain change is one edit; the host must derive from it too rather than being retyped.

**Isolation matters here and the two rules below are not interchangeable.** The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so everything is `@MainActor` unless it opts out:

- `siteHost` must be a **stored `static let`**, not a computed `static var`. An immutable `static let` of a `Sendable` type is reachable from nonisolated contexts — which is why `LegalLinksTests` can read `AppConstants.Links.privacy` without annotation. A computed `var` would be MainActor-isolated and would break both the parser and its tests.
- `VerificationLink` is declared `nonisolated`, following `nonisolated enum ServerDateFormatter` (`Utilities/ServerDateFormatter.swift:14`) — the codebase's established pattern for a pure value utility. This is what lets its test suite skip `@MainActor` entirely, and MainActor code (the view, the app entry point) can always reach nonisolated members.

`VerificationLink` is `Identifiable` because `.sheet(item:)` requires it — the same reason `WebLink` is (`Components/SafariView.swift:34`).

`URL.host()` (with parens) is the iOS 16+ replacement for the deprecated `host` property; the deployment target is 17.6, so it is available.

- [ ] **Step 1: Write the failing test**

Create `JetLedgerTests/VerificationLinkTests.swift`:

```swift
//
//  VerificationLinkTests.swift
//  JetLedgerTests
//
//  The parser stands between a tapped universal link and a POST that mutates
//  account state, so it is the one piece of this feature worth testing without
//  a device. A too-loose match would let any jetledger.io link open the
//  verification sheet; a too-tight one silently drops real verifications back
//  to "nothing happened" when the app opens.
//

import Testing
import Foundation
@testable import JetLedger

@Suite
struct VerificationLinkTests {

    @Test
    func parsesTokenFromACanonicalVerifyLink() {
        let link = VerificationLink(url: URL(string: "https://jetledger.io/verify-email/abc123XYZ")!)
        #expect(link?.token == "abc123XYZ")
    }

    @Test
    func keepsTheOriginalURLForTheBrowserFallback() {
        let url = URL(string: "https://jetledger.io/verify-email/abc123XYZ")!
        #expect(VerificationLink(url: url)?.url == url)
    }

    @Test
    func rejectsAnotherHost() {
        #expect(VerificationLink(url: URL(string: "https://evil.example.com/verify-email/abc123")!) == nil)
    }

    @Test
    func rejectsPlainHTTP() {
        #expect(VerificationLink(url: URL(string: "http://jetledger.io/verify-email/abc123")!) == nil)
    }

    /// The other jetledger.io pages the app links to must never route through
    /// the verification sheet — they open in SafariView.
    @Test
    func rejectsTheInAppBrowserPages() {
        #expect(VerificationLink(url: AppConstants.Links.signup) == nil)
        #expect(VerificationLink(url: AppConstants.Links.terms) == nil)
        #expect(VerificationLink(url: AppConstants.Links.privacy) == nil)
        #expect(VerificationLink(url: AppConstants.Links.forgotPassword) == nil)
    }

    @Test
    func rejectsAMissingToken() {
        #expect(VerificationLink(url: URL(string: "https://jetledger.io/verify-email/")!) == nil)
        #expect(VerificationLink(url: URL(string: "https://jetledger.io/verify-email")!) == nil)
    }

    /// A trailing segment means the link is not the one we issued; redeeming
    /// the middle segment would be guessing.
    @Test
    func rejectsExtraPathSegments() {
        #expect(VerificationLink(url: URL(string: "https://jetledger.io/verify-email/abc123/extra")!) == nil)
    }

    @Test
    func identityFollowsTheToken() {
        let a = VerificationLink(url: URL(string: "https://jetledger.io/verify-email/abc123")!)
        let b = VerificationLink(url: URL(string: "https://jetledger.io/verify-email/abc123")!)
        let c = VerificationLink(url: URL(string: "https://jetledger.io/verify-email/different")!)
        #expect(a?.id == b?.id)
        #expect(a?.id != c?.id)
    }

    @Test
    func verifyEndpointResolvesToItsPublishedRoute() {
        #expect(AppConstants.WebAPI.authVerifyEmail == "/api/auth/verify-email")
    }

    @Test
    func siteHostIsDerivedFromTheCanonicalSiteURL() {
        #expect(AppConstants.Links.siteHost == "jetledger.io")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```sh
cd ~/dev/jetledger-ios/JetLedger
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tail -40
```

Expected: build failure — `cannot find 'VerificationLink' in scope`. The string `** TEST SUCCEEDED **` must NOT appear.

- [ ] **Step 3: Add the constants**

In `JetLedger/Utilities/Constants.swift`, inside `enum WebAPI`, after the `authDeviceLogin` line (line 43):

```swift
        static let authVerifyEmail = "/api/auth/verify-email"
```

And inside `enum Links`, after the `forgotPassword` line (line 99):

```swift
        /// Host of the canonical site, for matching incoming universal links.
        /// Derived from `site` so a domain change stays a one-line edit.
        ///
        /// A stored `let`, not a computed `var`: an immutable Sendable static
        /// is reachable from nonisolated code, which `VerificationLink` is.
        static let siteHost: String? = site.host()
```

- [ ] **Step 4: Write the parser**

Create `JetLedger/Utilities/VerificationLink.swift`:

```swift
//
//  VerificationLink.swift
//  JetLedger
//
//  A tapped email-verification universal link, parsed and validated.
//
//  The verification link arrives in Mail, not in the app, so the in-app
//  SFSafariViewController from signup is long gone by the time the user taps
//  it. A universal link is the only mechanism that can route an https:// URL
//  back into an installed app — the app claims https://jetledger.io/verify-email/*
//  via the applinks block in the web app's AASA payload.
//
//  Validation is strict on purpose. This value is the sole gate between an
//  arbitrary inbound URL and a POST that mutates account state, and a loose
//  match would route the pages the app opens in SafariView (/signup, /terms,
//  /privacy, /forgot-password) into the verification sheet instead.
//

import Foundation

/// nonisolated, like `ServerDateFormatter`: a pure value type with no state,
/// parsed from a URL on the main actor but usable from anywhere.
nonisolated struct VerificationLink: Identifiable {
    /// The raw token from the link's path — redeemed via
    /// `AuthService.verifyEmail(token:)`.
    let token: String

    /// The original URL, kept for the expired-link fallback: the web page at
    /// this address carries the real error copy and the resend affordance.
    let url: URL

    /// Identity keys the `.sheet(item:)` presentation, the same way `WebLink`'s
    /// does. Two taps on the same link are the same sheet.
    var id: String { token }

    /// Returns nil for anything that is not a verification link this app issued.
    init?(url: URL) {
        guard url.scheme == "https",
              let host = url.host(),
              host == AppConstants.Links.siteHost
        else { return nil }

        // ["/", "verify-email", "<token>"] — anything else is not our link.
        let components = url.pathComponents
        guard components.count == 3,
              components[1] == "verify-email",
              !components[2].isEmpty
        else { return nil }

        self.token = components[2]
        self.url = url
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```sh
cd ~/dev/jetledger-ios/JetLedger
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **` appears in the output. If it does not, the task is not done regardless of exit code.

- [ ] **Step 6: Commit**

```bash
cd ~/dev/jetledger-ios/JetLedger
git add JetLedger/Utilities/VerificationLink.swift JetLedger/Utilities/Constants.swift JetLedgerTests/VerificationLinkTests.swift
git commit -m "$(cat <<'EOF'
feat: parse verify-email universal links

VerificationLink is the gate between an arbitrary inbound URL and a POST that
mutates account state, so it matches scheme, host, and the exact three-segment
path shape. The pages the app opens in SafariView must never route through it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `AuthService.verifyEmail(token:)`

**Repo:** `~/dev/jetledger-ios/JetLedger`

**Files:**
- Modify: `JetLedger/Services/AuthService.swift`
- Modify: `JetLedgerTests/VerificationLinkTests.swift` (add a suite)

**Interfaces:**
- Consumes: `AppConstants.WebAPI.authVerifyEmail` (Task 3); `apiClient.performRawRequest(_:_:bodyData:) async throws -> (Data, Int)`; `APIClient.encoder`; the private `AuthService.errorString(from:)` at `AuthService.swift:547`.
- Produces:
  - `enum AuthService.EmailVerificationOutcome: Equatable { case verified, invalidOrExpired, failed(message: String) }`
  - `static func AuthService.verificationOutcome(status: Int, data: Data) -> EmailVerificationOutcome` (internal, so `@testable` can reach it)
  - `func verifyEmail(token: String) async -> EmailVerificationOutcome`
  - Used by Task 5.

**Background the implementer needs:**

`AuthService.init()` builds its own `APIClient` against the real base URL with no injection point, so `verifyEmail` cannot be driven end-to-end from a unit test without changing that initializer. Don't change it. Instead the decision logic — mapping an HTTP status plus body to an outcome — lives in a pure static function that tests call directly. The network round-trip around it is four lines with no branching beyond "did it throw".

`errorString(from:)` is `private static`, which `@testable import` cannot reach — but `verificationOutcome` is in the same type, so it can call it. Only `verificationOutcome` needs to be internal.

Follow `acceptCurrentTerms` (`AuthService.swift:129-190`) for shape: `performRawRequest` rather than `request()`, because the error body must be readable.

Note that `performRawRequest` calls `addHeaders`, which attaches a `Bearer` token if one exists. That is harmless — the endpoint is unauthenticated and ignores it — and it keeps this call on the same path as every other request.

- [ ] **Step 1: Write the failing test**

Append to `JetLedgerTests/VerificationLinkTests.swift`:

```swift
/// The status→outcome mapping is the whole decision this feature makes on a
/// server response, and it is worth pinning independently of the network:
/// a 400 that means "your link is dead" and a 400 that means "the app sent a
/// malformed request" must never show the same thing to the user.
///
/// Each test is `@MainActor` because `AuthService` is — the same convention
/// `TermsContractTests` uses for tests that touch MainActor-isolated types.
@Suite
struct EmailVerificationOutcomeTests {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    @Test
    @MainActor
    func successVerifies() {
        let outcome = AuthService.verificationOutcome(status: 200, data: body(#"{"verified":true}"#))
        #expect(outcome == .verified)
    }

    @Test
    @MainActor
    func deadTokenIsInvalidOrExpired() {
        let outcome = AuthService.verificationOutcome(status: 400, data: body(#"{"error":"invalid_or_expired"}"#))
        #expect(outcome == .invalidOrExpired)
    }

    /// A client-side bug must not be reported to the user as an expired link.
    @Test
    @MainActor
    func malformedRequestIsNotReportedAsAnExpiredLink() {
        let outcome = AuthService.verificationOutcome(status: 400, data: body(#"{"error":"invalid_request"}"#))
        #expect(outcome != .invalidOrExpired)
        if case .failed = outcome {} else {
            Issue.record("invalid_request should map to .failed, got \(outcome)")
        }
    }

    /// Matched exactly, like the terms 403 backstop — a substring match would
    /// let an unrelated error containing the phrase read as a dead link.
    @Test
    @MainActor
    func unrecognizedFourHundredIsNotInvalidOrExpired() {
        let outcome = AuthService.verificationOutcome(status: 400, data: body(#"{"error":"invalid_or_expired_something_else"}"#))
        #expect(outcome != .invalidOrExpired)
    }

    @Test
    @MainActor
    func serverErrorSurfacesTheServerMessage() {
        let outcome = AuthService.verificationOutcome(status: 500, data: body(#"{"error":"internal"}"#))
        #expect(outcome == .failed(message: "internal"))
    }

    @Test
    @MainActor
    func unreadableBodyStillFailsCleanly() {
        let outcome = AuthService.verificationOutcome(status: 503, data: body("<html>gateway</html>"))
        if case .failed = outcome {} else {
            Issue.record("an unreadable body should still map to .failed, got \(outcome)")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```sh
cd ~/dev/jetledger-ios/JetLedger
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tail -40
```

Expected: build failure — `type 'AuthService' has no member 'verificationOutcome'`.

- [ ] **Step 3: Implement**

In `JetLedger/Services/AuthService.swift`, add after the `acceptCurrentTerms` implementation (after line 190, before the `// MARK: - Session Restore` comment):

```swift
    // MARK: - Email Verification

    enum EmailVerificationOutcome: Equatable {
        case verified
        /// The token is unknown, expired, or already redeemed — the server
        /// collapses all three, because its lookup filters on expiry and
        /// splitting them would let a caller probe token state.
        case invalidOrExpired
        case failed(message: String)
    }

    /// Maps a verify-email response to an outcome. Pure and separate from the
    /// round-trip so the one decision this makes is testable: a 400 meaning
    /// "your link is dead" and a 400 meaning "the app sent a bad request" must
    /// not reach the user as the same message.
    static func verificationOutcome(status: Int, data: Data) -> EmailVerificationOutcome {
        switch status {
        case 200:
            return .verified
        case 400 where errorString(from: data) == "invalid_or_expired":
            // Matched exactly, like the terms 403 backstop — this string is
            // contract (docs/ios-api.md in the jetledger repo), not a hint.
            return .invalidOrExpired
        default:
            return .failed(message: errorString(from: data) ?? "Something went wrong. Please try again.")
        }
    }

    /// Redeems an email-verification token tapped as a universal link.
    ///
    /// Creates no session and changes no auth state: this is a token
    /// redemption, not a sign-in. The user may not be signed in at all, and
    /// the endpoint is unauthenticated for exactly that reason.
    func verifyEmail(token: String) async -> EmailVerificationOutcome {
        let bodyData: Data
        do {
            bodyData = try APIClient.encoder.encode(EmailVerifyRequest(token: token))
        } catch {
            return .failed(message: "Something went wrong. Please try again.")
        }

        do {
            let (data, httpStatus) = try await apiClient.performRawRequest(
                .post, AppConstants.WebAPI.authVerifyEmail, bodyData: bodyData
            )
            return Self.verificationOutcome(status: httpStatus, data: data)
        } catch {
            // A transport failure is not a dead link — say so, so a user on a
            // bad connection retries instead of assuming their link expired.
            return .failed(message: "Unable to connect. Check your internet connection and try again.")
        }
    }
```

And add alongside the other private DTOs at the end of the file, next to `TermsAcceptRequest` (line 895):

```swift
private struct EmailVerifyRequest: Encodable {
    let token: String
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```sh
cd ~/dev/jetledger-ios/JetLedger
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **` in the output.

- [ ] **Step 5: Commit**

```bash
cd ~/dev/jetledger-ios/JetLedger
git add JetLedger/Services/AuthService.swift JetLedgerTests/VerificationLinkTests.swift
git commit -m "$(cat <<'EOF'
feat: redeem email-verification tokens from AuthService

verifyEmail(token:) posts to the unauthenticated /api/auth/verify-email and
creates no session — this is a token redemption, not a sign-in.

The status-to-outcome mapping is a pure static so it can be tested without a
network: a 400 meaning "your link is dead" and a 400 meaning "the app sent a
bad request" must not reach the user as the same message, and a transport
failure must not read as an expired link at all.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `EmailVerificationView`

**Repo:** `~/dev/jetledger-ios/JetLedger`

**Files:**
- Create: `JetLedger/Views/Auth/EmailVerificationView.swift`

**Interfaces:**
- Consumes: `VerificationLink` (Task 3); `AuthService.verifyEmail(token:)` and `EmailVerificationOutcome` (Task 4); `WebLink` / `safariSheet(_:)` (`Components/SafariView.swift`).
- Produces: `struct EmailVerificationView: View` with `init(link: VerificationLink)` — presented by Task 6.

**Background the implementer needs:**

Style reference is `Views/Terms/TermsGateView.swift`: centered `VStack(spacing: 24)`, an SF Symbol at `.font(.system(size: 44))` tinted `Color.accentColor`, `.title2.bold()` headline, `.subheadline` secondary body, prominent button in `Color(.brandPrimary)` with white content.

**Colors follow the project's two-token rule** (CLAUDE.md § Design): global tint uses `AccentColor`; a filled surface under white text uses `BrandPrimary`. Status colors are the existing colorsets — `Color(.statusSuccess)`, `Color(.statusWarning)`, `Color(.statusError)`.

**Deployment target is 17.6** — use `checkmark.circle.fill` and `exclamationmark.triangle.fill`, both long-available. Do not use symbols renamed in iOS 18.

The view runs its verification once on appear via `.task`, which does not re-fire on redraw.

- [ ] **Step 1: Create the view**

Create `JetLedger/Views/Auth/EmailVerificationView.swift`:

```swift
//
//  EmailVerificationView.swift
//  JetLedger
//
//  Shown when the user taps their email-verification link and iOS routes it
//  here as a universal link. It redeems the token natively rather than opening
//  the web page: the point of claiming the link at all is that the user stops
//  being handed to Safari at the one moment they are least oriented.
//
//  The expired state does open the web page — in the in-app SafariView — because
//  that page already carries the real error copy and the resend affordance, and
//  a native dead end would be worse than a browser that stays inside the app.
//
//  Transport failure is deliberately a separate state from expired. Telling
//  someone on a bad connection that their link is dead sends them looking for a
//  new email that will never help.
//

import SwiftUI

struct EmailVerificationView: View {
    let link: VerificationLink

    @Environment(AuthService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case verifying
        case verified
        case expired
        case failed(message: String)
    }

    @State private var phase: Phase = .verifying
    @State private var webLink: WebLink?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            switch phase {
            case .verifying:
                ProgressView()
                    .controlSize(.large)
                Text("Verifying your email…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .verified:
                icon("checkmark.circle.fill", color: Color(.statusSuccess))
                headline("Email verified", detail: "You're all set. You can sign in now.")

            case .expired:
                icon("exclamationmark.triangle.fill", color: Color(.statusWarning))
                headline(
                    "Link expired",
                    detail: "This verification link has expired or was already used."
                )

            case .failed(let message):
                icon("exclamationmark.triangle.fill", color: Color(.statusError))
                headline("Couldn't verify", detail: message)
            }

            Spacer()

            actions
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .safariSheet($webLink)
        .task {
            phase = await verify()
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            switch phase {
            case .verifying:
                EmptyView()

            case .verified:
                primaryButton("Continue") { dismiss() }

            case .expired:
                // The web page owns the real error copy and the resend path.
                primaryButton("Open in browser") { webLink = WebLink(link.url) }
                Button("Dismiss") { dismiss() }

            case .failed:
                primaryButton("Try Again") {
                    phase = .verifying
                    Task { phase = await verify() }
                }
                Button("Dismiss") { dismiss() }
            }
        }
    }

    private func verify() async -> Phase {
        switch await authService.verifyEmail(token: link.token) {
        case .verified:
            return .verified
        case .invalidOrExpired:
            return .expired
        case .failed(let message):
            return .failed(message: message)
        }
    }

    // MARK: - Pieces

    private func icon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 44))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private func headline(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title2.bold())
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(.brandPrimary))
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```sh
cd ~/dev/jetledger-ios/JetLedger
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```

Expected: `BUILD SUCCEEDED`. The four colorsets used here — `BrandPrimary`, `StatusSuccess`, `StatusWarning`, `StatusError` — all exist in `Assets.xcassets` and are already used elsewhere in the app (`SyncStatusBadge.swift:68`, `TermsGateView.swift:120`).

- [ ] **Step 3: Run the test suite to confirm nothing regressed**

```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd ~/dev/jetledger-ios/JetLedger
git add JetLedger/Views/Auth/EmailVerificationView.swift
git commit -m "$(cat <<'EOF'
feat: add the email-verification sheet

Verifies natively on appear. The expired state hands off to the web page in
the in-app SafariView, which already carries the real error copy and the
resend path — a native dead end would be worse than a browser that stays
inside the app.

Transport failure is a separate, retryable state: telling someone on a bad
connection that their link is dead sends them hunting for a new email.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Entitlement and link routing

**Repo:** `~/dev/jetledger-ios/JetLedger`

**Files:**
- Modify: `JetLedger/JetLedger.entitlements`
- Modify: `JetLedger/JetLedgerApp.swift`

**Interfaces:**
- Consumes: `VerificationLink` (Task 3), `EmailVerificationView` (Task 5).
- Produces: nothing consumed by later tasks. This is the wiring that makes the feature live.

**Prerequisite:** Task 2 Step 6 must have passed — the live AASA must already carry the `applinks` block.

**Background the implementer needs:**

`applinks:` is **added to** the existing `com.apple.developer.associated-domains` array. Do not replace `webcredentials:jetledger.io` — that backs Apple Passwords autofill on the sign-in screen.

The sheet is attached to the `WindowGroup` content (alongside the existing `.alert` modifiers around `JetLedgerApp.swift:82-115`), not inside `rootView`'s switch. `rootView` is a `@ViewBuilder` switch over `authState`; attaching there would mean repeating the modifier in every branch and losing the sheet across state transitions. Attached at the top it works identically from `.unauthenticated`, `.authenticated` and `.offlineReady`, and it presents *above* the `TermsGateView` ZStack layer without bypassing the gate — verification is not a gated action.

The app uses `@UIApplicationDelegateAdaptor`, but `AppDelegate` does not implement `application(_:continue:restorationHandler:)`, so SwiftUI's `onOpenURL` receives universal links. Do not add that delegate method — it would intercept them.

- [ ] **Step 1: Add the entitlement**

In `JetLedger/JetLedger.entitlements`, extend the associated-domains array (currently lines 7-10):

```xml
	<key>com.apple.developer.associated-domains</key>
	<array>
		<string>webcredentials:jetledger.io</string>
		<string>applinks:jetledger.io</string>
	</array>
```

- [ ] **Step 2: Add the state and routing**

In `JetLedger/JetLedgerApp.swift`, add to the `@State` declarations (after `showBiometricPrompt` at line 31):

```swift
    // A verification link tapped in Mail, routed here as a universal link.
    @State private var verificationLink: VerificationLink?
```

Then attach to the `WindowGroup` content, immediately after the existing `.alert("Different Account", ...)` block and its `message:` closure (after line 115, before the closing brace of the `WindowGroup`):

```swift
            .onOpenURL { url in
                // Universal links arrive here (AppDelegate deliberately does
                // not implement continueUserActivity, which would intercept
                // them). Anything that is not a verification link is ignored:
                // the app claims only /verify-email/* in its AASA, and the
                // pages it opens itself go through SafariView.
                if let link = VerificationLink(url: url) {
                    verificationLink = link
                }
            }
            .sheet(item: $verificationLink) { link in
                // A sheet, not a root-view swap: it presents identically from
                // every authState and cannot strand a user mid-capture. It
                // also sits above the TermsGateView layer without bypassing
                // it — verification is not a gated action.
                EmailVerificationView(link: link)
                    .environment(authService)
            }
```

- [ ] **Step 3: Build**

```sh
cd ~/dev/jetledger-ios/JetLedger
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the test suite**

```sh
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=D13D970E-2F18-4017-9205-321368BA87B3' test 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Smoke-test routing in the simulator**

The simulator honors universal links from `xcrun simctl openurl` once the app is installed and the AASA has been fetched. Install the build, then:

```sh
xcrun simctl openurl booted "https://jetledger.io/verify-email/not-a-real-token"
```

Expected: JetLedger comes to the front and shows the verifying state, then the **Link expired** state (the token is fake). If Safari opens instead, the association has not been picked up — that is expected on a simulator without a fresh install, and is resolved by the device testing in Task 7 rather than by changing code here.

Then confirm the in-app browser pages are NOT hijacked:

```sh
xcrun simctl openurl booted "https://jetledger.io/terms"
```

Expected: Safari opens the page. JetLedger must **not** come to the front.

- [ ] **Step 6: Commit**

```bash
cd ~/dev/jetledger-ios/JetLedger
git add JetLedger/JetLedger.entitlements JetLedger/JetLedgerApp.swift
git commit -m "$(cat <<'EOF'
feat: route tapped verification links into the app

Claims applinks:jetledger.io alongside the existing webcredentials entry and
presents the verification sheet on a matching onOpenURL.

Attached to the WindowGroup rather than inside rootView's authState switch:
it then presents identically whether the user is signed in, signed out, or in
offline mode, and sits above the terms gate layer without bypassing it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Device verification

**Repo:** both. No code changes unless a step fails.

**Files:** none (temporarily `JetLedger/JetLedger.entitlements` for the developer-mode step).

This task is manual and cannot be automated. The universal-link handoff involves Apple's CDN, Mail, and the OS association cache — none of which are reachable from a test target.

**Background the implementer needs:**

Apple CDN-caches the AASA at `app-site-association.cdn-apple.com`, and the association is fetched at install/first launch. A freshly deployed AASA may not reach a device immediately, and an already-installed build will not pick up changes without a reinstall. For development builds, `applinks:jetledger.io?mode=developer` makes the device fetch the file directly from the domain, bypassing the CDN.

- [ ] **Step 1: Switch to developer mode for testing**

In `JetLedger/JetLedger.entitlements`, temporarily change:

```xml
		<string>applinks:jetledger.io?mode=developer</string>
```

Do not commit this. Step 8 reverts it.

- [ ] **Step 2: Install on a physical device**

Build and run to a real iPhone (not the simulator — Mail's link handling is what is being tested). Delete any previously installed copy first so the association is fetched fresh.

- [ ] **Step 3: Happy path**

Create an account from the app's sign-in screen ("Create an account"), complete the web signup, then open Apple Mail and tap the verification link.

Expected: JetLedger opens, shows "Verifying your email…", then "Email verified". Tapping Continue dismisses back to the sign-in screen.

- [ ] **Step 4: Expired path**

Tap the same link a second time.

Expected: "Link expired". Tapping **Open in browser** shows the web verify page inside the app (a Close button in the top corner, not a switch to Safari). Tapping Dismiss closes the sheet.

- [ ] **Step 5: Every auth state**

Repeat Step 3 with a fresh account while the app is (a) signed out, (b) signed in, (c) in offline mode.

Expected: the sheet presents and behaves identically in all three. In particular, signing in is not required, and being signed in as a different user does not block it.

- [ ] **Step 6: Nothing else got claimed**

From the sign-in screen, tap "Create an account", "Forgot password?", "Privacy Policy" and "Terms of Service".

Expected: all four open in the in-app browser as they did before. None of them causes an app relaunch or routes to the verification sheet.

- [ ] **Step 7: No-app fallback**

Open a verification link on a device without JetLedger installed (or in a desktop browser).

Expected: the ordinary web verify page, unchanged.

- [ ] **Step 8: Revert developer mode**

Restore the entitlement to:

```xml
		<string>applinks:jetledger.io</string>
```

Confirm with `git diff` that `JetLedger.entitlements` shows **no** changes against the Task 6 commit — `?mode=developer` must never ship in a release build.

- [ ] **Step 9: Record the outcome**

If every step passed, note in the PR or commit trail that device verification passed on <device model / iOS version>. If any step failed, stop and report which — do not mark the feature complete.

---

## Notes for the implementer

**Things that look like bugs but are not:**

- `verifyEmail` sends a `Bearer` header when a session exists. `performRawRequest` adds it unconditionally; the endpoint is unauthenticated and ignores it. Leaving it keeps this call on the same path as every other request.
- The verify sheet can appear while the terms gate is up. That is intended — verification is not one of the actions the gate exists to block.
- `invalid_or_expired` covers three distinct server conditions. See the comments in Task 1.

**Do not:**

- Add a `GET` variant of the API endpoint. The existing GET's non-mutating behavior is what defeats mail-scanner prefetch.
- Broaden the AASA path pattern.
- Add `application(_:continue:restorationHandler:)` to `AppDelegate`.
- Ship `?mode=developer`.
