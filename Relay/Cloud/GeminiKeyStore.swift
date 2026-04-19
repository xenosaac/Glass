import Foundation

/// Keychain wrapper for the Google Gemini API key used by the cloud
/// fallback path. Thin — one item per (service, account) — matching the
/// shape of `Gmail/Keychain.swift`'s single-value blob storage.
///
/// Flow:
/// `CloudFallbackSection` saves / removes here on user action.
/// `RelayConfig` reads here on app init (Keychain wins over env var so
/// Settings edits persist across relaunches).
/// `AgentCore` reads `RelayConfig.shared.geminiAPIKey` at each
/// cloud-fallback attempt (not here directly) so mid-session key
/// changes take effect without tearing down the session.
enum GeminiKeyStore {
 private static let service = "com.isaac.relay.gemini"
 private static let account = "api_key"

 /// Persist `key` to the Keychain. Replaces any existing value.
 static func save(_ key: String) throws {
 guard let data = key.data(using: .utf8) else { return }
 try Keychain.store(data, service: service, account: account)
 }

 /// Load the persisted key, or `nil` if none is stored.
 static func load() -> String? {
 guard let data = try? Keychain.load(service: service, account: account) else {
 return nil
 }
 return String(data: data, encoding: .utf8)
 }

 /// Remove the stored key. No-op if already absent.
 static func delete() {
 try? Keychain.delete(service: service, account: account)
 }
}
