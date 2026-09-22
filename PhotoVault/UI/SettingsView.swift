import SwiftUI
import LocalAuthentication

struct SettingsView: View {
    @EnvironmentObject var store: VaultStore
    @AppStorage("wifiOnlyBackup") private var wifiOnly = true
    @AppStorage("chargingOnlyBackup") private var chargingOnly = false
    @AppStorage("includeVideos") private var includeVideos = true
    @AppStorage("cellularPolicy") private var cellularPolicy = CellularPolicy.wifiOnly.rawValue
    @State private var cacheCapGB: Double = Double(AppSettings.originalsCacheCapBytes) / 1_000_000_000
    @State private var cacheUsage: Int64 = 0
    @State private var showRecovery = false
    @State private var recoveryString: String?
    @State private var authError: String?
    @State private var connecting = false
    @State private var manualCode = ""
    @State private var showManualCode = false

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
                Section {
                    Button {
                        Task {
                            await store.syncNow()
                            await store.backupNow(force: true)
                        }
                    } label: {
                        if store.isSyncing {
                            HStack { Text("Syncing…"); Spacer(); ProgressView() }
                        } else {
                            Text("Sync now")
                        }
                    }
                    .disabled(store.isSyncing)
                }
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
                CacheManager.enforceOriginalsCap(AppSettings.originalsCacheCapBytes)
                cacheUsage = CacheManager.originalsCacheSize()
            }
            .onAppear { cacheUsage = CacheManager.originalsCacheSize() }
            .sheet(isPresented: $showRecovery) {
                if let recoveryString {
                    RecoverySheet(recoveryString: recoveryString)
                }
            }
            .alert("Authentication failed", isPresented: .constant(authError != nil)) {
                Button("OK") { authError = nil }
            } message: {
                Text(authError ?? "")
            }
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
                    Task { await connect() }
                } label: {
                    if connecting { ProgressView() } else { Text("Connect STRATO HiDrive") }
                }
                .disabled(connecting)
                Button("Paste authorization code instead") {
                    showManualCode = true
                }
            }
        }
        .alert("Authorization code", isPresented: $showManualCode) {
            TextField("Code", text: $manualCode)
            Button("Connect") {
                Task { await submitManualCode() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        do {
            let code = try await OAuthWebFlow.shared.authorize()
            try await HiDriveAuth.shared.exchangeCode(code)
            try await store.client.ensureLayout(deviceId: VaultKeys.deviceId)
            await store.refreshConnectionState()
        } catch {
            authError = "Could not connect: \(error.localizedDescription)"
        }
    }

    private func submitManualCode() async {
        do {
            try await HiDriveAuth.shared.exchangeCode(manualCode.trimmingCharacters(in: .whitespacesAndNewlines))
            try await store.client.ensureLayout(deviceId: VaultKeys.deviceId)
            await store.refreshConnectionState()
        } catch {
            authError = "Could not connect: \(error.localizedDescription)"
        }
        manualCode = ""
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
                Text("Register an app at developer.hidrive.com to get these.")
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
