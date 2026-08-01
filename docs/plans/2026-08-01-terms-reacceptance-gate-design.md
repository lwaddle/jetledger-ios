# Terms Re-Acceptance Gate (iOS client) — Design

**Date:** 2026-08-01
**Status:** Implemented
**Scope:** iOS client half of the terms re-acceptance contract. Server half is
merged in the web repo (PR #58); the contract this was built against is that
repo's `docs/ios-api.md` § "Terms re-acceptance (2026-07-31)", with rationale
in `docs/plans/2026-07-31-terms-reacceptance-design.md` (roadmap item 22).

---

## The contract, restated in one paragraph

The server tells the client a user is behind in three ways: a `terms` object
(`current_version`, `accepted_version`, `acceptance_required`, `terms_url`,
`privacy_url`) on `GET /api/accounts` and every session-creating auth
response; `POST /api/terms/accept` with the displayed version echoed back
(409 = version moved, refetch and re-present); and a 403 backstop
`{"error": "terms_acceptance_required", ...}` on every other authenticated
endpoint, **exact-match** on the error string. The client keys off
`acceptance_required` only. The gate fails OPEN offline, and a terms 403 on a
queued upload is retryable-after-acceptance.

## Decisions

1. **Gate state lives on `AuthService`, not a new service.** `AuthService`
   already drives root routing, owns the `APIClient`, and handles every
   session-creating response — the three places the signal arrives or acts.
   A separate service would need references to all three for one `Bool` and
   one accept call. `AccountService` feeds accounts-refresh signals in via an
   `onTermsStatus` closure (the `onWillSignOut` pattern), keeping it free of
   a direct `AuthService` dependency.

2. **In-memory only — the last-known state is deliberately not persisted.**
   Fail-open then needs no special casing: an offline cold launch has no
   signal, so no gate, and capture works; an online cold launch re-learns the
   state from the accounts fetch `loadAccounts` already performs (and the
   login path carries the signal directly). A persisted flag is exactly the
   stale state that could wrongly block a pilot at altitude, and the 403
   backstop makes persistence unnecessary for correctness — the server never
   serves a behind user, whether or not the client remembers.

3. **The 403 is classified in `APIClient` and fans out via a callback**
   (`onTermsAcceptanceRequired`, mirroring `onUnauthorized`), because any
   service's request can be the first to learn — a landing-time upload burst
   races the foreground accounts refresh. `APIClient.termsRequiredPayload`
   is the single exact-match point; the payload merges over any prior signal
   (`TermsStatus.from403`) so the gate can present from the 403 alone.

4. **Parking = revert to `.queued`, mirroring the 401 path.** The queue pass
   stops at the first terms 403 (the whole session is gated; hammering every
   receipt buys nothing). `firstFailedAt` is not stamped, so no "Failed"
   badge and no stalled-banner escalation for a condition one tap resolves —
   `isStalled` requires `.failed`, so parked receipts are structurally exempt.
   Grants are untouched; their 24h expiry runs on its own clock and
   `isGrantUsable` re-uploads if acceptance comes later than the reap margin.
   `lastError` stays clear: the gate is the report, and an "Upload Error"
   alert behind it would double-report. Status sync stops quietly the same
   way.

5. **Presentation is an opaque ZStack layer over `MainView`, inside the
   `.authenticated` branch of `rootView` — not a new `AuthState` case, not a
   replacement, not a sheet.** A new state case would tear down services and
   any in-progress capture on a foreground refresh; a sheet can be swiped
   away and collides with `MainView`'s own presentations. As a layer,
   already-open presentation covers (a mid-capture flow that survived
   backgrounding) sit above it and can finish — their uploads park on the
   server's backstop, which is the contract's own answer to that race. The
   gate never renders in `.offlineReady`; `MainView` is
   `.accessibilityHidden` while gated. When the flag clears, `MainView`'s
   `onChange` kicks `processQueue` + status sync + list refresh (guarded on
   `.authenticated`, since sign-out also clears the flag).

6. **Declining = Sign Out or Delete Account, both on the gate.** Parity with
   the web gate's reachable actions, and both endpoints are allowlisted past
   the backstop. Sign-out uses the identity-retaining path (same as
   Settings), so receipts captured before the gate stay on-device and upload
   after a future sign-in — which re-presents the gate first.

7. **The 409 path updates the displayed version and re-presents** with an
   explicit "the Terms were updated again" notice; the new version is never
   auto-accepted. URLs come from the signal (`terms_url` / `privacy_url`)
   with `AppConstants.Links` as parse-failure fallback, shown in the existing
   `SafariView` pattern.

## Testing

- `TermsContractTests` — signal decoding (null `accepted_version`, absent
  `terms` object), exact-match classification incl. near-misses, 403→status
  merge.
- `SyncServiceTermsTests` (in `MockURLProtocolSuites`) — parking semantics
  (queued, no `firstFailedAt`, queue stops, grants preserved, no `lastError`),
  plain-403 behavior unchanged, quiet status-sync stop, APIClient callback +
  typed error.
- Manual verification against a local server (put a user behind by setting
  `profiles.terms_version` to an old date in shared.db) still needed before
  release — this session had no macOS toolchain to run the suite.
