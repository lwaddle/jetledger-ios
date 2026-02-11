# JetLedger iOS

Companion iOS app for [JetLedger](https://jetledger.io) — captures receipt images in the field (including offline) and uploads them for review on the web app.

Built with SwiftUI, targeting iOS 17+, iPhone and iPad.

## Setup

### Prerequisites

- Xcode 26.2+
- A Supabase project (shared with the JetLedger web app)

### Configuration

Supabase credentials are kept out of source control via an `.xcconfig` file.

1. Copy the example config:
   ```
   cp Secrets.xcconfig.example Secrets.xcconfig
   ```
2. Edit `Secrets.xcconfig` and fill in your Supabase project URL and anon key (found at [supabase.com/dashboard](https://supabase.com/dashboard/project/_/settings/api))
3. Open `JetLedger.xcodeproj` in Xcode and build

`Constants.swift` reads these values from the app bundle at runtime via Info.plist variable expansion. If unconfigured, the app crashes on launch with a message telling you what to do.

### How it works

```
Secrets.xcconfig  →  Build Settings  →  Info.plist $(VARIABLES)  →  Bundle.main  →  Constants.swift
   (gitignored)
```

## Architecture

The app is offline-first. Receipts are captured and stored locally, then uploaded when connectivity is available. Authentication, database, and storage are shared with the JetLedger web app via Supabase.

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
├── Services/                    # Auth, sync, networking
├── Views/
│   ├── Login/                   # LoginView, MFAVerifyView
│   ├── Main/                    # Main screen, receipt list
│   ├── Capture/                 # Camera, preview, crop
│   ├── Detail/                  # Receipt detail viewer
│   └── Settings/                # Settings, about
├── Components/                  # Reusable UI components
└── Utilities/                   # Constants, helpers
```

## Dependencies

| Package | Purpose |
|---------|---------|
| [supabase-swift](https://github.com/supabase/supabase-swift) | Auth, database, storage |

All other frameworks are Apple-provided: Vision, CoreImage, AVFoundation, PhotosUI, SwiftData, Network.

## License

Proprietary. All rights reserved.
