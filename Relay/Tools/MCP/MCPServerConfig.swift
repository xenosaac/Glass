import Foundation

/// Configuration for a single MCP server.
public struct MCPServerConfig: Codable, Sendable, Identifiable, Equatable {
 private static let canvasURLHeaderKey = "x-canvas-url"
 private static let whitespace = CharacterSet.whitespacesAndNewlines

 public let id: String
 public let name: String
 public let baseURL: URL
 public var headers: [String: String]
 public var isEnabled: Bool
 public var timeout: TimeInterval

 public init(
 id: String = UUID().uuidString,
 name: String,
 baseURL: URL,
 headers: [String: String] = [:],
 isEnabled: Bool = true,
 timeout: TimeInterval = 30
 ) {
 self.id = id
 self.name = name
 self.baseURL = baseURL
 self.headers = Self.normalizedHeaders(headers)
 self.isEnabled = isEnabled
 self.timeout = timeout
 }

 /// Backward compat: read Authorization header if present.
 public var authHeader: String? { headers["Authorization"] }

 // Migration: decode old configs with single authHeader field
 enum CodingKeys: String, CodingKey {
 case id, name, baseURL, headers, isEnabled, timeout
 case legacyAuthHeader = "authHeader"
 }

 public init(from decoder: Decoder) throws {
 let container = try decoder.container(keyedBy: CodingKeys.self)
 id = try container.decode(String.self, forKey: .id)
 name = try container.decode(String.self, forKey: .name)
 baseURL = try container.decode(URL.self, forKey: .baseURL)
 isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
 timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 30

 // Try new headers dict first, fall back to legacy authHeader
 if let h = try? container.decode([String: String].self, forKey: .headers) {
 headers = Self.normalizedHeaders(h)
 } else if let auth = try? container.decodeIfPresent(String.self, forKey: .legacyAuthHeader), !auth.isEmpty {
 headers = Self.normalizedHeaders(["Authorization": auth])
 } else {
 headers = [:]
 }
 }

 public func encode(to encoder: Encoder) throws {
 var container = encoder.container(keyedBy: CodingKeys.self)
 try container.encode(id, forKey: .id)
 try container.encode(name, forKey: .name)
 try container.encode(baseURL, forKey: .baseURL)
 try container.encode(headers, forKey: .headers)
 try container.encode(isEnabled, forKey: .isEnabled)
 try container.encode(timeout, forKey: .timeout)
 }

 /// Sanitized name for tool namespacing (lowercase, alphanumeric + underscore)
 public var safeName: String {
 name.lowercased()
 .replacingOccurrences(of: " ", with: "_")
 .filter { $0.isLetter || $0.isNumber || $0 == "_" }
 }

 private static func normalizedHeaders(_ headers: [String: String]) -> [String: String] {
 var normalized = headers
 for (key, value) in headers {
 let trimmedValue = value.trimmingCharacters(in: whitespace)
 if isSensitiveHeader(key), trimmedValue != value {
 logSensitiveHeaderNormalization(key: key, removedCharacters: value.count - trimmedValue.count)
 }

 if key.lowercased() == canvasURLHeaderKey {
 normalized[key] = normalizeCanvasAPIURL(trimmedValue)
 } else {
 normalized[key] = trimmedValue
 }
 }
 return normalized
 }

 private static func normalizeCanvasAPIURL(_ raw: String) -> String {
 let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
 guard !trimmed.isEmpty else { return trimmed }

 let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
 guard var components = URLComponents(string: candidate) else { return trimmed }

 switch components.path {
 case "", "/":
 components.path = "/api/v1"
 case "/api", "/api/":
 components.path = "/api/v1"
 case "/api/v1/":
 components.path = "/api/v1"
 default:
 break
 }

 return components.string ?? candidate
 }

 private static func isSensitiveHeader(_ key: String) -> Bool {
 let lower = key.lowercased()
 return lower.contains("authorization")
 || lower.contains("token")
 || lower.contains("secret")
 || lower.contains("api-key")
 || lower.contains("cookie")
 }

