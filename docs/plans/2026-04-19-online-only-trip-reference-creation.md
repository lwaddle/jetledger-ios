# Online-Only Trip Reference Creation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove offline trip-reference creation to eliminate silent cross-pilot duplicate-merge risk, gate creation to online-only, and surface a clear "use existing" UX when the server reports a conflict (HTTP 409).

**Architecture:** `TripReferenceService.createTripReference` becomes online-only — no client-UUID pending records, no background sync, no silent conflict relinking. When the server returns 409, the service looks up the conflicting ref (in cache, or forces a reload) and surfaces it to the UI as a typed error carrying the existing `CachedTripReference`. `TripReferencePicker` disables the "+" button offline with an inline caption explaining why. The offline picker and cached-search paths remain untouched — pilots can still tag captures to trips dispatch created previously.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, `@Observable` services, native `URLSession` via shared `APIClient`, Swift Testing framework.

---

## Pre-flight: Migration Note for Existing Pending Records

If any TestFlight users have `CachedTripReference` records with `isPendingSync == true` from the current offline-create flow, they will become orphaned after this change ships. We handle this with a one-time cleanup in `TripReferenceService.loadTripReferences` on next launch: when a cached pending ref can't be matched to a server record after reload, unlink it from any receipts and delete it locally. Receipts lose their trip link but remain capturable/uploadable — the user re-tags on web during review or from the iOS detail edit sheet when online.

---

## Task 1: Extend `TripReferenceError` with typed conflict case

**Files:**
- Modify: `JetLedger/Services/TripReferenceService.swift:416-426`

**Step 1: Update the error enum**

Replace the existing enum (lines 416-426) with:

```swift
enum TripReferenceError: LocalizedError {
    case validationFailed(String)
    case duplicate(String)
    case offline
    case conflictWithExisting(CachedTripReference)

    var errorDescription: String? {
        switch self {
        case .validationFailed(let message), .duplicate(let message):
            message
        case .offline:
            "Connect to the internet to create a new trip reference."
        case .conflictWithExisting(let ref):
            "A trip reference with this ID or name already exists: \(ref.displayTitle)."
        }
    }
}
```

**Step 2: Verify it builds**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add JetLedger/Services/TripReferenceService.swift
git commit -m "feat: add offline + conflictWithExisting cases to TripReferenceError"
```

---

## Task 2: Write failing test for online-only `createTripReference` (offline rejection)

**Files:**
- Modify: `JetLedgerTests/JetLedgerTests.swift`

> Note: existing tests are scaffolded only. We add the first real test. Swift Testing framework (`import Testing`).

**Step 1: Replace the placeholder test file**

```swift
//
//  JetLedgerTests.swift
//  JetLedgerTests
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

@MainActor
struct TripReferenceServiceTests {

    private func makeService(isConnected: Bool) throws -> (TripReferenceService, ModelContext) {
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext
        let monitor = NetworkMonitor()
        monitor.setConnectedForTesting(isConnected)
        let apiClient = APIClient()
        let service = TripReferenceService(
            apiClient: apiClient,
            modelContext: context,
            networkMonitor: monitor
        )
        return (service, context)
    }

    @Test
    func createTripReferenceRejectsWhenOffline() async throws {
        let (service, _) = try makeService(isConnected: false)

        await #expect(throws: TripReferenceError.self) {
            try await service.createTripReference(
                accountId: UUID(),
                externalId: "TRIP-1",
                name: nil
            )
        }
    }
}
```

**Step 2: Add a test hook to `NetworkMonitor`**

Open `JetLedger/Services/NetworkMonitor.swift` and add at the end of the class body:

```swift
#if DEBUG
    func setConnectedForTesting(_ value: Bool) { isConnected = value }
