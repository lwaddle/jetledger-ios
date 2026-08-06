//
//  MainView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    var isOfflineMode: Bool = false

    @Environment(AuthService.self) private var authService
    @Environment(AccountService.self) private var accountService
    @Environment(SyncService.self) private var syncService
    @Environment(TripReferenceService.self) private var tripReferenceService
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(PushNotificationService.self) private var pushService
    @Environment(ReceiptListService.self) private var receiptListService
    @Environment(CameraSessionManager.self) private var cameraSessionManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var showCapture = false
    @State private var showFilePicker = false
    @State private var importedURLs: [URL] = []
    @State private var selectedReceipt: LocalReceipt?
    @State private var syncErrorMessage: String?
    @State private var showImportError = false
    @State private var importErrorMessage: String?
    @State private var deepLinkErrorMessage: String?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// Where the user last imported from, so the document picker opens there
    /// instead of visibly restoring its own location. Consumed in Task 6.
    @AppStorage("lastImportDirectory") private var lastImportDirectoryPath: String = ""

    /// One sheet slot, not two. SwiftUI reliably services a single presentation
    /// per view, and this view already carries a `.fullScreenCover` and a
    /// `.fileImporter` alongside. Two independent `.sheet(isPresented:)`
    /// modifiers contending for that slot is how a Settings tap gets swallowed.
    private enum ActiveSheet: Identifiable {
        case importFlow
        case settings

        var id: Int {
            switch self {
            case .importFlow: 0
            case .settings: 1
            }
        }
    }

    @State private var activeSheet: ActiveSheet?

    private var canUpload: Bool {
        // No account yet (still loading) → don't flash the viewer banner.
        // Account present but role unrecognized → fail closed; an unknown
        // future role must not silently get upload UI.
        guard let account = accountService.selectedAccount else { return true }
        return account.accountRole?.canUpload ?? false
    }

    // `body` is split across the stages below purely to keep each expression
    // inside the Swift type checker's budget. As one chain — 14 modifiers over
    // ~190 lines, several carrying multi-statement closures and inline
    // `Binding(get:set:)` pairs — it exceeds that budget and fails the build
    // with "the compiler is unable to type-check this expression in reasonable
    // time", reported at whichever line the checker gave up on rather than at
    // the culprit. Anything added to this view risks tipping it over again;
    // add to a stage, or add a stage.
    //
    // Each stage applies its modifiers to the previous one, so the resulting
    // order is identical to the single chain this replaced. Keep it that way —
    // modifier order is semantic for presentation modifiers.
    var body: some View {
        withLifecycleHandlers
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        AccountSelectorView()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            activeSheet = .settings
                        } label: {
                            // Filled + explicitly tinted: the default outline
                            // glyph read as decorative against the glass chrome.
                            Image(systemName: "gearshape.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        } detail: {
            if let selectedReceipt {
                // .id resets the detail view's @State (gallery page, delete
                // confirmation, sheets) when the iPad selection changes —
                // without it, a confirmation opened for receipt A can execute
                // against receipt B.
                ReceiptDetailView(receipt: selectedReceipt, selectedReceipt: $selectedReceipt)
                    .id(selectedReceipt.id)
            } else if !canUpload {
                ContentUnavailableView(
                    "Read-Only Access",
                    systemImage: "eye.fill",
                    description: Text("Viewers can browse receipts but cannot upload. Contact your administrator to request editor access.")
                )
            } else {
                ContentUnavailableView(
                    "Select a Receipt",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a receipt from the list to view its details.")
                )
            }
        }
    }

    private var withPresentations: some View {
        splitView
        .fullScreenCover(isPresented: $showCapture) {
            if let account = accountService.selectedAccount {
                CaptureFlowView(accountId: account.id, cameraSessionManager: cameraSessionManager)
            }
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
            switch sheet {
            case .importFlow:
                if let account = accountService.selectedAccount {
                    ImportFlowView(accountId: account.id, urls: importedURLs)
                }
            case .settings:
                SettingsView(isOfflineMode: isOfflineMode)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf, .jpeg, .png, .heic],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }

    /// The importer's completion runs while the document picker is still
    /// dismissing. Presenting the import sheet from inside it requested a new
    /// presentation mid-teardown: the request was swallowed, and the machinery
    /// was left confused enough to eat the *next* one — which is how a Settings
    /// tap did nothing. Hopping to the next runloop turn lets the dismissal
    /// finish first.
    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        importedURLs = urls
        if let directory = urls.first?.deletingLastPathComponent() {
            lastImportDirectoryPath = directory.absoluteString
        }
        Task { activeSheet = .importFlow }
    }

    /// Was `onChange(of: showImport)`. `.sheet(item:)`'s `onDismiss` does not
    /// say which item closed, so this now runs for Settings too. That widening
    /// is deliberate and safe: `processQueue` is idempotent and no-ops with an
    /// empty queue, and `importedURLs` is only read while the import sheet is
    /// up. Reconstructing "which sheet was that" to avoid a free no-op would
    /// cost more than it saves.
    private func handleSheetDismiss() {
        importedURLs = []
        if !isOfflineMode {
            syncService.processQueue()
        }
    }

    private var withStateObservers: some View {
        withPresentations
        .onChange(of: showCapture) { _, isShowing in
            if !isShowing {
                if !isOfflineMode {
                    syncService.processQueue()
                }
                // Defer the session stop — re-opens within 30s skip the
                // warming overhead and avoid the FigXPC pause noise
                // (one pair per output) emitted by an immediate stop.
                cameraSessionManager.scheduleStop(after: 30)
            } else {
                cameraSessionManager.cancelScheduledStop()
            }
        }
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            if !isOfflineMode {
                syncService.handleNetworkChange(isConnected: isConnected)
            }
        }
        .onChange(of: accountService.selectedAccount?.id) { _, _ in
            // The detail column must not keep showing the previous account's
            // receipt after a switch.
            selectedReceipt = nil
        }
        .task(id: accountService.selectedAccount?.id) {
            if !isOfflineMode, let accountId = accountService.selectedAccount?.id {
                await tripReferenceService.loadTripReferences(for: accountId)
                await syncService.syncReceiptStatuses()
                await refreshReceiptList(accountId: accountId)
                runCleanup()
            }
        }
        .onChange(of: authService.termsAcceptanceRequired) { wasRequired, isRequired in
            resumeWorkParkedByTermsGate(wasRequired: wasRequired, isRequired: isRequired)
        }
        .onChange(of: syncService.lastError) { _, error in
            if let error {
                syncErrorMessage = error
            }
        }
    }

    private var withAlerts: some View {
        withStateObservers
        .alert("Upload Error", isPresented: Binding(
            get: { syncErrorMessage != nil },
            set: { if !$0 { syncErrorMessage = nil } }
        )) {
            Button("Retry") {
                syncService.lastError = nil
                syncErrorMessage = nil
                syncService.retryAllFailed()
            }
            Button("OK", role: .cancel) {
                syncService.lastError = nil
                syncErrorMessage = nil
            }
        } message: {
            Text(syncErrorMessage ?? "")
        }
        .alert("Import Error", isPresented: $showImportError) {
            Button("OK") { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
        .alert("Receipt Unavailable", isPresented: Binding(
            get: { deepLinkErrorMessage != nil },
            set: { if !$0 { deepLinkErrorMessage = nil } }
        )) {
            Button("OK") { deepLinkErrorMessage = nil }
        } message: {
            Text(deepLinkErrorMessage ?? "")
        }
    }

    private var withLifecycleHandlers: some View {
        withAlerts
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !isOfflineMode, let accountId = accountService.selectedAccount?.id {
                let result = SharedImportService.processPendingImports(
                    accountId: accountId,
                    modelContext: modelContext
                )
                if result.imported > 0 {
                    syncService.processQueue()
                }
                if let problem = result.problemMessage {
                    importErrorMessage = problem
                    showImportError = true
                }
                Task {
                    // Memberships can change while the app is backgrounded —
                    // e.g. accepting an org invitation from Mail on this same
                    // device. Refresh silently so the account switcher (and
                    // roles) update on return instead of requiring a relaunch.
                    await accountService.refreshAccounts()
                    await syncService.syncReceiptStatuses()
                    await refreshReceiptList(accountId: accountId)
                    runCleanup()
                }
            }
        }
        // initial: true — on a cold launch from a notification tap, the deep-link
        // id is set before MainView exists; without an initial evaluation the
        // onChange never fires and the tap lands on a plain list.
        .onChange(of: pushService.pendingDeepLinkReceiptId, initial: true) { _, receiptId in
            guard let receiptId else { return }
            pushService.pendingDeepLinkReceiptId = nil
            navigateToReceipt(serverReceiptId: receiptId)
        }
        .task {
            cameraSessionManager.configure()
            // Process any pending shared imports
            if !isOfflineMode, let accountId = accountService.selectedAccount?.id {
                let result = SharedImportService.processPendingImports(
                    accountId: accountId,
                    modelContext: modelContext
                )
                if let problem = result.problemMessage {
                    importErrorMessage = problem
                    showImportError = true
                }
            }
            if !isOfflineMode {
                syncService.processQueue()
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if accountService.isLoading {
            VStack {
                Spacer()
                ProgressView("Loading accounts...")
                Spacer()
            }
        } else if let account = accountService.selectedAccount {
            accountContent(account)
        } else if let loadError = accountService.loadError {
            ContentUnavailableView {
                Label("Unable to Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Retry") {
                    Task { await accountService.loadAccounts() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "No Accounts",
                systemImage: "building.2",
                description: Text("You don't belong to any accounts. Contact your administrator.")
            )
        }
    }

    @ViewBuilder
    private func accountContent(_ account: CachedAccount) -> some View {
        ReceiptListView(accountId: account.id, selectedReceipt: $selectedReceipt) {
            VStack(spacing: 24) {
                // Offline banner
                if isOfflineMode {
                    offlineBanner
                }

                // Brand bar — logo only; the account selector lives in the
                // toolbar so long org names get the full nav-bar width.
                HStack {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 28)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, isOfflineMode ? 0 : 12)

                // Scan + Import buttons
                if canUpload {
                    VStack(spacing: 12) {
                        Button {
                            showCapture = true
                        } label: {
                            Label("Scan Receipt", systemImage: "camera.fill")
                                .foregroundStyle(.white)
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        // BrandPrimary, not the accent: in dark mode the accent
                        // is a bright tint blue that fails under the white label;
                        // filled buttons use the navy primary like web btn-primary.
                        .buttonStyle(.borderedProminent)
                        .tint(Color(.brandPrimary))
                        .padding(.horizontal)

                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Import from Files", systemImage: "doc.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.accentColor)
                        .padding(.horizontal)
                    }
                } else {
                    viewerBanner
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var offlineBanner: some View {
        Button {
            authService.authState = .unauthenticated
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.subheadline)
                if networkMonitor.isConnected {
                    let queuedCount = queuedReceiptCount
                    Text(queuedCount > 0
                         ? "Sign in to upload \(queuedCount) receipt\(queuedCount == 1 ? "" : "s")"
                         : "Sign in to sync receipts")
                        .font(.subheadline)
                } else {
                    Text("Offline — sign in to sync receipts")
                        .font(.subheadline)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            // Meridian warning pair: the dark-mode gold is too bright for white
            // text, so the content colorset flips to dark umber there.
            .foregroundStyle(Color(.statusWarningContent))
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.statusWarning))
        }
    }

    private var queuedReceiptCount: Int {
        guard let accountId = accountService.selectedAccount?.id else { return 0 }
        let allReceipts = (try? modelContext.fetch(FetchDescriptor<LocalReceipt>())) ?? []
        return allReceipts.filter {
            $0.accountId == accountId && ($0.syncStatus == .queued || $0.syncStatus == .failed)
        }.count
    }

    private var viewerBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Read-Only Access")
                .font(.headline)
            Text("Viewers can browse receipts but cannot scan or upload. Contact your administrator to request editor access.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: - Cleanup

    /// Runs retention cleanup and drops the detail selection if its record was
    /// deleted — a live `ReceiptDetailView` touching a destroyed `@Model`
    /// crashes on the next body evaluation. The selected id is captured before
    /// the delete so the check never reads a destroyed model.
    private func runCleanup() {
        let selectedId = selectedReceipt?.id
        let deletedIds = syncService.performCleanup()
        if let selectedId, deletedIds.contains(selectedId) {
            selectedReceipt = nil
        }
    }

    /// Acceptance is the green light for everything the terms gate parked:
    /// queued uploads, status sync, and the server-driven list, all of which
    /// were 403ing moments ago. The authState check filters the other way this
    /// flag goes false — sign-out clearing the session, where kicking the queue
    /// would upload against a dead token.
    ///
    /// A method rather than an inline closure: `body`'s modifier chain is long
    /// enough that a multi-statement closure here pushes the type checker past
    /// its budget, and it fails somewhere else in the chain rather than at the
    /// culprit.
    private func resumeWorkParkedByTermsGate(wasRequired: Bool, isRequired: Bool) {
        guard wasRequired, !isRequired, !isOfflineMode,
              authService.authState == .authenticated else { return }

        syncService.processQueue()
        guard let accountId = accountService.selectedAccount?.id else { return }
        Task {
            await syncService.syncReceiptStatuses()
            await refreshReceiptList(accountId: accountId)
        }
    }

    /// Refreshes the server-backed list and drops the detail selection if the
    /// refresh proved that receipt was deleted on the web — a live
    /// `ReceiptDetailView` holding a destroyed `@Model` crashes on the next body
    /// evaluation.
    private func refreshReceiptList(accountId: UUID) async {
        let selectedId = selectedReceipt?.id
        let pruned = await receiptListService.refresh(accountId: accountId)
        if let selectedId, pruned.contains(selectedId) {
            selectedReceipt = nil
        }
    }

    // MARK: - Deep Link Navigation

    /// A push can name a receipt this device never uploaded — an email forward,
    /// or one captured on another phone. Falling through to a detail fetch is
    /// what stops the tap landing on a plain list.
    private func navigateToReceipt(serverReceiptId: UUID) {
        let descriptor = FetchDescriptor<LocalReceipt>()
        if let receipts = try? modelContext.fetch(descriptor),
           let match = receipts.first(where: { $0.serverReceiptId == serverReceiptId }) {
            selectedReceipt = match
            return
        }

        guard let accountId = accountService.selectedAccount?.id else { return }
        Task {
            switch await receiptListService.fetchDetail(
                serverReceiptId: serverReceiptId, accountId: accountId
            ) {
            case .ok(let receipt), .removedFromServer(let receipt):
                selectedReceipt = receipt
            case .deleted:
                deepLinkErrorMessage = "That receipt is no longer available."
            case .cancelled:
                break
            case .failed(let message):
                deepLinkErrorMessage = message
            }
        }
    }

}
