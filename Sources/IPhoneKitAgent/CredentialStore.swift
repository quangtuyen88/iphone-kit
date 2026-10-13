import Foundation
import Security
import LocalAuthentication
import IPhoneKitCore

public enum ModelCredentialStore {
    private static let service = "dev.iphonekit.model-credentials"
    public static func validate(_ key: String) throws {
        guard key.utf8.count <= 4096, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw KitError("INVALID_API_KEY", "API keys must contain printable ASCII without spaces or control characters.")
        }
    }
    private static func query(_ configuration: ProviderConfiguration) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: try configuration.credentialAccount(), kSecAttrSynchronizable as String: false]
    }
    public static func load(for configuration: ProviderConfiguration) throws -> String? {
        var fields = try query(configuration)
        fields[kSecReturnData as String] = true
        fields[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
                context.interactionNotAllowed = true
                fields[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(fields as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KitError("KEYCHAIN_UNAVAILABLE", "Cannot read this provider's saved API key. Unlock your login Keychain.")
        }
        return value
    }
    public static func save(_ key: String, for configuration: ProviderConfiguration) throws {
        try validate(key)
        guard !key.isEmpty else { throw KitError("INVALID_API_KEY", "Enter an API key, or leave an existing saved key unchanged.") }
        let fields = try query(configuration)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(fields as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KitError("KEYCHAIN_UNAVAILABLE", "Cannot update the provider API key.") }
        let status = SecItemAdd(fields.merging(attributes) { _, value in value } as CFDictionary, nil)
        guard status == errSecSuccess else { throw KitError("KEYCHAIN_UNAVAILABLE", "Cannot save the provider API key.") }
    }
    public static func delete(for configuration: ProviderConfiguration) throws {
        let status = SecItemDelete(try query(configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KitError("KEYCHAIN_UNAVAILABLE", "Cannot remove the provider API key.")
        }
    }
}
