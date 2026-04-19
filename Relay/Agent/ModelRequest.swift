import Foundation

/// Value-type bundle of everything a single model call needs, plus the
/// `wasTruncated` flag produced by `MessagePipeline`. Returned by
/// `ContextBuilder.build(...)` and consumed by `AgentRunner`.
///
/// pure struct, no behavior. Later phases may extend it
/// (e.g., `AutoCompactTrackingState` for , `RetrievalDecisions`
/// for ) — additions land here, not inside `AgentRunner` or
/// `ContextBuilder`, so the consumer doesn't grow new parameters.
public struct ModelRequest: Sendable {
 public let messages: [RelayMessage]
 public let systemPrompt: String
 public let tools: [any RelayTool]
 public let options: CactusModelHost.CompletionOptions
 public let wasTruncated: Bool

 public init(
 messages: [RelayMessage],
 systemPrompt: String,
 tools: [any RelayTool],
 options: CactusModelHost.CompletionOptions,
 wasTruncated: Bool
 ) {
 self.messages = messages
 self.systemPrompt = systemPrompt
 self.tools = tools
 self.options = options
 self.wasTruncated = wasTruncated
 }

 internal init(
 compiledTurn: CompiledTurnRequest,
 tools: [any RelayTool]
 ) {
 self.init(
 messages: compiledTurn.messages,
 systemPrompt: compiledTurn.promptAssembly.rendered,
 tools: tools,
 options: compiledTurn.hostOptions.completionOptions,
 wasTruncated: compiledTurn.wasTruncated
 )
 }
}
