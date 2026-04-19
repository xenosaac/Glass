import Foundation

/// A source of `RelayTool`s.
///
/// Built-in registry, MCP client, AppIntents bridge, skills manager, and the
/// memory palace's read/write tools all conform to `ToolProvider`.
///
/// `AgentCore` polls every registered provider at the start of each turn —
/// this allows providers to hot-swap their tools (for example, after an
/// MCP server reconnects or a new skill is installed).
public protocol ToolProvider: Sendable {
 /// Display name for debug / settings UI.
 var providerName: String { get }

 /// Canonical origin of tools vended by this provider. Used by
 /// `ToolRegistry.catalog(for:)` to tag each `ToolCatalogEntry.source`.
 /// Defaults to `.other` so out-of-tree providers keep compiling.
 var source: ToolSource { get }

 /// Returns the tools this provider currently offers.
 func tools(for context: ToolCallContext) async -> [any RelayTool]
}

public extension ToolProvider {
 var source: ToolSource { .other }
}
