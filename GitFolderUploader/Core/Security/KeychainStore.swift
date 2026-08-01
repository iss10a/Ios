//
//  KeychainStore.swift
//  GitFolderUploader
//
//  Minimal, dependency-free Keychain wrapper used to persist the GitHub
//  access token. Values are stored with `kSecAttrAccessibleAfterFirstUnlock`
//  so background upload jobs can still authenticate while the device is locked.
//

import Foundation
import Security

struct KeychainStore {

    enum Key: String {
        case accessToken = "github.access.token"
        case tokenKind = "github.access.token.kind"
        case oauthClientID = "github.oauth.client.id"
    }

    private let service: String

    init(service: String = "com.gitfolderuploader.credentials") {
        self.service = service
    }

    // MARK: - String helpers

    func string(for key: Key) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: Key) {
        guard let value = value, !value.isEmpty else {
            remove(key)
            return
        }
        set(Data(value.utf8), for: key)
    }

    // MARK: - Data primitives

    func data(for key: Key) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    func set(_ data: Data, for key: Key) {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func remove(_ key: Key) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    func removeAll() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
    }

    private func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
