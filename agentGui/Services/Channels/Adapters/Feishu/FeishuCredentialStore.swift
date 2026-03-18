import Foundation
import Security

struct FeishuCredentials: Equatable, Sendable {
    let appID: String
    let appSecret: String
}

protocol FeishuCredentialBacking: AnyObject {
    func store(value: String, for key: String) throws
    func loadValue(for key: String) throws -> String?
    func removeValue(for key: String) throws
}

final class FeishuCredentialStore {
    enum CredentialError: Error {
        case incompleteCredentials
    }

    private let backend: any FeishuCredentialBacking
    private let appIDKey = "feishu.app_id"
    private let appSecretKey = "feishu.app_secret"

    init(backend: any FeishuCredentialBacking = KeychainFeishuCredentialBackend()) {
        self.backend = backend
    }

    func save(appID: String, appSecret: String) throws {
        try backend.store(value: appID, for: appIDKey)
        try backend.store(value: appSecret, for: appSecretKey)
    }

    func load() throws -> FeishuCredentials? {
        guard let appID = try backend.loadValue(for: appIDKey),
              let appSecret = try backend.loadValue(for: appSecretKey) else {
            return nil
        }
        guard !appID.isEmpty, !appSecret.isEmpty else {
            throw CredentialError.incompleteCredentials
        }
        return FeishuCredentials(appID: appID, appSecret: appSecret)
    }

    func clear() throws {
        try backend.removeValue(for: appIDKey)
        try backend.removeValue(for: appSecretKey)
    }
}

final class KeychainFeishuCredentialBackend: FeishuCredentialBacking {
    private let service = "com.feint.agentGui.feishu"

    func store(value: String, for key: String) throws {
        let encoded = Data(value.utf8)
        let query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)
        var payload = query
        payload[kSecValueData as String] = encoded
        let status = SecItemAdd(payload as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func loadValue(for key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    func removeValue(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

final class InMemoryFeishuCredentialBackend: FeishuCredentialBacking {
    private var storage: [String: String] = [:]

    func store(value: String, for key: String) throws {
        storage[key] = value
    }

    func loadValue(for key: String) throws -> String? {
        storage[key]
    }

    func removeValue(for key: String) throws {
        storage[key] = nil
    }
}