#endif
```

**Step 3: Run the test — expect failure**

Run: `xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -only-testing:JetLedgerTests/TripReferenceServiceTests/createTripReferenceRejectsWhenOffline`
Expected: FAIL — `createTripReference` method does not exist (only `createTripReferenceLocally`).

---

## Task 3: Refactor `createTripReference` — remove offline fallback, enhance conflict handling

**Files:**
- Modify: `JetLedger/Services/TripReferenceService.swift:104-175`

**Step 1: Replace `createTripReferenceLocally` with online-only `createTripReference`**

Replace the entire method (lines 104-175) with:

```swift
    // MARK: - Create (online-only)

    func createTripReference(
        accountId: UUID,
        externalId: String?,
        name: String?
    ) async throws -> CachedTripReference {
        let trimmedExtId = externalId?.trimmingCharacters(in: .whitespaces).strippingHTMLTags
        let trimmedName = name?.trimmingCharacters(in: .whitespaces).strippingHTMLTags

        guard !(trimmedExtId ?? "").isEmpty || !(trimmedName ?? "").isEmpty else {
            throw TripReferenceError.validationFailed("Trip ID or name is required.")
        }

        guard networkMonitor.isConnected else {
            throw TripReferenceError.offline
        }

        let accountRefs = tripReferences.filter { $0.accountId == accountId }
        if let extId = trimmedExtId, !extId.isEmpty,
           let existing = accountRefs.first(where: { $0.externalId?.lowercased() == extId.lowercased() }) {
            throw TripReferenceError.conflictWithExisting(TripReferenceSummary(from: existing))
        }
        if let n = trimmedName, !n.isEmpty, (trimmedExtId ?? "").isEmpty,
           let existing = accountRefs.first(where: { $0.name?.lowercased() == n.lowercased() }) {
            throw TripReferenceError.conflictWithExisting(TripReferenceSummary(from: existing))
        }

        let request = TripReferenceBody(
            externalId: trimmedExtId?.isEmpty == true ? nil : trimmedExtId,
            name: trimmedName?.isEmpty == true ? nil : trimmedName
        )

        do {
            let response: TripReferenceDTO = try await withTimeout(seconds: 5) { [apiClient] in
                try await apiClient.request(
                    .post, AppConstants.WebAPI.tripReferences,
                    body: request
                )
            }

            let cached = CachedTripReference(
                id: response.id,
                accountId: accountId,
                externalId: response.externalId,
                name: response.name,
                createdAt: response.createdAt
            )
            modelContext.insert(cached)
            try? modelContext.save()
            tripReferences.insert(cached, at: 0)
            return cached
        } catch let error as APIError where error == .conflict {
            let existing = await findExistingConflict(
                accountId: accountId,
                externalId: trimmedExtId,
                name: trimmedName
            )
            if let existing {
                throw TripReferenceError.conflictWithExisting(TripReferenceSummary(from: existing))
            }
            throw TripReferenceError.duplicate("This trip reference already exists but could not be loaded. Try again.")
        }
    }

    private func findExistingConflict(
        accountId: UUID,
        externalId: String?,
        name: String?
    ) async -> CachedTripReference? {
        await loadTripReferences(for: accountId)
        let accountRefs = tripReferences.filter { $0.accountId == accountId }

        if let extId = externalId, !extId.isEmpty {
            return accountRefs.first { $0.externalId?.lowercased() == extId.lowercased() }
        }
        if let n = name, !n.isEmpty {
            return accountRefs.first { $0.name?.lowercased() == n.lowercased() }
        }
        return nil
    }
