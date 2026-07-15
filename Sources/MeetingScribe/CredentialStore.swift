import Foundation
import Security

enum KeychainCredentialError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .status(status):
            "A credencial não pôde ser salva no Chaves do macOS (código \(status))."
        }
    }
}

struct KeychainCredentialStore {
    let service: String
    let account: String

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCredentialError.status(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialError.status(addStatus)
        }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum OpenAITokenStore {
    private static let store = KeychainCredentialStore(
        service: "local.gabriel.pontograva.openai",
        account: "api-key"
    )

    static func load() -> String? { store.load() }
    static func save(_ token: String) throws { try store.save(token) }
    static func delete() { store.delete() }
}
