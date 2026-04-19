import Foundation

/// Service locator with injectable services.
///
/// Default constructor provides no-op stubs for everything.
/// Production usage injects real implementations as they become available:
///
/// ```swift
/// let files = FileProvider
/// try await files.initialize
/// let mcp = MCPToolProvider
/// let locator = DefaultServiceLocator(fileProvider: files, mcpProvider: mcp)
/// let core = AgentCore(host: host, serviceLocator: locator)
/// ```
public struct DefaultServiceLocator: ServiceLocator, Sendable {
 private let _fileProvider: (any FileProviderService)?
 private let _mcpProvider: MCPToolProvider?
 private let _appIntents: (any AppIntentsService)?
 private let _gmail: (any GmailService)?
 private let _memoryStore: MemoryStore?

 /// All no-op stubs (backward-compatible default).
 public init() {
 _fileProvider = nil
 _mcpProvider = nil
 _appIntents = nil
 _gmail = nil
 _memoryStore = nil
 }

 /// Flexible initializer: all services optional.
 public init(
 fileProvider: (any FileProviderService)? = nil,
 mcpProvider: MCPToolProvider? = nil,
 appIntents: (any AppIntentsService)? = nil,
 gmail: (any GmailService)? = nil,
 memoryStore: MemoryStore? = nil
 ) {
 _fileProvider = fileProvider
 _mcpProvider = mcpProvider
 _appIntents = appIntents
 _gmail = gmail
 _memoryStore = memoryStore
 }

 public func fileProvider() -> any FileProviderService {
 _fileProvider ?? NoOpFileProvider()
 }

 public func appIntents() -> any AppIntentsService {
 _appIntents ?? NoOpAppIntents()
 }

 public func mcpClient(server: String) -> (any MCPClientService)? {
 // MCPToolProvider is an actor, need to access client asynchronously.
 // For sync access, return nil — tools use MCPToolProvider directly.
 nil
 }

 public func gmail() -> any GmailService {
 _gmail ?? NoOpGmail()
 }

 /// Get the MCP tool provider (for registering with ToolRegistry).
 public func mcpToolProvider() -> MCPToolProvider? {
 _mcpProvider
 }

 public func memoryStore() -> MemoryStore? {
 _memoryStore
 }
}

private struct NoOpFileProvider: FileProviderService {}
private struct NoOpAppIntents: AppIntentsService {}
private struct NoOpGmail: GmailService {}
