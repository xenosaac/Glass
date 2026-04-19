import Foundation
import Security

/// Minimal Keychain wrapper scoped to storing one payload per (service, account).
/// Not a general-purpose library — kept intentionally small for the single
/// Gmail token blob.
enum Keychain {
 enum KeychainError: Error, LocalizedError {
 case status(OSStatus)
 case notFound

 var errorDescription: String? {
 switch self {
 case .status(let s): return "Keychain error (\(s))"
 case .notFound: return "Keychain item not found"
 }
 }
 }

 /// Store `data` under `(service, account)`. Any existing item is replaced.
 static func store(_ data: Data, service: String, account: String) throws {
 let base: [String: Any] = [
 kSecClass as String: kSecClassGenericPassword,
 kSecAttrService as String: service,
 kSecAttrAccount as String: account,
 ]
 // Delete + add. Simpler than SecItemUpdate for a single-value blob.
 SecItemDelete(base as CFDictionary)
 var add = base
 add[kSecValueData as String] = data
 add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
 let status = SecItemAdd(add as CFDictionary, nil)
 guard status == errSecSuccess else { throw KeychainError.status(status) }
 }

 /// Load the data stored under `(service, account)`, or throw `notFound`.
 static func load(service: String, account: String) throws -> Data {
 let query: [String: Any] = [
 kSecClass as String: kSecClassGenericPassword,
 kSecAttrService as String: service,
 kSecAttrAccount as String: account,
 kSecReturnData as String: true,
 kSecMatchLimit as String: kSecMatchLimitOne,
 ]
 var result: CFTypeRef?
 let status = SecItemCopyMatching(query as CFDictionary, &result)
 if status == errSecItemNotFound { throw KeychainError.notFound }
 guard status == errSecSuccess, let data = result as? Data else {
 throw KeychainError.status(status)
 }
 return data
 }

 /// Delete the stored item. No-op if already absent.
 static func delete(service: String, account: String) throws {
 let query: [String: Any] = [
 kSecClass as String: kSecClassGenericPassword,
 kSecAttrService as String: service,
 kSecAttrAccount as String: account,
 ]
 let status = SecItemDelete(query as CFDictionary)
 guard status == errSecSuccess || status == errSecItemNotFound else {
 throw KeychainError.status(status)
 }
 }
}
