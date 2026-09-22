import Foundation
import Security

enum KeychainStore {
    private static let service = "com.example.photovault"

    static func set(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func get(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func setString(_ value: String, account: String) {
        set(Data(value.utf8), account: account)
    }

    static func getString(account: String) -> String? {
        guard let data = get(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// Vault identity: master key + device id, both created on first run.
enum VaultKeys {
    static var masterKey: Data? { KeychainStore.get(account: "masterKey") }

    static func createMasterKey() -> Data {
        var key = Data(count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        KeychainStore.set(key, account: "masterKey")
        return key
    }

    static func restoreMasterKey(recoveryString: String) -> Data? {
        guard let key = Base32.decode(recoveryString), key.count == 32 else { return nil }
        KeychainStore.set(key, account: "masterKey")
        return key
    }

    static func recoveryString(for key: Data) -> String {
        let raw = Base32.encode(key)
        var grouped = ""
        for (i, c) in raw.enumerated() {
            if i > 0 && i % 4 == 0 { grouped.append(" ") }
            grouped.append(c)
        }
        return grouped
    }

    static var deviceId: String {
        if let existing = KeychainStore.getString(account: "deviceId") { return existing }
        let id = UUID().uuidString.lowercased()
        KeychainStore.setString(id, account: "deviceId")
        return id
    }

    static func destroyVault() {
        KeychainStore.delete(account: "masterKey")
    }
}
