import Foundation

/// Manages registered `ToolProvider`s and gathers all available tools per turn.
///
/// AgentCore polls `gatherAll(for:)` at the start of every turn so that
/// hot-swappable providers (MCP reconnect, new skill installed) are reflected
/// immediately without restart.
public actor ToolRegistry {
 private var providers: [any ToolProvider] = []

 public init() {}

 public func register(_ provider: any ToolProvider) {
 providers.append(provider)
 }

 public func unregister(named name: String) {
 providers.removeAll { $0.providerName == name }
 }

 /// Collect tools from every registered provider. Called fresh each turn.
 public func gatherAll(for context: ToolCallContext) async -> [any RelayTool] {
 var all: [any RelayTool] = []
 for provider in providers {
 let tools = await provider.tools(for: context)
 all.append(contentsOf: tools)
 }
 return all
 }

 /// Canonical catalog projection (Glass 2.0 Module C). Walks every registered
 /// provider, asks for its tools, and maps each tool into a `ToolCatalogEntry`
 /// tagged with the provider's declared `source`.
 public func catalog(for context: ToolCallContext) async -> [ToolCatalogEntry] {
 var entries: [ToolCatalogEntry] = []
 for provider in providers {
 let tools = await provider.tools(for: context)
 for tool in tools {
 entries.append(tool.catalogEntry(source: provider.source))
 }
 }
 return entries
 }

 public var providerCount: Int { providers.count }
}