```

**Step 2: Run the failing test — expect PASS now (offline rejection)**

Run: `xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -only-testing:JetLedgerTests/TripReferenceServiceTests/createTripReferenceRejectsWhenOffline`
Expected: BUILD will FAIL — `createTripReferenceLocally` is still referenced elsewhere. Do not commit yet — proceed to Task 4 to clear remaining references.

---

## Task 4: Delete pending-sync and conflict-relink logic

**Files:**
- Modify: `JetLedger/Services/TripReferenceService.swift`

**Step 1: Delete methods**

Remove these methods entirely:
- `syncPendingTripReferences()` (lines ~179-189)
- `syncSingleTripReference(_:)` (lines ~191-229)
- `handleUniqueConflict(localRef:)` (lines ~231-303)
- `relinkReceipts(from:to:externalId:name:)` (lines ~305-312)

**Step 2: Simplify `loadTripReferences` — remove pending preservation, add one-time orphan cleanup**

Replace the method body (lines 29-88) with:

```swift
    func loadTripReferences(for accountId: UUID) async {
        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
        let cachedForAccount = allCached.filter { $0.accountId == accountId }
        if !cachedForAccount.isEmpty {
            tripReferences = cachedForAccount
        }

        if cachedForAccount.isEmpty { isLoading = true }
        defer { isLoading = false }

        do {
            let response: TripReferencesResponse = try await withTimeout(
                seconds: AppConstants.Sync.networkQueryTimeoutSeconds
            ) { [apiClient] in
                try await apiClient.get(AppConstants.WebAPI.tripReferences)
            }

            // One-time migration: unlink and delete orphaned legacy pending refs
            let serverIds = Set(response.tripReferences.map(\.id))
            let existing = try modelContext.fetch(FetchDescriptor<CachedTripReference>())
            for ref in existing where ref.accountId == accountId {
                if ref.isPendingSync && !serverIds.contains(ref.id) {
                    unlinkReceiptsFromTripReference(ref.id)
                }
                modelContext.delete(ref)
            }

            var cached: [CachedTripReference] = []
            for item in response.tripReferences {
                let ref = CachedTripReference(
                    id: item.id,
                    accountId: accountId,
                    externalId: item.externalId,
                    name: item.name,
                    createdAt: item.createdAt
                )
                modelContext.insert(ref)
                cached.append(ref)
            }

            try modelContext.save()
            tripReferences = cached
        } catch {
            if tripReferences.isEmpty {
                let fallback = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
                tripReferences = fallback.filter { $0.accountId == accountId }
            }
        }
    }

    private func unlinkReceiptsFromTripReference(_ tripRefId: UUID) {
        guard let allReceipts = try? modelContext.fetch(FetchDescriptor<LocalReceipt>()) else { return }
        for receipt in allReceipts where receipt.tripReferenceId == tripRefId {
            receipt.tripReferenceId = nil
            receipt.tripReferenceExternalId = nil
            receipt.tripReferenceName = nil
        }
    }
```

**Step 3: Simplify `clearCache` — drop pending handling**

Replace `clearCache` (lines ~360-378) with:

```swift
    func clearCache() {
        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
        for ref in allCached { modelContext.delete(ref) }
        try? modelContext.save()
        tripReferences = []
    }
```

**Step 4: Remove `syncPendingTripReferences()` call from `SyncService`**

Open `JetLedger/Services/SyncService.swift:55-56` and delete:

```swift
            // Sync pending trip references before uploading receipts
            await tripReferenceService.syncPendingTripReferences()
```

**Step 5: Verify build**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build`
Expected: BUILD SUCCEEDED

**Step 6: Run the full test suite**

Run: `xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -only-testing:JetLedgerTests`
Expected: PASS (offline rejection test passes; no other tests regress)

**Step 7: Commit**

```bash
git add JetLedger/Services/TripReferenceService.swift JetLedger/Services/SyncService.swift JetLedger/Services/NetworkMonitor.swift JetLedgerTests/JetLedgerTests.swift
git commit -m "refactor: make trip reference creation online-only

Removes pending-sync/conflict-relink logic that silently merged duplicate
trips across pilots. Offline creation now throws TripReferenceError.offline;
server 409 conflicts throw .conflictWithExisting(ref) so the UI can offer
'use this existing trip' instead of a silent merge.

Includes one-time cleanup for legacy pending refs on next load."
```

---

## Task 5: Remove `isPendingSync` UI treatment in `TripReferencePicker`

**Files:**
- Modify: `JetLedger/Components/TripReferencePicker.swift:24-28, 96-100`

**Step 1: Remove clock.arrow.circlepath indicators**

Delete lines 24-28:

```swift
                            if ref.isPendingSync {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
```

Delete lines 96-100 (same pattern inside the list row):

```swift
                                if ref.isPendingSync {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
```

Also remove the now-unused `HStack(spacing: 4)` wrapper around the `Text(ref.displayTitle)` at both sites — collapse to just the `Text`.

**Step 2: Verify build**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build`
Expected: BUILD SUCCEEDED

---

## Task 6: Offline state in `TripReferenceListView` (disabled + button + inline caption)

**Files:**
- Modify: `JetLedger/Components/TripReferencePicker.swift:53-146`

**Step 1: Inject `NetworkMonitor`**

Add inside `TripReferenceListView` (below `@Environment(TripReferenceService.self) private var tripReferenceService`):

```swift
    @Environment(NetworkMonitor.self) private var networkMonitor
