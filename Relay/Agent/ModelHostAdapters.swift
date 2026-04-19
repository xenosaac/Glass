import Foundation

internal enum ModelHostAdapterError: LocalizedError, Sendable {
 case functionGemmaUnavailable(String)

 var errorDescription: String? {
 switch self {
 case .functionGemmaUnavailable(let message):
 return message
 }
 }
}

internal struct CatalogBackedRelayToolStub: RelayTool {
 let entry: ToolCatalogEntry

 var name: String { entry.name }
 var description: String { entry.title }
 var inputSchema: ToolInputSchema { ToolInputSchema(json: entry.inputSchema) }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { entry.policy.risk == .readOnly }
 var isDestructive: Bool { entry.policy.risk == .destructive }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 fatalError("CatalogBackedRelayToolStub is for host prompt assembly only")
 }

 func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 entry.policy
 }
}

internal struct CactusOnDeviceHostAdapter: ModelHostAdapter {
 internal let host: CactusModelHost
 internal let profileID: PromptProfileID = .gemmaLocal
 internal let tier: ModelTier = .fast

 internal func streamTurn(_ request: CompiledTurnRequest) -> AsyncThrowingStream<HostStreamEvent, Error> {
 let tools = request.hostOptions.toolMode == .disabled
 ? []
 : request.toolCatalog.map { CatalogBackedRelayToolStub(entry: $0) as any RelayTool }

 var options = request.hostOptions.completionOptions
 options.forceTools = request.hostOptions.toolMode.forceTools

 return Self.wrap(
 host.stream(
 messages: request.messages,
 tools: tools,
 options: options,
 systemPrompt: request.promptAssembly.rendered
 ),
 request: request,
 tier: tier
 )
 }

 internal static func wrap(
 _ stream: AsyncThrowingStream<CactusModelHost.StreamEvent, Error>,
 request: CompiledTurnRequest,
 tier: ModelTier
 ) -> AsyncThrowingStream<HostStreamEvent, Error> {
 AsyncThrowingStream { continuation in
 let task = Task {
 do {
 for try await event in stream {
 switch event {
 case .token(let token):
 if request.hostOptions.emitVisibleTokens {
 continuation.yield(.token(token))
 }

 case .done(let result):
 continuation.yield(
 .finished(
 CompiledTurnResponse(
 tier: tier,
 outputText: result.text,
 toolCalls: result.toolUses.map(ParsedToolCall.init),
 finishReason: finishReason(
 for: result,
 allowCloudHandoff: request.hostOptions.allowCloudHandoff
 ),
 rawCompletion: CompletionSnapshot(result: result)
 )
 )
 )
 }
 }
 continuation.finish()
 } catch {
 continuation.finish(throwing: error)
 }
 }
 continuation.onTermination = { _ in task.cancel() }
 }
 }
}

internal struct GeminiCloudHostAdapter: ModelHostAdapter {
 internal let client: GeminiClient
 internal let profileID: PromptProfileID = .geminiCloud
 internal let tier: ModelTier = .cloud

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

internal struct FunctionGemmaToolHostAdapter: ModelHostAdapter {
 internal let runtime: SharedFunctionGemmaRuntime
 internal let profileID: PromptProfileID = .functionGemmaTool
 internal let tier: ModelTier = .toolSpecialist

 internal func streamTurn(_ request: CompiledTurnRequest) -> AsyncThrowingStream<HostStreamEvent, Error> {
 AsyncThrowingStream { continuation in
 let task = Task {
 guard let host = await runtime.ensureReady() else {
 let message = await runtime.lastFailureReason()
 ?? "FunctionGemma tool specialist model is unavailable."
 continuation.finish(
 throwing: ModelHostAdapterError.functionGemmaUnavailable(message)
 )
 return
 }

 let tools = request.hostOptions.toolMode == .disabled
 ? []
 : request.toolCatalog.map { CatalogBackedRelayToolStub(entry: $0) as any RelayTool }

 var options = request.hostOptions.completionOptions
 options.forceTools = request.hostOptions.toolMode.forceTools

 let stream = host.stream(
 messages: request.messages,
 tools: tools,
 options: options,
 systemPrompt: request.promptAssembly.rendered
 )

 do {
 for try await event in CactusOnDeviceHostAdapter.wrap(
 stream,
 request: request,
 tier: tier
 ) {
 continuation.yield(event)
 }
 continuation.finish()
 } catch {
 continuation.finish(throwing: error)
 }
 }
 continuation.onTermination = { _ in task.cancel() }
 }
 }
}

private func finishReason(
 for result: CactusModelHost.CompletionResult,
 allowCloudHandoff: Bool
) -> FinishReason {
 if !result.toolUses.isEmpty {
 return .toolCalls
 }
 if result.cloudHandoff && allowCloudHandoff {
 return .cloudHandoff
 }
 if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
 return .empty
 }
 return .message
}
