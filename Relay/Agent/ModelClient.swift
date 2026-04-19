import Foundation

/// Abstraction over the two model backends that Relay can call for a
/// single completion turn: the on-device Cactus/Gemma host and the
/// cloud Gemini fallback. Both already expose an identically-shaped
/// `stream(messages:tools:options:systemPrompt:)` method; this protocol
/// captures that shape so `AgentRunner` can call either without
/// branching on concrete type.
///
/// harness extraction: protocol + empty conformance extensions.
/// `CactusModelHost` and `GeminiClient` are untouched — the concrete
/// methods they already expose satisfy this requirement via witness
/// matching (Swift allows concrete methods with default argument
/// values to fulfill protocol requirements without defaults).
public protocol ModelClient: Sendable {
 nonisolated func stream(
 messages: [RelayMessage],
 tools: [any RelayTool],
 options: CactusModelHost.CompletionOptions,
 systemPrompt: String?
 ) -> AsyncThrowingStream<CactusModelHost.StreamEvent, Error>
}

// MARK: - Conformance

extension CactusModelHost: ModelClient {}
extension GeminiClient: ModelClient {}

/// Compatibility bridge for legacy tests and transitional callers that still
/// surface `ModelClient`. Production runtime flow should use concrete
/// `ModelHostAdapter` implementations directly.
internal struct LegacyModelClientHostAdapter: ModelHostAdapter {
 internal let client: any ModelClient
 internal let profileID: PromptProfileID
 internal let tier: ModelTier

 internal func streamTurn(_ request: CompiledTurnRequest) -> AsyncThrowingStream<HostStreamEvent, Error> {
 let tools = request.hostOptions.toolMode == .disabled
 ? []
 : request.toolCatalog.map { CatalogBackedRelayToolStub(entry: $0) as any RelayTool }

 var options = request.hostOptions.completionOptions
 options.forceTools = request.hostOptions.toolMode.forceTools

 return CactusOnDeviceHostAdapter.wrap(
 client.stream(
 messages: request.messages,
 tools: tools,
 options: options,
 systemPrompt: request.promptAssembly.rendered
 ),
 request: request,
 tier: tier
 )
 }
}
