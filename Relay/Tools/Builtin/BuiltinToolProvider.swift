import Foundation

/// Bundles all built-in tools into a single `ToolProvider`.
///
/// Register with `ToolRegistry` once at app startup:
/// ```swift
/// await registry.register(BuiltinToolProvider)
/// ```
public struct BuiltinToolProvider: ToolProvider, Sendable {
 public var providerName: String { "builtin" }
 public var source: ToolSource { .builtin }

 public init() {}

 public func tools(for context: ToolCallContext) async -> [any RelayTool] {
 // `WebSearchTool` removed. Web search now
 // routes via the Round-6 web-search pre-route in
 // `AgentRunner.streamCompletion` → Gemini cloud handoff →
 // `GeminiClient` enables `googleSearch` grounding tool. No more
 // Brave API dependency / paid subscription required.
 [
 DateTimeTool(),
 MemoryWriteTool(),
 FileReadTool(),
 GlobTool(),
 GrepTool(),
 ]
 }
}
