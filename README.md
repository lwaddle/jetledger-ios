# JetLedger iOS

Companion iOS app for [JetLedger](https://jetledger.io) — captures receipt images in the field (including offline) and uploads them for review on the web app.

Built with SwiftUI, targeting iOS 17+, iPhone and iPad.

## Setup

### Prerequisites

- Xcode 26.2+
- The JetLedger Go backend running (shared with the web app)

### Configuration

The API URL is kept out of source control via an `.xcconfig` file.

1. Copy the example config:
   ```
   cp Secrets.xcconfig.example Secrets.xcconfig
   ```
2. Edit `Secrets.xcconfig` and set `JETLEDGER_API_URL` to your Go backend URL
3. Open `JetLedger.xcodeproj` in Xcode and build

`Constants.swift` reads this value from the app bundle at runtime via Info.plist variable expansion. If unconfigured, the app crashes on launch with a message telling you what to do.

### How it works

```
Secrets.xcconfig  →  Build Settings  →  Info.plist $(VARIABLES)  →  Bundle.main  →  Constants.swift
   (gitignored)
```

## Architecture

The app is offline-first. Receipts are captured and stored locally, then uploaded when connectivity is available. Authentication and data access are shared with the JetLedger web app via direct HTTP calls to the Go backend through a shared `APIClient`.

See [CLAUDE.md](CLAUDE.md) for the full v1 specification, including:
- Authentication and MFA flow
- Camera and capture flow with edge detection
- Multi-page receipt support
- Offline sync engine
- API endpoints and database schema
- Development phases and checklist

## Project Structure

```
JetLedger/
├── JetLedgerApp.swift          # Entry point, auth-gated routing
├── Info.plist                   # Custom keys for xcconfig → bundle bridge
├── Models/                      # SwiftData models and enums
├── Services/                    # Auth, sync, networking (APIClient, AuthService, etc.)
├── Views/
│   ├── Login/                   # LoginView, MFAVerifyView (TOTP + recovery codes)
│   ├── Main/                    # Main screen, receipt list
│   ├── Capture/                 # Camera, preview, crop
│   ├── Detail/                  # Receipt detail viewer
│   └── Settings/                # Settings, about
├── Components/                  # Reusable UI components
└── Utilities/                   # Constants, KeychainHelper, image utils
```

## Dependencies

Zero third-party dependencies. All networking via native `URLSession` through a shared `APIClient`. All other frameworks are Apple-provided: Vision, CoreImage, AVFoundation, PhotosUI, SwiftData, Network, Security.

## License

Proprietary. All rights reserved.