```

**Step 2: Add inline caption to list when offline**

Inside `List { ... }`, before the `if selection != nil && searchText.isEmpty` block, add:

```swift
            if canCreate && !networkMonitor.isConnected {
                Section {
                    Label(
                        "New trips can be created when you're back online.",
                        systemImage: "wifi.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
```

**Step 3: Disable the "+" button when offline**

Change the toolbar block (lines ~123-132) from:

```swift
            if canCreate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreateForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
```

to:

```swift
            if canCreate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreateForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!networkMonitor.isConnected)
                    .accessibilityHint(networkMonitor.isConnected
                        ? "Create new trip reference"
                        : "Unavailable offline")
                }
            }
```

**Step 4: Verify build**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build`
Expected: BUILD SUCCEEDED

---

## Task 7: 409 conflict UI in `CreateTripReferenceView`

**Files:**
- Modify: `JetLedger/Components/TripReferencePicker.swift:150-236`

**Step 1: Add state for the conflicting ref**

Add to `CreateTripReferenceView`:

```swift
    @State private var conflictingRef: TripReferenceSummary?
```

> Note: `conflictingRef` carries a `Sendable` snapshot (not the live `@Model`). When the user taps "Use this one", we look up the live `CachedTripReference` from `tripReferenceService.tripReferences` by `id` before calling `onCreated`.

**Step 2: Rewrite `save()` to handle `.conflictWithExisting`**

Replace the `save()` method (lines ~217-235) with:

```swift
    private func save() {
        isSaving = true
        errorMessage = nil
        conflictingRef = nil

        Task {
            do {
                let ref = try await tripReferenceService.createTripReference(
                    accountId: accountId,
                    externalId: externalId.trimmingCharacters(in: .whitespaces),
                    name: name.trimmingCharacters(in: .whitespaces)
                )
                onCreated(ref)
                dismiss()
            } catch let error as TripReferenceError {
                if case .conflictWithExisting(let ref) = error {
                    conflictingRef = ref
                } else {
                    errorMessage = error.localizedDescription
                }
                isSaving = false
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
```

**Step 3: Add conflict banner section in the form**

Inside `Form { ... }`, after the `errorMessage` section, add:

```swift
            if let conflictingRef {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A trip reference with this ID already exists.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conflictingRef.displayTitle)
                                    .fontDesign(conflictingRef.externalId != nil ? .monospaced : .default)
                                if conflictingRef.externalId != nil, let n = conflictingRef.name {
                                    Text(n)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Use this one") {
                                if let live = tripReferenceService.tripReferences.first(where: { $0.id == conflictingRef.id }) {
                                    onCreated(live)
                                    dismiss()
                                } else {
                                    // Summary is stale — reload and retry once.
                                    Task {
                                        await tripReferenceService.loadTripReferences(for: accountId)
                                        if let live = tripReferenceService.tripReferences.first(where: { $0.id == conflictingRef.id }) {
                                            onCreated(live)
                                            dismiss()
                                        } else {
                                            errorMessage = "Couldn't load the existing trip reference. Try again."
                                            self.conflictingRef = nil
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
```

**Step 4: Verify build**

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build`
Expected: BUILD SUCCEEDED

**Step 5: Manual verification (UI cannot be unit-tested here)**

On the simulator:

1. **Happy path online:** Enter a new unique Trip ID → "Save" → form dismisses, selection populates.
2. **Offline disabled state:** Toggle simulator to Airplane Mode (⌘ K simulator → Features → Toggle Airplane Mode is unreliable in sim — use `xcrun simctl ... status_bar` or test on device). Open picker → "+" button is disabled (tinted secondary); inline caption "New trips can be created when you're back online." appears at the top of the list.
3. **Conflict handling:** While online, create a trip with ID `TEST-CONFLICT`. Then attempt to create another with the exact same ID. Expect: conflict section appears inside the create form with the existing ref and a "Use this one" button that links the receipt to the existing ref.

**Step 6: Commit**

```bash
git add JetLedger/Components/TripReferencePicker.swift
git commit -m "feat: offline-disabled + conflict handling UI for trip reference creation

