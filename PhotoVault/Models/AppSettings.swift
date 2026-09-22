import Foundation

enum CellularPolicy: String, CaseIterable, Identifiable {
    case always
    case ask
    case wifiOnly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: return "Always"
        case .ask: return "Ask"
        case .wifiOnly: return "Wi-Fi only"
        }
    }
}

// Thin typed wrapper over UserDefaults so engines (non-View code) share the same settings as the UI.
enum AppSettings {
    static let defaults = UserDefaults.standard

    static var wifiOnlyBackup: Bool {
        get { defaults.object(forKey: "wifiOnlyBackup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wifiOnlyBackup") }
    }

    static var chargingOnlyBackup: Bool {
        get { defaults.bool(forKey: "chargingOnlyBackup") }
        set { defaults.set(newValue, forKey: "chargingOnlyBackup") }
    }

    static var includeVideos: Bool {
        get { defaults.object(forKey: "includeVideos") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "includeVideos") }
    }

    static var autoBackupEnabled: Bool {
        get { defaults.bool(forKey: "autoBackupEnabled") }
        set { defaults.set(newValue, forKey: "autoBackupEnabled") }
    }

    // Set when the vault is created or restored; an install upgraded from an older build pins it on first read.
    static var autoBackupAfter: Date {
        get {
            if let date = defaults.object(forKey: "autoBackupAfter") as? Date { return date }
            let now = Date()
            defaults.set(now, forKey: "autoBackupAfter")
            return now
        }
        set { defaults.set(newValue, forKey: "autoBackupAfter") }
    }

    // Candidates need creationDate > this instant: the start of the cutoff day, local time.
    static var autoBackupCutoff: Date {
        Calendar.current.startOfDay(for: autoBackupAfter)
    }

    static var originalsCacheCapBytes: Int64 {
        get {
            let value = defaults.object(forKey: "originalsCacheCapBytes") as? Int64
            return value ?? 2_000_000_000
        }
        set { defaults.set(newValue, forKey: "originalsCacheCapBytes") }
    }

    static var cellularPolicy: CellularPolicy {
        get { CellularPolicy(rawValue: defaults.string(forKey: "cellularPolicy") ?? "") ?? .wifiOnly }
        set { defaults.set(newValue.rawValue, forKey: "cellularPolicy") }
    }

    static var onboardingComplete: Bool {
        get { defaults.bool(forKey: "onboardingComplete") }
        set { defaults.set(newValue, forKey: "onboardingComplete") }
    }
}
