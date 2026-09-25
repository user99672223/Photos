import SwiftUI
import SwiftData
import BackgroundTasks
import UIKit

@MainActor var globalStore: VaultStore?

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        HiDriveClient.backgroundCompletionHandler = completionHandler
    }
}

@main
struct PhotoVaultApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: VaultStore
    private let container: ModelContainer

    init() {
        let container = PhotoVaultApp.makeContainer()
        self.container = container
        let store = VaultStore(container: container)
        _store = StateObject(wrappedValue: store)
        globalStore = store
        PhotoVaultApp.registerBackgroundTask()
    }

    // A store the current schema cannot open is removed and starts empty; "Rebuild local index"
    // (or the next sync) restores everything from the cloud journal.
    static func makeContainer() -> ModelContainer {
        if let container = try? ModelContainer(for: Asset.self, SeenJournalFile.self, UploadJob.self) {
            return container
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
        }
        return try! ModelContainer(for: Asset.self, SeenJournalFile.self, UploadJob.self)
    }

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.example.photovault.backup", using: nil) { task in
            PhotoVaultApp.scheduleBackgroundTask()
            let processing = task as! BGProcessingTask
            let work = Task { @MainActor in
                guard let store = globalStore, store.onboarded else {
                    processing.setTaskCompleted(success: true)
                    return
                }
                await store.backupNow()
                await store.syncNow()
                await store.purgeOldTombstones()
                // Bounded slice of the thumbnail warm-up; it stops early if the task expires.
                await store.warmup.runSlice(limit: 400)
                processing.setTaskCompleted(success: !Task.isCancelled)
            }
            processing.expirationHandler = {
                work.cancel()
            }
        }
    }

    static func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: "com.example.photovault.backup")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = AppSettings.chargingOnlyBackup
        try? BGTaskScheduler.shared.submit(request)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .modelContainer(container)
                .preferredColorScheme(nil)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard store.onboarded else { return }
                store.startObservingLibraryIfAuthorized()
                Task {
                    await store.syncNow()
                    await store.backupNow()
                    store.startWarmupIfAllowed()
                }
            case .background:
                store.warmup.stop()
                PhotoVaultApp.scheduleBackgroundTask()
            default:
                break
            }
        }
    }
}
