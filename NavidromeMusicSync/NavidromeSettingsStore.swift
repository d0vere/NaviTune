import Foundation
import Security

struct NavidromeSettings: Codable {
    let server: String
    let username: String
    let password: String
}

enum NavidromeSettingsStore {
    private static let serverKey = "navidrome.server"
    private static let usernameKey = "navidrome.username"
    private static let keychainService = "com.d0vere.NaviTune.navidrome"
    private static let passwordAccount = "password"
    private static let settingsFilename = "NavidromeSettings.plist"

    static func load() -> NavidromeSettings {
        // SideStore re-signing can change keychain accessibility. Documents is
        // preserved together with the pairing file, so use the protected plist
        // as the durable source and keep UserDefaults/Keychain as fallbacks.
        if let fileSettings = loadFromDocuments() {
            return fileSettings
        }

        let defaults = UserDefaults.standard
        return NavidromeSettings(
            server: defaults.string(forKey: serverKey) ?? "",
            username: defaults.string(forKey: usernameKey) ?? "",
            password: loadPassword() ?? ""
        )
    }

    static func save(server: String, username: String, password: String) {
        let settings = NavidromeSettings(server: server, username: username, password: password)

        let defaults = UserDefaults.standard
        defaults.set(server, forKey: serverKey)
        defaults.set(username, forKey: usernameKey)
        savePassword(password)
        saveToDocuments(settings)
    }

    private static func settingsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(settingsFilename)
    }

    private static func saveToDocuments(_ settings: NavidromeSettings) {
        guard let url = settingsURL() else { return }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(settings)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            // The primary app workflow must remain usable if durable settings
            // persistence fails; UserDefaults/Keychain are still attempted.
        }
    }

    private static func loadFromDocuments() -> NavidromeSettings? {
        guard let url = settingsURL(),
              let data = try? Data(contentsOf: url),
              let settings = try? PropertyListDecoder().decode(NavidromeSettings.self, from: data)
        else { return nil }
        return settings
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
            kSecReturnData as String] = true
        var fixedQuery = query
        fixedQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(fixedQuery as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
