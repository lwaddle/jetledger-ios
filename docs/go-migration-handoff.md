# Go Backend Migration — Status

> Original handoff written 2026-07-14 from the jetledger (Go backend) repo.
> **Corrected 2026-07-14 after auditing this repo:** the migration it described
> was already complete. Every item on its "Remaining" list — AuthService on the
> Go auth API, Keychain token storage, AccountService/TripReferenceService/
> PushNotificationService on Go endpoints, offline identity from the Go login
> response, deletion of the Supabase-only views, removal of supabase-swift —
> was already done (`grep -ri supabase` returns nothing; the project has zero
> SPM dependencies). Authoritative API reference: `~/dev/jetledger/docs/ios-api.md`
> and the "iOS API Routes" section of `~/dev/jetledger/docs/routes.md`.

## The one real gap (fixed 2026-07-14)

Session token rotation. The Go middleware never rolls `expires_at` on use
(`GetAPISessionByTokenHash` only checks `expires_at > now`), so "30 days with
rolling refresh" is **client-driven**: without an explicit
`POST /api/auth/refresh`, active users hard-expire at 30 days.

Fix: `AuthService.refreshSessionIfNeeded()` — called on launch (after
`restoreSession()`) and on every foreground via `scenePhase` in `JetLedgerApp`.
It rotates the token once it's ~7 days old, stores the server-provided
`expires_at`, and treats missing stored expiry (installs predating the change)
as refresh-now. Failures are non-fatal: 401 routes through the existing
biometric re-auth path; network errors retry on a later foreground.

## Local testing against a real backend

The Go repo has a zero-secrets staging compose (built for load testing,
perfect for iOS dev):

```bash
cd ~/dev/jetledger
docker compose -f loadtest/docker-compose.staging.yml up -d --build
# app on http://localhost:8080, dev mode (no real email/OCR), local storage
go run ./cmd/loadseed -tenants 1 -password test-pw   # test account: load-1@loadtest.local
```

Caveat: presigned R2 upload endpoints return 503 with local storage — point
`Secrets.xcconfig` at production (or an R2-configured instance) to exercise
the direct-upload path.
