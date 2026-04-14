# Face ID / Biometric Re-Authentication Design

**Date:** 2026-04-13
**Status:** Implemented

## Problem

When the 30-day server session token expires, users must re-enter email + password + TOTP. This is high-friction for pilots who use the app intermittently while traveling.

## Solution

Trusted device token approach:

1. First login: normal email + password + TOTP
2. App prompts "Enable Face ID?" after successful login
3. If enabled: server issues a long-lived device token (1 year), stored in Keychain with biometric protection (`.biometryCurrentSet`)
4. On session expiry: Face ID unlocks device token, server issues new session token (no password, no TOTP)
5. If Face ID fails/cancelled: falls back to normal login

## Security Model

- Device token stored server-side as SHA-256 hash (plaintext never stored)
- Keychain uses `.biometryCurrentSet` + `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`
- Token automatically invalidated if user changes enrolled biometrics
- Max 5 trusted devices per user (oldest auto-deleted)
- Sign-out revokes device token server-side + deletes locally
- Separate non-biometric Keychain copy exists solely for sign-out revocation

## Backend Endpoints

- `POST /api/auth/trust-device` (requires session) -- register device, returns token
- `POST /api/auth/device-login` (no session) -- authenticate with device token
- `POST /api/auth/revoke-device` (requires session) -- revoke without ending session
- `POST /api/auth/logout` (modified) -- optionally accepts device_token for revocation

## Key Files

### Backend (Go)
- `db/migrations/shared/001_init.sql` -- trusted_devices table schema
- `internal/database/shared.go` -- runtime schema creation
- `db/queries/shared/trusted_devices.sql` -- sqlc queries
- `api/auth.go` -- TrustDevice, DeviceLogin, RevokeDevice handlers

### iOS
- `Services/BiometricAuthService.swift` -- Face ID service
- `Utilities/KeychainHelper.swift` -- biometric Keychain methods
- `Services/AuthService.swift` -- async restoreSession, 401 re-auth guard
- `JetLedgerApp.swift` -- lifecycle wiring, post-login prompt
- `Views/Settings/SettingsView.swift` -- Face ID toggle
