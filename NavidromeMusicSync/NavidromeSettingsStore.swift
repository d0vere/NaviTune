import Foundation
import Security

struct NavidromeSettings {
    let server: String
    let username: String
    let password: String
}

enum NavidromeSettingsStore {
    private static let serverKey = "navidrome.server"
    private static let usernameKey = "navidrome.username"
    private static let keychainService = "com.d0vere.NavidromeMusicSync.navidrome"
    private static let passwordAccount = "password"

    static func load() -> NavidromeSettings {
        let defaults = UserDefaults.standard
        return NavidromeSettings(
            server: defaults.string(forKey: serverKey) ?? "",
            username: defaults.string(forKey: usernameKey) ?? "",
            password: loadPassword() ?? ""
        )
    }

    static func save(server: String, username: String, password: String) {
        let defaults = UserDefaults.standard
        defaults.set(server, forKey: serverKey)
        defaults.set(username, forKey: usernameKey)
        savePassword(password)
    }

    private static func savePassword(_ password: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: passwordAccount
        ]

        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func loadPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: passwordAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
