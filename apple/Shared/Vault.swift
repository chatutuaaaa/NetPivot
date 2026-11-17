import CryptoKit
import Foundation
import Security

enum Vault {
    private static func query(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "NetPivot",
            kSecAttrAccessGroup as String: Settings.value("NetPivotKeychainGroup"),
            kSecAttrAccount as String: name
        ]
    }

    static func read(_ name: String) throws -> Data? {
        var q = query(name)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NetPivotError("无法读取设备凭据，请检查设备是否已解锁。")
        }
        return data
    }

    static func insert(_ name: String, value: Data) throws -> Data {
        var q = query(name)
        q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try read(name) { return existing }
        guard status == errSecSuccess else { throw NetPivotError("无法保存设备凭据，请检查应用签名。") }
        return value
    }

    static func save(_ name: String, value: Data) throws {
        let status = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound { _ = try insert(name, value: value) }
        else if status != errSecSuccess { throw NetPivotError("无法更新连接配置。") }
    }

    static func identity() throws -> Curve25519.Signing.PrivateKey {
        if let data = try read("identity") { return try .init(rawRepresentation: data) }
        return try .init(rawRepresentation: insert("identity", value: Curve25519.Signing.PrivateKey().rawRepresentation))
    }

    static func tunnelKey(_ id: String) throws -> Data {
        if let data = try read("wg."+id) { return data }
        return try insert("wg."+id, value: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
    }

    static func loadSnapshot(_ id: String) throws -> TunnelSnapshot {
        guard let data = try read("configuration."+id) else { throw NetPivotError("找不到连接配置。") }
        return try JSONDecoder().decode(TunnelSnapshot.self, from: data)
    }

    static func saveSnapshot(_ snapshot: TunnelSnapshot) throws {
        try save("configuration."+snapshot.networkId, value: JSONEncoder().encode(snapshot))
    }

    static var preferences: UserDefaults {
        UserDefaults(suiteName: Settings.value("NetPivotAppGroup")) ?? .standard
    }
}
