import Foundation
import Security

/// Where secret access keys are kept.
protocol SecretStore {
    func set(_ secret: String, for account: String) throws
    func get(_ account: String) -> String?
    func delete(_ account: String)
}

/// Secret access keys live in the macOS Keychain (replaces Windows DPAPI).
struct KeychainSecretStore: SecretStore {
    func set(_ secret: String, for account: String) throws { try Keychain.set(secret, for: account) }
    func get(_ account: String) -> String? { Keychain.get(account) }
    func delete(_ account: String) { Keychain.delete(account) }
}

/// In-memory secrets, used by tests and the smoke test.
final class InMemorySecretStore: SecretStore {
    private var secrets: [String: String] = [:]
    func set(_ secret: String, for account: String) throws { secrets[account] = secret }
    func get(_ account: String) -> String? { secrets[account] }
    func delete(_ account: String) { secrets[account] = nil }
}

enum Keychain {
    static let service = "io.cloud-atlas.Atlas"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func set(_ secret: String, for account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(secret.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AWSError(code: "KeychainError", message: SecCopyErrorMessageString(status, nil) as String? ?? "\(status)", status: Int(status))
        }
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Account metadata persisted as JSON in ~/Library/Application Support/Atlas.
struct AccountStore {
    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atlas", isDirectory: true)
    }

    var folder: URL = Self.defaultFolder

    private var file: URL {
        try? PrivateFile.createFolder(folder)
        return folder.appendingPathComponent("accounts.json")
    }

    func load() -> [AwsAccount] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([AwsAccount].self, from: data)) ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ accounts: [AwsAccount]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(accounts) {
            // Account names and access key IDs: readable only by the user.
            try? PrivateFile.write(data, to: file)
        }
    }
}
