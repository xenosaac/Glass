import Foundation

/// Event emitted by `AgentCore` while a turn is running.
///
/// SwiftUI views subscribe to `AsyncThrowingStream<TurnEvent, Error>`
/// returned by `AgentCore.submit(_:)` to render live updates without
/// having to know how the agent loop works.
public enum TurnEvent: Sendable {
 /// Streaming text token from the model.
 case tokenReceived(String)

 /// Model decided to call a tool.
 case toolCallStarted(name: String, toolUseId: String, inputJson: String)

 /// Tool finished — success or error indicated by `result.isError`.
 case toolCallCompleted(toolUseId: String, result: ToolResult)

 /// A `ContextProvider` injected text (RAG hit, persona, skill instructions).
 case contextAdded(source: String, snippet: String)

 /// Router selected which model tier to use for this turn.
 case routingDecision(tier: ModelTier, reason: String)

 /// Recovery-aware runtime status for retries / cleanup.
 case recoveryStateChanged(RecoveryDisplayState)

 /// Clear any provisional streamed output before a retry or interruption cleanup.
 case clearProvisionalOutput

 /// Turn finished — final assistant message.
 case done(RelayMessage)

 /// Per-tool-use execution progress. toolUseId matches a prior `.toolCallStarted`.
 case toolProgress(toolUseId: String, message: String)

 /// Fatal error mid-turn. Loop stops.
 case failure(message: String)
}

public enum RecoveryDisplayState: String, Sendable, Codable, Equatable {
 case retryingWithCloud
 case compactingContext
 case retryingAfterContextReduction
 case cleaningUpInterruptedTurn
}

/// Which on-device / cloud model the router picked for this turn.
public enum ModelTier: String, Sendable, Codable, Equatable {
 /// Gemma-4-E2B — fast path, low latency, simple queries.
 case fast

 /// Gemma-4-E4B — quality path, higher reasoning, multi-tool chains.
 case quality

 /// FunctionGemma specialist pass for authoritative tool planning.
 case toolSpecialist

 /// Gemini Flash — cloud fallback for live web data only.
 case cloud
}
