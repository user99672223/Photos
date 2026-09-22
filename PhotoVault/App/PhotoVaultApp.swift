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
        let container = try! ModelContainer(for: Asset.self, SeenJournalFile.self, UploadJob.self)
        self.container = container
        let store = VaultStore(container: container)
        _store = StateObject(wrappedValue: store)
        globalStore = store
        PhotoVaultApp.registerBackgroundTask()
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
                processing.setTaskCompleted(success: true)
            }
            processing.expirationHandler = {
                work.cancel()
                processing.setTaskCompleted(success: false)
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
                }
            case .background:
                PhotoVaultApp.scheduleBackgroundTask()
            default:
                break
            }
        }
    }
}
