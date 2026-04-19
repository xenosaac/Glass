import Foundation

/// ToolProvider that discovers and wraps tools from all configured MCP servers.
///
/// On each agent turn, queries enabled servers for available tools and wraps
/// them as RelayTools. Caches tool listings per server to avoid excessive
/// network calls.
public actor MCPToolProvider: ToolProvider {
 public nonisolated var providerName: String { "mcp" }
 public nonisolated var source: ToolSource { .mcp(server: "aggregate") }

 private var clients: [String: MCPClient] = [:]
 private let configStore: MCPConfigStore
 private let session: URLSession

 /// Errors from the last tools call, keyed by server name.
 /// Cleared on each tools call; populated with any discovery failures.
 public private(set) var lastErrors: [String: Error] = [:]

 public init(configStore: MCPConfigStore = .shared, session: URLSession = .shared) {
 self.configStore = configStore
 self.session = session
 }

 /// Gather tools from all enabled MCP servers.
 ///
 /// Fails gracefully: if a server is unreachable, skips it and continues
 /// with others. Never blocks the agent turn due to a single server failure.
 public func tools(for context: ToolCallContext) async -> [any RelayTool] {
 // Clear previous errors
 lastErrors = [:]

 let configs = await configStore.enabledServers

 guard !configs.isEmpty else {
 return []
 }

 var allTools: [any RelayTool] = []

 for config in configs {
 do {
 let client = getOrCreateClient(for: config)
 let mcpTools = try await client.listTools

 let wrapped = mcpTools.map { def in
 MCPToolWrapper(
 serverName: config.safeName,
 definition: def,
 client: client
 )
 }
 allTools.append(contentsOf: wrapped)
 } catch {
 // Track error for diagnostics, continue with other servers
 lastErrors[config.name] = error
 print("[MCP] Server '\(config.name)' discovery failed: \(error.localizedDescription)")
 continue
 }
 }

 return allTools
 }

 /// Force refresh tool listings for all servers.
 public func refreshAll() async {
 for client in clients.values {
 await client.invalidateCache
 _ = try? await client.listTools(forceRefresh: true)
 }
 }

 /// Get a client for a specific server by name.
 public func client(named name: String) async -> MCPClient? {
 guard let config = await configStore.server(named: name) else {
 return nil
 }
 return await getOrCreateClient(for: config)
 }

 /// Get a client for a specific server by ID.
 public func client(id: String) async -> MCPClient? {
 guard let config = await configStore.server(id: id) else {
 return nil
 }
 return await getOrCreateClient(for: config)
 }

 // MARK: - Private

 private func getOrCreateClient(for config: MCPServerConfig) -> MCPClient {
 if let existing = clients[config.id] {
 return existing
 }
 let client = MCPClient(config: config, session: session)
 clients[config.id] = client
 return client
 }

 /// Remove cached client for a server (e.g., after config change).
 public func removeClient(id: String) {
 clients.removeValue(forKey: id)
 }

 /// Clear all cached clients.
 public func clearClients() {
 clients.removeAll
 }
}