 private static func logSensitiveHeaderNormalization(key: String, removedCharacters: Int) {
 guard removedCharacters > 0 else { return }
 print("[MCP][config] normalized sensitive header key=\(key) trimmedChars=\(removedCharacters)")
 }
}

/// Persistence for MCP server configurations.
///
/// Stores configurations in a file-backed envelope. Legacy UserDefaults data
/// is imported once on first load when no file-backed store exists yet.
public actor MCPConfigStore {
 public static let shared = MCPConfigStore()

 private let fileURL: URL
 private let legacyDefaults: UserDefaults
 private let contract = StorageRegistry.contract(for: .mcpConfig)
 private var cache: [MCPServerConfig]?
 private let encoder: JSONEncoder
 private let decoder: JSONDecoder

 public init(
 fileURL: URL = AppPaths.mcpServers,
 legacyDefaults: UserDefaults = .standard
 ) {
 self.fileURL = fileURL
 self.legacyDefaults = legacyDefaults
 let encoder = JSONEncoder()
 encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
 self.encoder = encoder
 self.decoder = JSONDecoder()
 }

 /// Get all configured servers.
 public func allServers() -> [MCPServerConfig] {
 if let cached = cache { return cached }
 let loaded = load
 cache = loaded()
 return loaded()
 }

 /// Get only enabled servers.
 public func enabledServers() -> [MCPServerConfig] {
 allServers().filter { $0.isEnabled }
 }

 /// Get a server by ID.
 public func server(id: String) -> MCPServerConfig? {
 allServers().first { $0.id == id }
 }

 /// Get a server by name.
 public func server(named name: String) -> MCPServerConfig? {
 allServers().first { $0.name == name }
 }

 /// Add a new server configuration.
 public func add(_ config: MCPServerConfig) {
 var servers = allServers()
 // Replace if exists, otherwise append
 if let idx = servers.firstIndex(where: { $0.id == config.id }) {
 servers[idx] = config
 } else {
 servers.append(config)
 }
 save(servers)
 }

 /// Remove a server by ID.
 public func remove(id: String) {
 var servers = allServers()
 servers.removeAll { $0.id == id }
 save(servers)
 }

 /// Enable or disable a server.
 public func setEnabled(_ enabled: Bool, id: String) {
 var servers = allServers()
 if let idx = servers.firstIndex(where: { $0.id == id }) {
 servers[idx].isEnabled = enabled
 save(servers)
 }
 }

 /// Clear all servers and reset to defaults.
 public func reset() {
 try? FileManager.default.removeItem(at: fileURL)
 if let legacyKey = contract.migrationRule.legacyKey {
 legacyDefaults.removeObject(forKey: legacyKey)
 }
 cache = nil
 }

 // MARK: - Private

 private func load() -> [MCPServerConfig] {
 if let data = try? Data(contentsOf: fileURL) {
 if let envelope = try? decoder.decode(VersionedStoreEnvelope<[MCPServerConfig]>.self, from: data) {
 guard envelope.header.isCompatible(with: contract) else {
 _ = try? StorageContractIO.archiveItemIfExists(at: fileURL, storeID: contract.id)
 return []
 }
 return envelope.payload
 }

 if let legacy = try? decoder.decode([MCPServerConfig].self, from: data) {
 save(legacy)
 return legacy
 }

 _ = try? StorageContractIO.archiveItemIfExists(at: fileURL, storeID: contract.id)
 return []
 }

 guard let legacyKey = contract.migrationRule.legacyKey,
 let data = legacyDefaults.data(forKey: legacyKey),
 let imported = try? decoder.decode([MCPServerConfig].self, from: data) else {
 return []
 }
 save(imported)
 return imported
 }

 private func save(_ servers: [MCPServerConfig]) {
 cache = servers
 try? StorageContractIO.ensureParentDirectory(for: fileURL)
 let envelope = VersionedStoreEnvelope(header: contract.schemaHeader, payload: servers)
 if let data = try? encoder.encode(envelope) {
 try? data.write(to: fileURL, options: .atomic)
 }
 }
}