Disables the create button when offline with a plain-english inline caption.
Surfaces 409 conflicts as an in-form 'use this one' affordance instead of
the previous silent relink-on-sync."
```

---

## Task 8: Remove `isPendingSync` field from `CachedTripReference`

> **Do this last.** Earlier tasks depend on the field existing for the one-time migration in `loadTripReferences`. Once that migration has shipped at least once, we can drop the field — but since this is pre-v1 (no App Store release), we can drop it now and include the migration in the same release.

**Files:**
- Modify: `JetLedger/Models/CachedTripReference.swift:18`
- Modify: `JetLedger/Services/TripReferenceService.swift` (the `loadTripReferences` cleanup check)

**Step 1: Decision point**

Two options:

- **A (recommended if no TestFlight users have pending refs):** Delete `var isPendingSync: Bool = false` entirely; simplify the one-time cleanup in `loadTripReferences` to drop the `ref.isPendingSync && ...` check and just trust server IDs as the source of truth.
- **B (safer if TestFlight users may have pending refs):** Keep the field. `SwiftData` auto-migration handles it fine as an unused column.

**Default:** Choose B for one release, then drop in the next. **This plan proceeds with Option B** — no change to the model in this release. If you prefer A, simply delete line 18 and the `ref.isPendingSync &&` condition inside `loadTripReferences`.

**Step 2 (only if choosing A):** Verify build and tests pass after deletion.

**Step 3: Commit (only if A chosen)**

```bash
git add JetLedger/Models/CachedTripReference.swift JetLedger/Services/TripReferenceService.swift
git commit -m "refactor: drop unused isPendingSync field from CachedTripReference"
```

---

## Task 9: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/v1-specification.md` (search for "trip reference" / "offline create")

**Step 1: Update `CLAUDE.md`**

Find the Sync & Upload section or add to Architecture. If the doc mentions offline trip creation anywhere, update it to: *"Trip reference creation requires an internet connection. The picker works offline using cached references; if the desired trip doesn't exist yet, the receipt can be captured without a trip link and tagged later via the detail edit sheet (online) or on the web during review."*

**Step 2: Search spec doc**

Run: `grep -n "pending\|offline.*trip\|trip.*offline" docs/v1-specification.md` and update any stale sentences.

**Step 3: Commit**

```bash
git add CLAUDE.md docs/v1-specification.md
git commit -m "docs: reflect online-only trip reference creation"
```

---

## Task 10: Update auto-memory

**Files:**
- Modify: `/Users/lwaddle/.claude/projects/-Users-lwaddle-dev-jetledger-ios-JetLedger/memory/MEMORY.md` and/or a dedicated topic file

**Step 1: Find existing trip-reference memory entries and update**

The `Completed (Phase 3)` and `Architecture Patterns (Phase 3 — Sync)` sections reference `TripReferenceService` and pending sync. Update:
- Remove mentions of `syncPendingTripReferences`, offline creation, pending sync flag
- Add a one-liner: *"Trip reference creation is online-only — 409 surfaces a `.conflictWithExisting(ref)` error for UI to offer 'use existing'."*

No commit — memory files are outside the repo.

---

## Final Verification

**Full verification before declaring done:**

1. Build: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build` → BUILD SUCCEEDED
2. Tests: `xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -only-testing:JetLedgerTests` → all green
3. Manual UI walkthrough from Task 7 Step 5
4. `git log --oneline` shows the task commits in order
5. Use **superpowers:verification-before-completion** before announcing completion

---

## Summary of Changes

**Deleted (~130 lines):**
- `TripReferenceService.syncPendingTripReferences`
- `TripReferenceService.syncSingleTripReference`
- `TripReferenceService.handleUniqueConflict`
- `TripReferenceService.relinkReceipts`
- Pending-preservation logic in `loadTripReferences`
- Pending-id handling in `clearCache`
- `TripReferenceService.createTripReferenceLocally` offline fallback branch
- `SyncService.processQueue` call to `syncPendingTripReferences`
- `isPendingSync` clock badges in `TripReferencePicker` (2 sites)

**Added (~80 lines):**
- `TripReferenceError.offline` + `.conflictWithExisting(CachedTripReference)` cases
- `TripReferenceService.createTripReference` (online-only) + `findExistingConflict` helper
- One-time orphan cleanup in `loadTripReferences`
- `unlinkReceiptsFromTripReference` helper
- Offline caption row + disabled create button in `TripReferenceListView`
- 409 conflict section + "Use this one" button in `CreateTripReferenceView`
- First real unit test (`createTripReferenceRejectsWhenOffline`)
- Test hook `NetworkMonitor.setConnectedForTesting` (DEBUG-only)

**Net:** simpler code, clearer UX, no silent cross-pilot merges.
