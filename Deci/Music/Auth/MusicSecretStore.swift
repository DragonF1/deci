import Foundation
import os
import Security

/// Where the sign-in cookies live between launches. Nothing else may persist them.
protocol MusicSecretStore: Sendable {
    func load() -> Data?
    func save(_ data: Data) throws
    /// Removes the item. Throws when the Keychain refuses; an item that is already gone is not a failure.
    func delete() throws
}

/// One generic-password item in the classic login keychain (no data-protection keychain,
/// so it needs no keychain-access-groups entitlement).
struct KeychainSecretStore: MusicSecretStore {
    struct KeychainError: Error, Equatable {
        let status: OSStatus
    }

    static let defaultService = "com.abraham.Deci.music"
    static let defaultAccount = "cookies"

    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "Music")

    let service: String
    let account: String

    init(service: String = defaultService, account: String = defaultAccount) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            Self.logger.error("Keychain read failed: \(status)")
            return nil
        }
    }

    func save(_ data: Data) throws {
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            Self.logger.error("Keychain update failed: \(update)")
            throw KeychainError(status: update)
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Deci YouTube Music sign-in"
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else {
            Self.logger.error("Keychain add failed: \(add)")
            throw KeychainError(status: add)
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Self.logger.error("Keychain delete failed: \(status)")
            throw KeychainError(status: status)
        }
    }
}
