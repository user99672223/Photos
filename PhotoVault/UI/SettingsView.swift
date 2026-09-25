import SwiftUI
import LocalAuthentication

struct SettingsView: View {
    @EnvironmentObject var store: VaultStore
    @AppStorage("wifiOnlyBackup") private var wifiOnly = true
    @AppStorage("chargingOnlyBackup") private var chargingOnly = false
    @AppStorage("includeVideos") private var includeVideos = true
    @AppStorage("autoBackupEnabled") private var autoBackupEnabled = false
    @AppStorage("cellularPolicy") private var cellularPolicy = CellularPolicy.wifiOnly.rawValue
    @State private var autoBackupAfter = AppSettings.autoBackupAfter
    @State private var cacheCapGB: Double = Double(AppSettings.originalsCacheCapBytes) / 1_000_000_000
    @State private var cacheUsage: Int64 = 0
    @State private var showRecovery = false
    @State private var recoveryString: String?
    @State private var authError: String?
    @State private var connecting = false
    @State private var signInPage: SignInPage?
    @State private var manualCode = ""
    @State private var showManualCode = false
    @State private var confirmRebuild = false
    @State private var diagnostics = DiagnosticsSnapshot()
    @State private var diagnosticsTick = 0

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                Section("API credentials") {
                    NavigationLink("View or replace") {
                        CredentialsView()
                    }
                }
                Section("Backup rules") {
                    Toggle("Wi-Fi only", isOn: $wifiOnly)
                    Toggle("Only while charging", isOn: $chargingOnly)
                    Toggle("Include videos", isOn: $includeVideos)
                    Toggle("Automatic backup", isOn: $autoBackupEnabled)
                    DatePicker("Only photos taken after", selection: $autoBackupAfter,
                               in: ...Date(), displayedComponents: .date)
                }
                Section("Originals cache") {
                    Picker("Cache limit", selection: $cacheCapGB) {
                        Text("1 GB").tag(1.0)
                        Text("2 GB").tag(2.0)
                        Text("5 GB").tag(5.0)
                        Text("10 GB").tag(10.0)
                    }
                    LabeledContent("In use", value: ByteCountFormatter.string(fromByteCount: cacheUsage, countStyle: .file))
                }
                Section("Originals on cellular") {
                    Picker("Download originals", selection: $cellularPolicy) {
                        ForEach(CellularPolicy.allCases) { policy in
                            Text(policy.label).tag(policy.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Security") {
                    Button("Show recovery string") {
                        Task { await revealRecovery() }
                    }
                }
                syncSection
                maintenanceSection
                diagnosticsSection
                Section {
                    LabeledContent("Version", value: appVersion)
                    if let error = store.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: cacheCapGB) { _, newValue in
                AppSettings.originalsCacheCapBytes = Int64(newValue * 1_000_000_000)
                let cap = AppSettings.originalsCacheCapBytes
                Task {
                    await Task.detached { CacheManager.enforceOriginalsCap(cap) }.value
                    cacheUsage = await Task.detached { CacheManager.originalsCacheSize() }.value
                }
            }
            .onChange(of: autoBackupEnabled) { _, enabled in
                if enabled {
                    Task { await store.backupNow() }
                }
            }
            .onChange(of: autoBackupAfter) { _, newValue in
                AppSettings.autoBackupAfter = newValue
                Task { await store.refreshDeviceItems() }
            }
            .task {
                cacheUsage = await Task.detached { CacheManager.originalsCacheSize() }.value
            }
            .task(id: diagnosticsTick) {
                diagnostics = await store.diagnostics()
            }
            .onAppear { diagnosticsTick += 1 }
            .sheet(isPresented: $showRecovery) {
                if let recoveryString {
                    RecoverySheet(recoveryString: recoveryString)
                }
            }
            .alert("Authorization code", isPresented: $showManualCode) {
                TextField("Code", text: $manualCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Connect") {
                    let code = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    manualCode = ""
                    Task { await submitCode(code) }
                }
                Button("Cancel", role: .cancel) { manualCode = "" }
            } message: {
                Text("Copy the code HiDrive showed you and paste it here (valid for 5 minutes)")
            }
            .confirmationDialog("Rebuild local index?", isPresented: $confirmRebuild, titleVisibility: .visible) {
                Button("Rebuild", role: .destructive) {
                    Task { await store.rebuildLocalIndex() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes the local index and cached thumbnails on this iPhone, then downloads the journal again. Your vault key, sign-in and settings are kept. Nothing in the cloud changes.")
            }
        }
        // HiDrive shows the code on its page ("oob"); closing the sheet leads straight to the code entry.
        .sheet(item: $signInPage, onDismiss: { showManualCode = true }) { page in
            SafariView(url: page.url) { signInPage = nil }
                .ignoresSafeArea()
        }
        .alert("Authentication failed",
               isPresented: Binding(get: { authError != nil }, set: { if !$0 { authError = nil } })) {
            Button("OK") { authError = nil }
        } message: {
            Text(authError ?? "")
        }
    }

    private var accountSection: some View {
        Section("STRATO account") {
            if store.isConnected {
                LabeledContent("Connected as", value: store.accountAlias ?? "HiDrive user")
                Button("Disconnect", role: .destructive) {
                    Task { await store.disconnect() }
                }
            } else {
                Button {
                    openSignIn()
                } label: {
                    if connecting { ProgressView() } else { Text("Connect STRATO HiDrive") }
                }
                .disabled(connecting)
                Button("Paste authorization code instead") {
                    showManualCode = true
                }
            }
        }
    }

    private var syncSection: some View {
        Section {
            Button {
                Task {
                    await store.syncNow()
                    await store.backupNow(force: true)
                    store.startWarmupIfAllowed()
                    diagnosticsTick += 1
                }
            } label: {
                if store.isSyncing {
                    HStack {
                        Text("Syncing \(store.syncDone)/\(store.syncTotal)")
                        Spacer()
                        ProgressView()
                    }
                } else {
                    Text("Sync now")
                }
            }
            .disabled(store.isSyncing || store.isRebuilding)
        }
    }

    private var maintenanceSection: some View {
        Section {
            Button("Rebuild local index", role: .destructive) {
                confirmRebuild = true
            }
            .disabled(store.isSyncing || store.isRebuilding || store.isBackingUp)
            if store.isRebuilding {
                HStack {
                    Text("Rebuilding…")
                    Spacer()
                    ProgressView()
                }
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text("Use this if the library looks incomplete or the app was interrupted during a sync.")
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Assets", value: "\(diagnostics.liveAssets) (+\(diagnostics.deletedAssets) in trash)")
            LabeledContent("Sections", value: "\(diagnostics.sections)")
            LabeledContent("Thumbnails cached", value: "\(diagnostics.thumbsCached) / \(diagnostics.liveAssets + diagnostics.deletedAssets)")
            LabeledContent("Last sync", value: "\(seconds(diagnostics.lastSyncDuration)), \(diagnostics.lastSyncFiles) files merged")
            LabeledContent("Thumbnail queue", value: "\(diagnostics.thumbQueued) queued, \(diagnostics.thumbRunning) running")
            LabeledContent("Thumbnails fetched", value: "\(diagnostics.thumbFetched) (\(diagnostics.thumbFailures) failed)")
            LabeledContent("Warm-up this session", value: "\(diagnostics.warmupDone)")
            LabeledContent("Backup queue", value: "\(diagnostics.backupQueue)")
            LabeledContent("Index load", value: seconds(diagnostics.indexLoadTime))
            LabeledContent("Timeline build", value: seconds(diagnostics.timelineBuildTime))
            Button("Refresh") { diagnosticsTick += 1 }
        }
    }

    private func seconds(_ interval: TimeInterval) -> String {
        interval < 1 ? String(format: "%.0f ms", interval * 1000) : String(format: "%.1f s", interval)
    }

    private func openSignIn() {
        do {
            signInPage = SignInPage(url: try OAuthWebFlow.authorizeURL())
        } catch {
            authError = error.localizedDescription
        }
    }

    private func submitCode(_ code: String) async {
        guard !code.isEmpty else { return }
        connecting = true
        defer { connecting = false }
        do {
            try await HiDriveAuth.shared.exchangeCode(code)
            try await store.client.ensureLayout(deviceId: VaultKeys.deviceId)
            await store.refreshConnectionState()
            await store.configureFetcher()
        } catch {
            authError = "Could not connect: \(error.localizedDescription)"
        }
    }

    private func revealRecovery() async {
        guard let key = VaultKeys.masterKey else { return }
        let context = LAContext()
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: "Reveal the vault recovery string")
            if ok {
                recoveryString = VaultKeys.recoveryString(for: key)
                showRecovery = true
            }
        } catch {
            authError = "Face ID / passcode check failed."
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

struct RecoverySheet: View {
    let recoveryString: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Anyone with this string can decrypt your photos. Store it somewhere safe.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Text(recoveryString)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if let qr = QRCode.image(for: recoveryString.replacingOccurrences(of: " ", with: "")) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Recovery string")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct CredentialsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var clientId = HiDriveAuth.credentials()?.id ?? ""
    @State private var clientSecret = HiDriveAuth.credentials()?.secret ?? ""

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $clientId)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Client secret", text: $clientSecret)
            } footer: {
                Text("Register a \"native\" app with redirect URI \"oob\" at developer.hidrive.com. Stored in this iPhone's Keychain only.")
            }
            Button("Save") {
                HiDriveAuth.storeCredentials(id: clientId.trimmingCharacters(in: .whitespaces),
                                             secret: clientSecret.trimmingCharacters(in: .whitespaces))
                dismiss()
            }
            .disabled(clientId.isEmpty || clientSecret.isEmpty)
        }
        .navigationTitle("API credentials")
    }
}
