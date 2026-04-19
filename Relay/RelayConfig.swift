import Foundation

/// App-wide configuration for API keys and feature flags.
///
/// Gemini key precedence: **Keychain first** (via `GeminiKeyStore`), then a
/// bundled local developer secrets plist, then a local environment variable
/// bootstrap (`GEMINI_API_KEY`).
///
/// Startup behavior:
/// If Keychain already has a key, that wins.
/// If Keychain is empty and a bundled local secret or env var is present,
/// we seed the Keychain once so the value appears in Settings and survives
/// relaunches.
///
/// Settings edits still persist across relaunches without an Xcode rebuild.
/// Local developer secrets remain opt-in and non-repo: a build step copies
/// `$HOME/.config/relay/RelayDeveloperSecrets.plist` into the app bundle when
/// present. Env var remains a developer convenience (Xcode scheme → Run →
/// Environment Variables).
///
/// the previous `braveSearchAPIKey` field was removed
/// when `WebSearchTool` was retired in favor of Gemini Google Search
/// grounding. Web search now happens via the cloud handoff path with
/// Gemini's built-in `googleSearch` tool — no third-party search API key
/// required. The Gemini key already in this struct is the only key the
/// app reads at startup.
///
/// Tools degrade gracefully if keys are missing (return descriptive errors, never crash).
public final class RelayConfig: @unchecked Sendable {
 public static var shared = RelayConfig()

 private static let developerSecretsResource = "RelayDeveloperSecrets"
 private static let developerSecretsExtension = "plist"
 private static let geminiSecretsKey = "GeminiAPIKey"

 public var geminiAPIKey: String

 /// Whether MCP tools are enabled globally.
 public var mcpEnabled: Bool

 /// Default timeout for MCP HTTP requests (seconds).
 public var mcpDefaultTimeout: TimeInterval

 private init() {
 geminiAPIKey = Self.resolveGeminiKey()
 mcpEnabled = ProcessInfo.processInfo.environment["MCP_ENABLED"] != "false"
 mcpDefaultTimeout = 30
 }

 /// Re-read the Gemini key using the same precedence as startup (Keychain ->
 /// bundled local developer secrets -> env var) into `shared.geminiAPIKey`.
 /// Called by Settings after Save / Remove so `AgentCore`'s per-fallback
 /// read picks up the latest resolved value without a session reload.
 public static func reloadGeminiKey() {
 shared.geminiAPIKey = resolveGeminiKey()
 }

 private static func resolveGeminiKey() -> String {
 resolvedGeminiKey(
 storedKey: GeminiKeyStore.load(),
 bundledKey: bundledGeminiKey(),
 envKey: ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
 persist: { key in try? GeminiKeyStore.save(key) }
 )
 }

 static func resolvedGeminiKey(
 storedKey: String?,
 bundledKey: String?,
 envKey: String?,
 persist: (String) -> Void = { _ in }
 ) -> String {
 if let stored = normalizedGeminiKey(storedKey), !stored.isEmpty {
 return stored
 }

 if let bundled = normalizedGeminiKey(bundledKey), !bundled.isEmpty {
 persist(bundled)
 return bundled
 }

 if let env = normalizedGeminiKey(envKey), !env.isEmpty {
 persist(env)
 return env
 }

 return ""
 }

 private static func bundledGeminiKey(bundle: Bundle = .main) -> String? {
 guard
 let url = bundle.url(
 forResource: developerSecretsResource,
 withExtension: developerSecretsExtension
 ),
 let raw = NSDictionary(contentsOf: url) as? [String: Any],
 let key = raw[geminiSecretsKey] as? String
 else {
 return nil
 }

 return normalizedGeminiKey(key)
 }

 private static func normalizedGeminiKey(_ key: String?) -> String? {
 let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
 return trimmed.isEmpty ? nil : trimmed
 }
}
