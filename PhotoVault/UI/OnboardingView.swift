import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var store: VaultStore

    enum Step {
        case welcome
        case createVault
        case restoreVault
        case credentials
        case connect
        case photos
        case restoring
    }

    @State private var step: Step = .welcome
    @State private var isRestoreFlow = false
    @State private var newKey: Data?
    @State private var savedChecked = false
    @State private var restoreInput = ""
    @State private var restoreError: String?
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var connecting = false
    @State private var connectError: String?
    @State private var manualCode = ""
    @State private var showManualCode = false

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .welcome: welcome
                case .createVault: createVault
                case .restoreVault: restoreVault
                case .credentials: credentials
                case .connect: connect
                case .photos: photos
                case .restoring: restoring
                }
            }
            .padding()
        }
    }

    private func afterVaultStep() {
        step = HiDriveAuth.credentials() == nil ? .credentials : .connect
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("PhotoVault").font(.largeTitle.bold())
            Text("Private, encrypted photo backup to your own STRATO HiDrive. Originals live only in your cloud, encrypted with a key that never leaves this device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Create new vault") {
                let key = VaultKeys.masterKey ?? VaultKeys.createMasterKey()
                newKey = key
                isRestoreFlow = false
                step = .createVault
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Restore existing vault") {
                isRestoreFlow = true
                step = .restoreVault
            }
            .controlSize(.large)
        }
    }

    private var createVault: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Your recovery string").font(.title2.bold())
                Text("This is the only way to recover your photos if you lose this phone. Write it down or scan the QR code.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let newKey {
                    let recovery = VaultKeys.recoveryString(for: newKey)
                    Text(recovery)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    if let qr = QRCode.image(for: recovery.replacingOccurrences(of: " ", with: "")) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                    }
                }
                Toggle("I saved my recovery string", isOn: $savedChecked)
                    .padding(.top)
                Button("Continue") { afterVaultStep() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!savedChecked)
            }
        }
    }

    private var restoreVault: some View {
        VStack(spacing: 20) {
            Text("Restore vault").font(.title2.bold())
            Text("Paste the 52-character recovery string you wrote down.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("XXXX XXXX XXXX …", text: $restoreInput, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            if let restoreError {
                Text(restoreError).font(.caption).foregroundStyle(.red)
            }
            Button("Continue") {
                if VaultKeys.restoreMasterKey(recoveryString: restoreInput) != nil {
                    store.hasVault = true
                    afterVaultStep()
                } else {
                    restoreError = "That doesn't look like a valid recovery string."
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(restoreInput.isEmpty)
            Spacer()
        }
    }

    private var credentials: some View {
        VStack(spacing: 20) {
            Text("HiDrive API credentials").font(.title2.bold())
            Text("This build has no embedded credentials. Register an app at developer.hidrive.com and paste its client id and secret.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Client ID", text: $clientId)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("Client secret", text: $clientSecret)
                .textFieldStyle(.roundedBorder)
            Button("Continue") {
                HiDriveAuth.storeCredentials(id: clientId.trimmingCharacters(in: .whitespaces),
                                             secret: clientSecret.trimmingCharacters(in: .whitespaces))
                step = .connect
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(clientId.isEmpty || clientSecret.isEmpty)
            Spacer()
        }
    }

    private var connect: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "externaldrive.badge.icloud")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Connect STRATO HiDrive").font(.title2.bold())
            if let connectError {
                Text(connectError).font(.caption).foregroundStyle(.red)
            }
            Button {
                Task { await startOAuth() }
            } label: {
                if connecting { ProgressView() } else { Text("Sign in") }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(connecting)
            Button("Paste authorization code instead") {
                showManualCode = true
            }
            Spacer()
        }
        .alert("Authorization code", isPresented: $showManualCode) {
            TextField("Code", text: $manualCode)
            Button("Connect") {
                Task { await finishConnect(code: manualCode.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func startOAuth() async {
        connecting = true
        defer { connecting = false }
        do {
            let code = try await OAuthWebFlow.shared.authorize()
            await finishConnect(code: code)
        } catch {
            connectError = "Sign-in was cancelled or failed. You can paste the authorization code manually."
        }
    }

    private func finishConnect(code: String) async {
        do {
            try await HiDriveAuth.shared.exchangeCode(code)
            try await store.client.ensureLayout(deviceId: VaultKeys.deviceId)
            await store.refreshConnectionState()
            step = .photos
        } catch {
            connectError = "Could not connect: \(error.localizedDescription)"
        }
    }

    private var photos: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Photo library access").font(.title2.bold())
            Text("PhotoVault needs access to your photos to back them up.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Allow access") {
                Task {
                    _ = await PhotoKitExport.requestAuthorization()
                    if isRestoreFlow {
                        step = .restoring
                        await store.syncNow()
                        finish()
                    } else {
                        finish()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
    }

    private var restoring: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
            Text("Rebuilding your library…").font(.headline)
            if store.restoreTotal > 0 {
                ProgressView(value: Double(store.restoreDone), total: Double(max(store.restoreTotal, 1)))
                Text("\(store.restoreDone) of \(store.restoreTotal) thumbnails")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func finish() {
        AppSettings.onboardingComplete = true
        store.onboarded = true
        store.startObservingLibraryIfAuthorized()
        Task { await store.backupNow() }
    }
}
