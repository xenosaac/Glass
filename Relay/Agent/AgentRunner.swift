import Foundation

/// Per-turn state machine. Drives one user turn to completion or
/// failure. Stateless between turns — every call to `run(...)` creates
/// fresh iteration state.
///
/// Ownership contract: `AgentCore` holds exactly one `AgentRunner` and
/// invokes `run(...)` once per user turn. The runner yields events
/// through the caller's `continuation`; it does not own or mutate
/// `AgentCore`'s `self.messages` — instead it returns the new message
/// array for `AgentCore` to assign on completion.
public actor AgentRunner {

 public enum TurnExit: Sendable, Equatable {
 case completed
 case maxTurns
 case modelError(String)
 case noCompletion
 case interrupted
 }

 private enum RecoverableFailure {
 case promptTooLong(String)
 case cloudRetryFailed(String)
 case interrupted
 case fatal(String)
 }

 internal enum TextOnlyFallbackReason: Sendable, Equatable {
 case noCloudClient
 case cloudRetryFailed
 case cloudProducedNoResult
 case cloudResponseRejected

 fileprivate var shouldAppendUnavailableDisclaimer: Bool {
 switch self {
 case .cloudResponseRejected:
 return false
 case .noCloudClient, .cloudRetryFailed, .cloudProducedNoResult:
 return true
 }
 }
 }

 private struct StreamAttempt {
 let result: CompiledTurnResponse?
 let emittedTokens: Bool
 }

 private static let promptTooLongMarkers: [String] = [
 "prompt too long",
 "context window",
 "context length",
 "too many tokens",
 "too large",
 "context too large",
 "token limit",
 "maximum context",
 "prompt exceeds",
 "request too large"
 ]

 public init() {}

 internal struct RunResult: Sendable {
 let state: AgentSessionState
 let artifacts: TurnRunArtifacts

 var exit: TurnExit {
 artifacts.exit.asTurnExit(errorMessage: artifacts.recoveryState.lastErrorMessage)
 }
 }

 internal func run(
 sessionID: String = "test-session",
 initialUserMessage: RelayMessage,
 state: AgentSessionState,
 contextBuilder: ContextBuilder,
 onDeviceClient: any ModelHostAdapter,
 cloudClient: (any ModelHostAdapter)?,
 toolSpecialistClient: (any ModelHostAdapter)? = nil,
 dispatcher: ToolDispatcher,
 toolContextFor: @Sendable ([RelayMessage]) -> ToolCallContext,
 tools: [any RelayTool],
 toolCatalog: [ToolCatalogEntry]? = nil,
 enabledToolNames: Set<String>,
 environment: SystemPrompt.Environment,
 extraSystemContext: [String: String],
 options: CactusModelHost.CompletionOptions,
 recoveryCompactor: Compactor? = nil,
 continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
 ) async -> (state: AgentSessionState, exit: TurnExit) {
 let initialTurn = NormalizedTurn(
 transcriptMessage: initialUserMessage,
 modelMessage: TurnIngressNormalizer.projectMessageForModel(initialUserMessage)
 )
 let result = await runWithArtifacts(
 turnID: initialTurn.turnID,
 sessionID: sessionID,
 initialTurn: initialTurn,
 state: state,
 contextBuilder: contextBuilder,
 onDeviceClient: onDeviceClient,
 cloudClient: cloudClient,
 toolSpecialistClient: toolSpecialistClient,
 dispatcher: dispatcher,
 toolContextFor: toolContextFor,
 tools: tools,
 toolCatalog: toolCatalog ?? tools.map { $0.catalogEntry(source: .other) },
 enabledToolNames: enabledToolNames,
 environment: environment,
 extraSystemContext: extraSystemContext,
 options: options,
 recoveryCompactor: recoveryCompactor,
 continuation: continuation
 )
 return (result.state, result.exit)
 }

 public func run(
 sessionID: String = "test-session",
 initialUserMessage: RelayMessage,
 state: AgentSessionState,
 contextBuilder: ContextBuilder,
 onDeviceClient: any ModelClient,
 cloudClient: (any ModelClient)?,
 toolSpecialistClient: (any ModelClient)? = nil,
 dispatcher: ToolDispatcher,
 toolContextFor: @Sendable ([RelayMessage]) -> ToolCallContext,
 tools: [any RelayTool],
 enabledToolNames: Set<String>,
 environment: SystemPrompt.Environment,
 extraSystemContext: [String: String],
 options: CactusModelHost.CompletionOptions,
 recoveryCompactor: Compactor? = nil,
 continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
 ) async -> (state: AgentSessionState, exit: TurnExit) {
 await run(
 sessionID: sessionID,
 initialUserMessage: initialUserMessage,
 state: state,
 contextBuilder: contextBuilder,
 onDeviceClient: LegacyModelClientHostAdapter(
 client: onDeviceClient,
 profileID: .gemmaLocal,
 tier: .fast
 ),
 cloudClient: cloudClient.map {
 LegacyModelClientHostAdapter(
 client: $0,
 profileID: .geminiCloud,
 tier: .cloud
 )
 },
 toolSpecialistClient: toolSpecialistClient.map {
 LegacyModelClientHostAdapter(
 client: $0,
 profileID: .functionGemmaTool,
 tier: .toolSpecialist
 )
 },
 dispatcher: dispatcher,
 toolContextFor: toolContextFor,
 tools: tools,
 enabledToolNames: enabledToolNames,
 environment: environment,
 extraSystemContext: extraSystemContext,
 options: options,
 recoveryCompactor: recoveryCompactor,
 continuation: continuation
 )
 }

 internal func runWithArtifacts(
 turnID: UUID,
 sessionID: String,
 initialUserMessage: RelayMessage,
 state: AgentSessionState,
 contextBuilder: ContextBuilder,
 onDeviceClient: any ModelHostAdapter,
 cloudClient: (any ModelHostAdapter)?,
 toolSpecialistClient: (any ModelHostAdapter)?,
 dispatcher: ToolDispatcher,
 toolContextFor: @Sendable ([RelayMessage]) -> ToolCallContext,
 tools: [any RelayTool],
 toolCatalog: [ToolCatalogEntry],
 enabledToolNames: Set<String>,
 environment: SystemPrompt.Environment,
 extraSystemContext: [String: String],
 options: CactusModelHost.CompletionOptions,
 recoveryCompactor: Compactor? = nil,
 continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
 ) async -> RunResult {
 let initialTurn = NormalizedTurn(
 turnID: turnID,
 transcriptMessage: initialUserMessage,
 modelMessage: TurnIngressNormalizer.projectMessageForModel(initialUserMessage)
 )
 return await runWithArtifacts(
 turnID: turnID,
 sessionID: sessionID,
 initialTurn: initialTurn,
 state: state,
 contextBuilder: contextBuilder,
 onDeviceClient: onDeviceClient,
 cloudClient: cloudClient,
 toolSpecialistClient: toolSpecialistClient,
 dispatcher: dispatcher,
 toolContextFor: toolContextFor,
 tools: tools,
 toolCatalog: toolCatalog,
 enabledToolNames: enabledToolNames,
 environment: environment,
 extraSystemContext: extraSystemContext,
 options: options,
 recoveryCompactor: recoveryCompactor,
 continuation: continuation
 )
 }

 internal func runWithArtifacts(
 turnID: UUID,
 sessionID: String,
 initialTurn: NormalizedTurn,
 state: AgentSessionState,
 contextBuilder: ContextBuilder,
 onDeviceClient: any ModelHostAdapter,
 cloudClient: (any ModelHostAdapter)?,
 toolSpecialistClient: (any ModelHostAdapter)?,
 dispatcher: ToolDispatcher,
 toolContextFor: @Sendable ([RelayMessage]) -> ToolCallContext,
 tools: [any RelayTool],
 toolCatalog: [ToolCatalogEntry],
 enabledToolNames: Set<String>,
 environment: SystemPrompt.Environment,
 extraSystemContext: [String: String],
 options: CactusModelHost.CompletionOptions,
 recoveryCompactor: Compactor? = nil,
 continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
 ) async -> RunResult {
 var runtimeState = state
 let currentTurnStartIndex = runtimeState.messages.count
 let priorHistoryTurnCount = state.turnCount
 runtimeState.messages.append(initialTurn.transcriptMessage)
 runtimeState.recoveryState = runtimeState.recoveryState.beganTurn()

 if case .user(let content) = initialTurn.transcriptMessage, !content.isMeta {
 runtimeState.turnCount += 1
 }

 // #4 — direct-dispatch shortcut for
 // unambiguous tool intents. For prompts like "What time is it?"
 // / "What's today's date?" we bypass the model loop entirely:
 // dispatch the resolved tool directly via the existing
 // ToolDispatcher, format the result as a single Glass-shaped
 // bubble sentence, return `.completed`. Solves three compounding
 // bugs at once:
 // (a) Gemma's unreliable "model decides tool" for simple
 // intents (R5 P2 risk),
 // (b) Cloud Gemini under toolConfig.mode=ANY picking the
 // wrong tool (often `memory_write` because it's over-
 // represented in the system prompt's 470-token Memory
 // section — Isaac's "memory firing on time queries"
 // complaint),
 // (c) Gemma's broken post-tool synthesis turn where it reads
 // a real tool result and replies "I don't have access."
 // Zero model iterations; zero cloud burn; zero memory_write
 // spam on non-memory turns.
 if let shortcut = Self.resolveDirectDispatchShortcut(
 initialUserMessage: initialTurn.transcriptMessage
 ) {
 return await Self.runDirectDispatchShortcut(
 turnID: turnID,
 runtimeState: runtimeState,
 acceptedUserMessage: initialTurn.transcriptMessage,
 shortcut: shortcut,
 dispatcher: dispatcher,
 toolContextFor: toolContextFor,
 tools: tools,
 continuation: continuation
 )
 }

 var router = ModelRouter()
 var loopCount = 0
 let maxLoops = 10
 var usedCloudFallback = false
 var usedReactiveCompactionRetry = false
 var attemptDiagnostics: [TurnAttemptDiagnostics] = []
 var aggregatedToolExecutions: [ToolExecutionRecord] = []
 var aggregatedApprovalDecisions: [ApprovalDecisionRecord] = []
 var nextAttemptIndex = 1
 // per-turn cache for idempotent tool
 // reads. Keys: `"<toolName>|<inputJson>"`. T22 device log showed
 // the model re-emitting `get_current_datetime` across iterations
 // 1 → 2 → 3, wasting two extra dispatches on a tool whose result
 // hasn't changed within the turn. Cache only writes for tools
 // that report `isReadOnly == true`; side-effecting tools
 // (sms_send, calendar_create_event, etc.) always re-execute.
 var idempotentToolResultCache: [String: ToolResultBlock] = [:]

 func appendAttempt(
 attemptIndex: Int,
 modelTier: ModelTier,
 request: CompiledTurnRequest,
 recoveryEvents: [TurnRecoveryEventDiagnostic],
 completion: CompiledTurnResponse? = nil,
 errorSummary: String? = nil
 ) {
 attemptDiagnostics.append(
 TurnAttemptDiagnostics(
 attemptIndex: attemptIndex,
 modelTier: modelTier,
 requestMessages: request.messages,
 systemPrompt: request.promptAssembly.rendered,
 promptDiagnostics: request.promptAssembly.diagnostics,
 currentTurnFocus: request.diagnostics.currentTurnFocus,
 retrievalDecision: request.retrievalPlan,
 wasTruncated: request.wasTruncated,
 emittedRecoveryEvents: recoveryEvents,
 completionSnapshot: completion?.rawCompletion.map(AttemptCompletionSnapshot.init(snapshot:)),
 errorSummary: errorSummary,
 compiledRequest: request,
 compiledResponse: completion
 )
 )
 }

 func finalize(
 state: AgentSessionState,
 exit: TurnExit,
 finalAssistantMessage: RelayMessage?
 ) -> RunResult {
 RunResult(
 state: state,
 artifacts: TurnRunArtifacts(
 turnID: turnID,
 exit: exit.summary,
 recoveryState: state.recoveryState,
 attempts: attemptDiagnostics,
 acceptedUserMessage: initialTurn.transcriptMessage,
 finalAssistantMessage: finalAssistantMessage,
 toolExecutions: aggregatedToolExecutions,
 approvalDecisions: aggregatedApprovalDecisions
 )
 )
 }

 while loopCount < maxLoops {
 loopCount += 1

 if Task.isCancelled {
 let interrupted = await finalizeInterruptedTurn(
 state: runtimeState,
 usedCloudFallback: usedCloudFallback,
 continuation: continuation
 )
 attemptDiagnostics = Self.appendingRecoveryEvents(
 [.cleaningUpInterruptedTurn, .clearProvisionalOutput],
 to: attemptDiagnostics
 )
 return finalize(
 state: interrupted.state,
 exit: interrupted.exit,
 finalAssistantMessage: nil
 )
 }

 let tier = router.decide(cloudHandoffSuggested: false)
 continuation.yield(.routingDecision(tier: tier, reason: router.lastReason))

 let request = await contextBuilder.buildCompiledTurn(
 turnID: turnID,
 sessionID: sessionID,
 state: runtimeState,
 currentTurn: initialTurn,
 enabledToolNames: enabledToolNames,
 environment: environment,
 extraSystemContext: extraSystemContext,
 toolCatalog: toolCatalog,
 options: options
 )
 runtimeState.retrievalState = .planned(
 query: request.diagnostics.retrievalQuery,
 decision: RetrievalDecision(
 query: request.diagnostics.retrievalQuery,
 artifacts: request.bindingContext?.retrievalArtifacts ?? []
 ),
 turnCount: runtimeState.turnCount
 )

 #if DEBUG
 print("[DEBUG_MEMORY] Sending \(request.messages.count) messages to model (loop \(loopCount)) truncated=\(request.wasTruncated)")
 #endif

 let modelStart = CFAbsoluteTimeGetCurrent()
 let onDeviceAttemptIndex = nextAttemptIndex
 nextAttemptIndex += 1
 let onDeviceAttempt: StreamAttempt
 do {
 // — try primary first, then promote to cloud once
 // on `HostError.inferenceFailed` (OOM / SIGILL / weights load
 // failure). Configuration errors (`notLoaded` / `decodeFailed`
 // / `loadFailed`) are NOT promoted since cloud can't help.
 // On successful cloud promotion, `onDeviceAttempt` holds the
 // cloud result and the turn continues as if primary succeeded.
 // On promotion failure the error re-throws to the outer catch
 // which runs the original `classify` logic.
 do {
 onDeviceAttempt = try await Self.streamCompletion(
 client: onDeviceClient,
 request: request,
 continuation: continuation
 )
 } catch let primaryErr {
 let isPromotable: Bool = {
 guard let he = primaryErr as? CactusModelHost.HostError else { return false }
 if case .inferenceFailed = he { return true }
 return false
 }()
 guard isPromotable,
 let cloud = cloudClient,
 !usedCloudFallback,
 request.bindingContext != nil else {
 throw primaryErr
 }
 print("[Route] primary inference error (\(primaryErr.localizedDescription)) → falling through to cloud fallback")
 let cloudReq = request.with(
 profileID: .geminiCloud,
 hostOptions: HostExecutionOptions(
 completionOptions: Self.widenCloudMaxTokens(request.hostOptions.completionOptions),
 toolMode: request.hostOptions.toolMode,
 emitVisibleTokens: true,
 allowCloudHandoff: false
 )
 )
 continuation.yield(.routingDecision(tier: .cloud, reason: "Primary inference error — retrying with Gemini"))
 continuation.yield(.recoveryStateChanged(.retryingWithCloud))
 continuation.yield(.clearProvisionalOutput)
 usedCloudFallback = true
 onDeviceAttempt = try await Self.streamCompletion(
 client: cloud,
 request: cloudReq,
 continuation: continuation
 )
 }
 } catch {
 let recovery = Self.classify(error: error, duringCloudRetry: false)
 switch recovery {
 case .interrupted:
 appendAttempt(
 attemptIndex: onDeviceAttemptIndex,
 modelTier: tier,
 request: request,
 recoveryEvents: [],
 errorSummary: error.localizedDescription
 )
 let interrupted = await finalizeInterruptedTurn(
 state: runtimeState,
 usedCloudFallback: usedCloudFallback,
 continuation: continuation
 )
 attemptDiagnostics = Self.appendingRecoveryEvents(
 [.cleaningUpInterruptedTurn, .clearProvisionalOutput],
 to: attemptDiagnostics
 )
 return finalize(
 state: interrupted.state,
 exit: interrupted.exit,
 finalAssistantMessage: nil
 )

 case .promptTooLong(let message):
 guard !usedReactiveCompactionRetry,
 let recoveryCompactor,
 let recoveredState = await reactivelyCompact(
 runtimeState: runtimeState,
 currentTurnStartIndex: currentTurnStartIndex,
 priorHistoryTurnCount: priorHistoryTurnCount,
 recoveryCompactor: recoveryCompactor
 ) else {
 appendAttempt(
 attemptIndex: onDeviceAttemptIndex,
 modelTier: tier,
 request: request,
 recoveryEvents: [.clearProvisionalOutput],
 errorSummary: error.localizedDescription
 )
 continuation.yield(.clearProvisionalOutput)
 let visible = "Inference error: \(error.localizedDescription)"
 continuation.yield(.failure(message: visible))
 runtimeState.recoveryState = runtimeState.recoveryState.updated(
 exit: .modelError,
 errorMessage: error.localizedDescription,
 cloudFallbackUsedLastTurn: usedCloudFallback,
 turnCount: runtimeState.turnCount,
 lastContinuationReason: runtimeState.recoveryState.lastContinuationReason ?? .fatalError
 )
 return finalize(
 state: runtimeState,
 exit: .modelError(error.localizedDescription),
 finalAssistantMessage: nil
 )
 }

 appendAttempt(
 attemptIndex: onDeviceAttemptIndex,
 modelTier: tier,
 request: request,
 recoveryEvents: [.compactingContext, .clearProvisionalOutput, .retryingAfterContextReduction],
 errorSummary: message
 )
 continuation.yield(.recoveryStateChanged(.compactingContext))
 continuation.yield(.clearProvisionalOutput)
 runtimeState.recoveryState = runtimeState.recoveryState.recordingContinuation(
 reason: .promptTooLongRetry,
 withheldRecoverableError: message,
 incrementAttemptCount: true
 )
 runtimeState = recoveredState
 usedReactiveCompactionRetry = true
 continuation.yield(.recoveryStateChanged(.retryingAfterContextReduction))
 continue

 case .cloudRetryFailed(let message), .fatal(let message):
 appendAttempt(
 attemptIndex: onDeviceAttemptIndex,
 modelTier: tier,
 request: request,
 recoveryEvents: [.clearProvisionalOutput],
 errorSummary: message
 )
 continuation.yield(.clearProvisionalOutput)
 let visible = "Inference error: \(message)"
 continuation.yield(.failure(message: visible))
 runtimeState.recoveryState = runtimeState.recoveryState.updated(
 exit: .modelError,
 errorMessage: message,
 cloudFallbackUsedLastTurn: usedCloudFallback,
 turnCount: runtimeState.turnCount,
 lastContinuationReason: runtimeState.recoveryState.lastContinuationReason ?? .fatalError
 )
 return finalize(
 state: runtimeState,
 exit: .modelError(message),
 finalAssistantMessage: nil
 )
 }
 }
 let modelMs = (CFAbsoluteTimeGetCurrent() - modelStart) * 1000
 print("[Perf] Model iteration \(loopCount): \(String(format: "%.0f", modelMs))ms (\(runtimeState.messages.count) msgs)")

 guard var result = onDeviceAttempt.result else {
 appendAttempt(
 attemptIndex: onDeviceAttemptIndex,
 modelTier: tier,
 request: request,
 recoveryEvents: [.clearProvisionalOutput],
 errorSummary: "No completion result from model"
 )
 continuation.yield(.clearProvisionalOutput)
 continuation.yield(.failure(message: "No completion result from model"))
 runtimeState.recoveryState = runtimeState.recoveryState.updated(
 exit: .noCompletion,
 errorMessage: "No completion result from model",
 cloudFallbackUsedLastTurn: usedCloudFallback,
 turnCount: runtimeState.turnCount,
 lastContinuationReason: runtimeState.recoveryState.lastContinuationReason ?? .fatalError
 )
 return finalize(
 state: runtimeState,
 exit: .noCompletion,
 finalAssistantMessage: nil
 )
 }

 // Option A obedience guard R6-Mem
 // hotfix #2): validate every primary `.message` response, on
 // every iteration of the turn loop. The action on failure
 // depends on state:
 //
 // If cloud is available AND we haven't fallen back yet
 // this turn → promote to `.cloudHandoff` (the existing
 // retry path).
 // Otherwise (cloud unavailable OR already used) →
 // substitute a hardcoded acknowledgment so the user
 // never sees a help-desk opener after a successful
 // tool round. Identity-violation reasons get the
 // existing `identityFallbackText`; everything else
 // gets `postCloudObedienceFallbackText`.
 //
 // Pre-hotfix the gate `!usedCloudFallback` skipped validation
 // entirely on iter 2+ of any turn that had touched cloud
 // earlier — letting Gemma's post-tool text response slip
 // through unchecked. Isaac's device test surfaced exactly
 // that: turn-1 iter-2 produced `"What can I help you with
 // today?"` after a successful memory_write round.
 if result.finishReason == .message,
 let bindingContext = request.bindingContext {
 #if DEBUG
 // log the primary model's raw text BEFORE the
 // obedience validator gets a chance to rewrite it into canned
 // text. Lets us see what Gemma actually produced, which is
 // the ground truth for any refusal/help-desk debugging.
 print("[DEBUG_GEMMA_RAW] pre-validator text (class=\(bindingContext.classification), len=\(result.outputText.count), toolCalls=\(result.toolCalls.count)): \(result.outputText.prefix(2000))")
 #endif
 let verdict = ResponseObedienceValidator.validate(
 response: result,
 classification: bindingContext.classification,
 visibleFacts: bindingContext.visibleFacts
 )
 if case .fail(let reason) = verdict {
 if cloudClient != nil, !usedCloudFallback {
 print("[Obedience] Primary response failed validation (\(reason)); promoting to cloud fallback.")
 result = CompiledTurnResponse(
 tier: result.tier,
 outputText: result.outputText,
 toolCalls: result.toolCalls,
 finishReason: .cloudHandoff,
 rawCompletion: result.rawCompletion
 )
 } else {
 print("[Obedience] Post-cloud-fallback response failed validation (\(reason)); substituting acknowledgment.")
 // 3 : pick the identity
 // fallback text based on whether the user actually
 // asked an identity question. For calendar/search
 // questions the introduction text is a non-sequitur.
 let userText = request.diagnostics.latestNonMetaUserText ?? ""
 let fallbackText: String
 if reason.contains("identity violation") {
 fallbackText = ResponseObedienceValidator.isIdentityQuestion(userText)
 ? ResponseObedienceValidator.identityFallbackText
 : ResponseObedienceValidator.identityFallbackForNonIdentityQuestionText
 } else {
 fallbackText = ResponseObedienceValidator.postCloudObedienceFallbackText
 }
 result = CompiledTurnResponse(
 tier: result.tier,
 outputText: fallbackText,
 toolCalls: [],
 finishReason: .message,
 rawCompletion: result.rawCompletion
 )
 }
 }
 }

 // #2 — Bug B: when the turn elevated toolMode
 // to `.required` (via `TurnClassifier.isToolIntent` in
 // ContextBuilder.selectToolMode) but Gemma chose to emit a
 // text-only response anyway, route to cloud where Gemini's
 // `toolConfig.mode = "ANY"` (R5 cloud fix) is much
 // more reliable at forcing tool emission. This is the R5
 // deferred P2 mitigation — surfaced by Isaac's
 // `What time is it?` device turn that came back as
 // `"Please let me know what you would like assistance
 // with."` instead of an actual time.
 //
 // Position matters: this MUST run after the validator block
 // above so a help-desk text shape gets caught + substituted
 // there first; if validator fired it already set
 // `.cloudHandoff` and our `result.finishReason == .message`
 // check below won't fire. No double-route.
 if result.finishReason == .message,
 request.hostOptions.toolMode == .required,
 result.toolCalls.isEmpty,
 cloudClient != nil,
 !usedCloudFallback,
 request.bindingContext != nil {
 print("[Tool] Primary skipped tool emission despite toolMode=.required; promoting to cloud fallback.")
 result = CompiledTurnResponse(
 tier: result.tier,
 outputText: result.outputText,
 toolCalls: [],
 finishReason: .cloudHandoff,
 rawCompletion: result.rawCompletion
 )
 }

 if result.finishReason == .cloudHandoff {
 appendAttempt(
 attemptIndex: onDeviceAttemptIndex,
 modelTier: tier,
 request: request,
 recoveryEvents: cloudClient != nil ? [.retryingWithCloud, .clearProvisionalOutput] : [],
 completion: result
 )
 if let cloud = cloudClient {
 // elevate toolMode to
 // .required for `.declarativeFact` cloud handoffs so
 // GeminiClient emits `toolConfig.mode = "ANY"` and
 // forces a `memory_write` call. Without this, Gemini
 // routinely returns "Got it. I'll remember that." as
 // pure text and the fact is silently dropped — see the
 // cross-session-memory bug.
 //
 // only elevate on the
 // FIRST iteration of the turn. Once any tool_use has
 // fired (e.g. memory_write succeeded on iter 1), the
 // .required mode forces the cloud to emit ANOTHER
 // tool_use on the synthesis pass — picks memory_write
 // again because that was the salient tool — infinite
 // loop. Detect via "any assistant tool_use after the
 // most recent user message" and downgrade.
 let toolAlreadyFiredThisTurn: Bool = {
 for msg in request.messages.reversed() {
 if case .user = msg { break }
 if case .assistant(let content) = msg,
 content.blocks.contains(where: {
 if case .toolUse = $0 { return true } else { return false }
 }) {
 return true
 }
 }
 return false
 }()
 let cloudToolMode: HostToolMode
 if let bc = request.bindingContext,
 bc.classification == .declarativeFact,
 !toolAlreadyFiredThisTurn {
 cloudToolMode = .required
 print("[Memory] Cloud handoff toolMode elevated to .required for declarativeFact")
 } else {
 cloudToolMode = request.hostOptions.toolMode
 if let bc = request.bindingContext,
 bc.classification == .declarativeFact,
 toolAlreadyFiredThisTurn {
 print("[Memory] Cloud handoff NOT elevated — tool already fired this turn (loop guard)")
 }
 }
 // — widen cloud output budget (2048→8192).
 let cloudRequest = request.with(
 profileID: .geminiCloud,
 hostOptions: HostExecutionOptions(
 completionOptions: Self.widenCloudMaxTokens(request.hostOptions.completionOptions),
 toolMode: cloudToolMode,
 emitVisibleTokens: true,
 allowCloudHandoff: false
 )
 )
 continuation.yield(.routingDecision(tier: .cloud, reason: "Retrying with Gemini..."))
 continuation.yield(.recoveryStateChanged(.retryingWithCloud))
 continuation.yield(.clearProvisionalOutput)
 runtimeState.recoveryState = runtimeState.recoveryState.recordingContinuation(
 reason: .cloudRetry,
 incrementAttemptCount: true
 )
 usedCloudFallback = true

 let onDeviceResult = result
 let cloudAttemptIndex = nextAttemptIndex
 nextAttemptIndex += 1
 do {
 let cloudAttempt = try await Self.streamCompletion(
 client: cloud,
 request: cloudRequest,
 continuation: continuation
 )
 if let cloudResult = cloudAttempt.result {
 appendAttempt(
 attemptIndex: cloudAttemptIndex,
 modelTier: .cloud,
 request: cloudRequest,
 recoveryEvents: [],
 completion: cloudResult
 )
 result = cloudResult

 //  — cloud re-validation.
 // Gemini itself sometimes produces help-desk
 // openers (e.g. `"Hello! How can Glass assist
 // you today?"`) in response to the same prompts
 // that trip Gemma. Run the same obedience
 // validator here; if cloud ALSO fails, fall
 // through to `textOnlyFallback` with a clear
 // log line. No further retry — this is the
 // terminal branch.
 if cloudResult.finishReason == .message,
 let bindingContext = cloudRequest.bindingContext {
 let verdict = ResponseObedienceValidator.validate(
 response: cloudResult,
 classification: bindingContext.classification,
 visibleFacts: bindingContext.visibleFacts
 )
 if case .fail(let reason) = verdict {
 print("[Obedience] Cloud response ALSO failed validation (\(reason)); falling through to textOnlyFallback.")
 continuation.yield(.clearProvisionalOutput)
 // identity
 // leaks get a hardcoded Glass-shaped
 // sentence instead of `textOnlyFallback`,
 // which would echo the on-device leak
 // text. The user gets a coherent reply
 // even in this terminal branch.
 // 3 : pick the
 // identity fallback text based on
 // whether the user actually asked an
 // identity question. Calendar/search
 // questions get a neutral retry, not
 // an introduction.
 if reason.contains("identity violation") {
 let userText = cloudRequest.diagnostics.latestNonMetaUserText ?? ""
 let fallbackText = ResponseObedienceValidator.isIdentityQuestion(userText)
 ? ResponseObedienceValidator.identityFallbackText
 : ResponseObedienceValidator.identityFallbackForNonIdentityQuestionText
 result = CompiledTurnResponse(
 tier: cloudResult.tier,
 outputText: fallbackText,
 toolCalls: [],
 finishReason: .message,
 rawCompletion: cloudResult.rawCompletion
 )
 } else {
 result = Self.textOnlyFallback(
 from: onDeviceResult,
 reason: .cloudResponseRejected
 )
 }
 if !result.outputText.isEmpty {
 continuation.yield(.tokenReceived(result.outputText))
 }
 }
 }
 } else {
 let recoveryEvents: [TurnRecoveryEventDiagnostic] = cloudAttempt.emittedTokens
 ? [.clearProvisionalOutput]
 : []
 appendAttempt(
 attemptIndex: cloudAttemptIndex,
 modelTier: .cloud,
 request: cloudRequest,
 recoveryEvents: recoveryEvents,
 errorSummary: "Cloud retry produced no completion result"
 )
 if cloudAttempt.emittedTokens {
 continuation.yield(.clearProvisionalOutput)
 }
 result = Self.textOnlyFallback(
 from: onDeviceResult,
 reason: .cloudProducedNoResult
 )
 if !result.outputText.isEmpty {
 continuation.yield(.tokenReceived(result.outputText))
 }
 }
 } catch {
 let recovery = Self.classify(error: error, duringCloudRetry: true)
 switch recovery {
 case .interrupted:
 appendAttempt(
 attemptIndex: cloudAttemptIndex,
 modelTier: .cloud,
 request: cloudRequest,
 recoveryEvents: [],
 errorSummary: error.localizedDescription
 )
 let interrupted = await finalizeInterruptedTurn(
 state: runtimeState,
 usedCloudFallback: usedCloudFallback,
 continuation: continuation
 )
 attemptDiagnostics = Self.appendingRecoveryEvents(
 [.cleaningUpInterruptedTurn, .clearProvisionalOutput],
 to: attemptDiagnostics
 )
 return finalize(
 state: interrupted.state,
 exit: interrupted.exit,
 finalAssistantMessage: nil
 )

 case .promptTooLong(let message):
 guard !usedReactiveCompactionRetry,
 let recoveryCompactor,
 let recoveredState = await reactivelyCompact(
 runtimeState: runtimeState,
 currentTurnStartIndex: currentTurnStartIndex,
 priorHistoryTurnCount: priorHistoryTurnCount,
 recoveryCompactor: recoveryCompactor
 ) else {
 appendAttempt(
 attemptIndex: cloudAttemptIndex,
 modelTier: .cloud,
 request: cloudRequest,
 recoveryEvents: [.clearProvisionalOutput],
 errorSummary: error.localizedDescription
 )
 continuation.yield(.clearProvisionalOutput)
 // #3: friendly errors (like
 // `GeminiError.quotaExhausted`) come with
 // a complete user-facing sentence already
 // don't double-prefix them with the
 // developer-y "Cloud retry error:" tag.
 let raw = error.localizedDescription
 let visible = raw.hasPrefix("Cloud quota exhausted")
 ? raw
 : "Cloud retry error: \(raw)"
 continuation.yield(.failure(message: visible))
 runtimeState.recoveryState = runtimeState.recoveryState.updated(
 exit: .modelError,
 errorMessage: error.localizedDescription,
 cloudFallbackUsedLastTurn: usedCloudFallback,
 turnCount: runtimeState.turnCount,
 lastContinuationReason: runtimeState.recoveryState.lastContinuationReason ?? .fatalError
 )
 return finalize(
 state: runtimeState,
 exit: .modelError(error.localizedDescription),
 finalAssistantMessage: nil
 )
 }

 appendAttempt(
 attemptIndex: cloudAttemptIndex,
 modelTier: .cloud,
 request: cloudRequest,
 recoveryEvents: [.compactingContext, .clearProvisionalOutput, .retryingAfterContextReduction],
 errorSummary: message
 )
 continuation.yield(.recoveryStateChanged(.compactingContext))
 continuation.yield(.clearProvisionalOutput)
 runtimeState.recoveryState = runtimeState.recoveryState.recordingContinuation(
 reason: .promptTooLongRetry,
 withheldRecoverableError: message,
 incrementAttemptCount: true
 )
 runtimeState = recoveredState
 usedReactiveCompactionRetry = true
 continuation.yield(.recoveryStateChanged(.retryingAfterContextReduction))
 continue

 case .cloudRetryFailed(let message):
 appendAttempt(
 attemptIndex: cloudAttemptIndex,
 modelTier: .cloud,
 request: cloudRequest,
 recoveryEvents: [.clearProvisionalOutput],
 errorSummary: message
 )
 continuation.yield(.clearProvisionalOutput)
 runtimeState.recoveryState = runtimeState.recoveryState.recordingContinuation(
 reason: .cloudRetry,
 withheldRecoverableError: message
 )
 result = Self.textOnlyFallback(
 from: onDeviceResult,
 reason: .cloudRetryFailed
 )
 if !result.outputText.isEmpty {
 continuation.yield(.tokenReceived(result.outputText))
 }

 case .fatal(let message):
 appendAttempt(
 attemptIndex: cloudAttemptIndex,
 modelTier: .cloud,
 request: cloudRequest,
 recoveryEvents: [.clearProvisionalOutput],
 errorSummary: message
 )
 continuation.yield(.clearProvisionalOutput)
 // #3: same friendly-error skip
 // as above — quota-exhausted message is
 // already a complete sentence.
 let visible = message.hasPrefix("Cloud quota exhausted")
 ? message
 : "Cloud retry error: \(message)"
 continuation.yield(.failure(message: visible))
 runtimeState.recoveryState = runtimeState.recoveryState.updated(
 exit: .modelError,
 errorMessage: message,
 cloudFallbackUsedLastTurn: usedCloudFallback,
 turnCount: runtimeState.turnCount,
 lastContinuationReason: runtimeState.recoveryState.lastContinuationReason ?? .fatalError
 )
 return finalize(
 state: runtimeState,
 exit: .modelError(message),
 finalAssistantMessage: nil
 )
 }
 }
 } else {
 result = Self.textOnlyFallback(from: result, reason: .noCloudClient)
 }
 } else {
 appendAttempt(
 attemptIndex: onDeviceAttemptIndex,
 modelTier: tier,
 request: request,
 recoveryEvents: [],
 completion: result
 )
 }

 if result.finishReason == .toolCalls,
 request.hostOptions.toolMode != .required,
 let toolSpecialistClient {
 let specialistAttemptIndex = nextAttemptIndex
 nextAttemptIndex += 1
 let specialistRequest = request.with(
 profileID: .functionGemmaTool,
 hostOptions: HostExecutionOptions(
 completionOptions: request.hostOptions.completionOptions,
 toolMode: .required,
 emitVisibleTokens: false,
 allowCloudHandoff: false
 )
 )
 continuation.yield(.routingDecision(tier: .toolSpecialist, reason: "Refining tool plan with FunctionGemma..."))
 runtimeState.recoveryState = runtimeState.recoveryState.recordingContinuation(
 reason: .toolSpecialist,
 incrementAttemptCount: true
 )
 do {
 let specialistAttempt = try await Self.streamCompletion(
 client: toolSpecialistClient,
 request: specialistRequest,
 continuation: continuation
 )
 if let specialistResult = specialistAttempt.result,
 !specialistResult.toolCalls.isEmpty {
 appendAttempt(
 attemptIndex: specialistAttemptIndex,
 modelTier: .toolSpecialist,
 request: specialistRequest,
 recoveryEvents: [],
 completion: specialistResult
 )
 result = specialistResult
 } else {
 let fallbackMessage = "FunctionGemma returned no tool calls; falling back to the primary tool plan."
 appendAttempt(
 attemptIndex: specialistAttemptIndex,
 modelTier: .toolSpecialist,
 request: specialistRequest,
 recoveryEvents: [],
 completion: specialistAttempt.result,
 errorSummary: fallbackMessage
 )
 runtimeState.recoveryState = runtimeState.recoveryState.recordingContinuation(
 reason: .toolSpecialist,
 withheldRecoverableError: fallbackMessage
 )
 }
 } catch {
 let fallbackMessage = error.localizedDescription
 appendAttempt(
 attemptIndex: specialistAttemptIndex,
 modelTier: .toolSpecialist,
 request: specialistRequest,
 recoveryEvents: [],
 errorSummary: fallbackMessage
 )
 runtimeState.recoveryState = runtimeState.recoveryState.recordingContinuation(
 reason: .toolSpecialist,
 withheldRecoverableError: fallbackMessage
 )
 }
 }

 if result.toolCalls.isEmpty {
 let finalMsg = RelayMessage.assistant(
 AssistantContent(blocks: [.text(result.outputText)])
 )
 runtimeState.messages.append(finalMsg)
 runtimeState.recoveryState = runtimeState.recoveryState.updated(
 exit: .completed,
 errorMessage: nil,
 cloudFallbackUsedLastTurn: usedCloudFallback,
 turnCount: runtimeState.turnCount
 )
 continuation.yield(.done(finalMsg))
 return finalize(
 state: runtimeState,
 exit: .completed,
 finalAssistantMessage: finalMsg
 )
 }

 let assistantBlocks = result.toolCalls.map { AssistantBlock.toolUse($0.asToolUseBlock()) }
 runtimeState.messages.append(.assistant(AssistantContent(blocks: assistantBlocks)))
 runtimeState.recentToolState.activeToolUses = result.toolCalls.map {
 ToolUseSnapshot(id: $0.id, name: $0.name, inputJson: $0.inputJSON)
 }

 for use in result.toolCalls {
 continuation.yield(.toolCallStarted(
 name: use.name,
 toolUseId: use.id,
 inputJson: use.inputJSON
 ))
 }

 if Task.isCancelled {
 let interrupted = await finalizeInterruptedTurn(
 state: runtimeState,
 usedCloudFallback: usedCloudFallback,
 continuation: continuation
 )
 attemptDiagnostics = Self.appendingRecoveryEvents(
 [.cleaningUpInterruptedTurn, .clearProvisionalOutput],
 to: attemptDiagnostics
 )
 return finalize(
 state: interrupted.state,
 exit: interrupted.exit,
 finalAssistantMessage: nil
 )
 }

 let ctx = toolContextFor(runtimeState.messages)

 // dedupe: split tool uses into "fresh" (never run with
 // these args this turn) and "cached" (idempotent reads we
 // already executed). Only fresh uses go to the dispatcher;
 // cached uses get a reissued result block carrying THIS
 // iteration's `toolUseId` so the model sees a normal result.
 let allUses = result.toolCalls.map { $0.asToolUseBlock() }
 let toolByName: [String: any RelayTool] = Dictionary(
 tools.map { ($0.name, $0) },
 uniquingKeysWith: { f, _ in f }
 )
 var freshUses: [(originalIndex: Int, use: ToolUseBlock)] = []
 var cachedResults: [Int: ToolResultBlock] = [:]
 for (i, use) in allUses.enumerated() {
 let key = "\(use.name)|\(use.inputJson)"
 if let cached = idempotentToolResultCache[key] {
 print("[Tool] Deduped repeat call to \(use.name) (same args as prior call this turn)")
 cachedResults[i] = ToolResultBlock(
 toolUseId: use.id,
 output: cached.output,
 isError: cached.isError,
 metadata: cached.metadata
 )
 } else {
 freshUses.append((i, use))
 }
 }
 let batch: ToolDispatchBatch
 if freshUses.isEmpty {
 batch = ToolDispatchBatch(results: [], executions: [], approvals: [])
 } else {
 batch = await dispatcher.execute(
 freshUses.map { $0.use },
 tools: tools,
 context: ctx
 )
 }
 // Cache fresh results for idempotent (read-only) tools so a
 // future iteration in the same turn won't re-execute them.
 for (offset, fresh) in freshUses.enumerated() {
 if toolByName[fresh.use.name]?.isReadOnly == true,
 offset < batch.results.count {
 let key = "\(fresh.use.name)|\(fresh.use.inputJson)"
 idempotentToolResultCache[key] = batch.results[offset]
 }
 }
 // Reconstruct results in original tool-call order.
 var orderedResults: [ToolResultBlock] = []
 orderedResults.reserveCapacity(allUses.count)
 var freshIter = batch.results.makeIterator()
 for i in 0..<allUses.count {
 if let cached = cachedResults[i] {
 orderedResults.append(cached)
 } else if let fresh = freshIter.next() {
 orderedResults.append(fresh)
 }
 }
 let toolResults = orderedResults
 aggregatedToolExecutions.append(contentsOf: batch.executions)
 aggregatedApprovalDecisions.append(contentsOf: batch.approvals)

 if Task.isCancelled {
 let interrupted = await finalizeInterruptedTurn(
 state: runtimeState,
 usedCloudFallback: usedCloudFallback,
 continuation: continuation
 )
 attemptDiagnostics = Self.appendingRecoveryEvents(
 [.cleaningUpInterruptedTurn, .clearProvisionalOutput],
 to: attemptDiagnostics
 )
 return finalize(
 state: interrupted.state,
 exit: interrupted.exit,
 finalAssistantMessage: nil
 )
 }

 for block in toolResults {
 continuation.yield(.toolCallCompleted(
 toolUseId: block.toolUseId,
 result: ToolResult(
 toolUseId: block.toolUseId,
 output: block.output,
 isError: block.isError,
 metadata: block.metadata ?? [:]
 )
 ))
 }

 runtimeState.messages.append(.toolResult(toolResults))
 runtimeState.recentToolState.activeToolUses = []
 runtimeState.recentToolState.lastCompletedBatch = toolResults.map { block in
 ToolResultSummary(
 toolUseId: block.toolUseId,
 isError: block.isError,
 outputPreview: ToolResultSummary.preview(for: block.output),
 metadata: block.metadata
 )
 }
 runtimeState.recentToolState.lastCompletedAtTurnCount = runtimeState.turnCount

 if let shortCircuitMessage = Self.shortCircuitAllErrorToolBatch(toolResults) {
 runtimeState.messages.append(shortCircuitMessage)
 runtimeState.recoveryState = runtimeState.recoveryState.updated(
 exit: .completed,
 errorMessage: nil,
 cloudFallbackUsedLastTurn: usedCloudFallback,
 turnCount: runtimeState.turnCount
 )
 print("[Synthesis] all-error tool batch short-circuited count=\(toolResults.count)")
 continuation.yield(.done(shortCircuitMessage))
 return finalize(
 state: runtimeState,
 exit: .completed,
 finalAssistantMessage: shortCircuitMessage
 )
 }

 // synthesis-after-tool-result reminder.
 // Cloud Gemini's post-tool synthesis pass was producing two
 // failure modes on device: (a) empty assistant body — visible
 // as "Today is..." flashing then vanishing on the date query;
 // (b) vague paraphrase ("Looks like there's a list of events
 // or activities like a calendar.") instead of naming the
 // actual tool result content. Both share the same trigger
 // chokepoint: the `.toolResult` append above. Injecting a
 // hidden meta user reminder right after the tool batch nudges
 // the next iteration to quote concrete values.
 //
 // Direct-dispatch shortcuts are unaffected — they have their
 // own deterministic formatters (`formatCalendarListShortcutResult`
 // etc.) and never run a follow-up model synthesis.
 runtimeState.messages.append(
 MessageFactory.userSystemReminder(Self.synthesisReminderBody)
 )
 print("[Synthesis] reminder injected after tool_result count=\(toolResults.count)")
 runtimeState.recoveryState = runtimeState.recoveryState.recordingContinuation(reason: .toolFollowup)
 }

 continuation.yield(.clearProvisionalOutput)
 continuation.yield(.failure(
 message: "Agent loop hit \(maxLoops) iterations — breaking to prevent infinite loop"
 ))
 runtimeState.recoveryState = runtimeState.recoveryState.updated(
 exit: .maxTurns,
 errorMessage: "Agent loop hit \(maxLoops) iterations — breaking to prevent infinite loop",
 cloudFallbackUsedLastTurn: usedCloudFallback,
 turnCount: runtimeState.turnCount,
 lastContinuationReason: runtimeState.recoveryState.lastContinuationReason ?? .fatalError
 )
 return finalize(
 state: runtimeState,
 exit: .maxTurns,
 finalAssistantMessage: nil
 )
 }

 internal func runWithArtifacts(
 turnID: UUID,
 sessionID: String = "test-session",
 initialUserMessage: RelayMessage,
 state: AgentSessionState,
 contextBuilder: ContextBuilder,
 onDeviceClient: any ModelClient,
 cloudClient: (any ModelClient)?,
 toolSpecialistClient: (any ModelClient)? = nil,
 dispatcher: ToolDispatcher,
 toolContextFor: @Sendable ([RelayMessage]) -> ToolCallContext,
 tools: [any RelayTool],
 enabledToolNames: Set<String>,
 environment: SystemPrompt.Environment,
 extraSystemContext: [String: String],
 options: CactusModelHost.CompletionOptions,
 recoveryCompactor: Compactor? = nil,
 continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
 ) async -> RunResult {
 let initialTurn = NormalizedTurn(
 turnID: turnID,
 transcriptMessage: initialUserMessage,
 modelMessage: TurnIngressNormalizer.projectMessageForModel(initialUserMessage)
 )
 return await runWithArtifacts(
 turnID: turnID,
 sessionID: sessionID,
 initialTurn: initialTurn,
 state: state,
 contextBuilder: contextBuilder,
 onDeviceClient: LegacyModelClientHostAdapter(
 client: onDeviceClient,
 profileID: .gemmaLocal,
 tier: .fast
 ),
 cloudClient: cloudClient.map {
 LegacyModelClientHostAdapter(
 client: $0,
 profileID: .geminiCloud,
 tier: .cloud
 )
 },
 toolSpecialistClient: toolSpecialistClient.map {
 LegacyModelClientHostAdapter(
 client: $0,
 profileID: .functionGemmaTool,
 tier: .toolSpecialist
 )
 },
 dispatcher: dispatcher,
 toolContextFor: toolContextFor,
 tools: tools,
 toolCatalog: tools.map { $0.catalogEntry(source: .other) },
 enabledToolNames: enabledToolNames,
 environment: environment,
 extraSystemContext: extraSystemContext,
 options: options,
 recoveryCompactor: recoveryCompactor,
 continuation: continuation
 )
 }

 private func reactivelyCompact(
 runtimeState: AgentSessionState,
 currentTurnStartIndex: Int,
 priorHistoryTurnCount: Int,
 recoveryCompactor: Compactor
 ) async -> AgentSessionState? {
 guard currentTurnStartIndex > 0, currentTurnStartIndex <= runtimeState.messages.count else {
 return nil
 }

 let priorHistory = Array(runtimeState.messages.prefix(currentTurnStartIndex))
 let currentTurnMessages = Array(runtimeState.messages.dropFirst(currentTurnStartIndex))
 guard !priorHistory.isEmpty else { return nil }

 var priorState = AgentSessionState(
 messages: priorHistory,
 turnCount: priorHistoryTurnCount,
 autoCompactTracking: runtimeState.autoCompactTracking,
 summaryState: runtimeState.summaryState,
 recentToolState: .empty,
 pendingApprovalState: runtimeState.pendingApprovalState,
 retrievalState: .empty,
 recoveryState: runtimeState.recoveryState
 )

 let (compactedState, didCompact) = await recoveryCompactor.compact(state: priorState)
 guard didCompact else { return nil }
 priorState = compactedState

 var recoveredState = runtimeState
 recoveredState.messages = priorState.messages + currentTurnMessages
 recoveredState.autoCompactTracking = priorState.autoCompactTracking
 recoveredState.summaryState = priorState.summaryState
 return recoveredState
 }

 private func finalizeInterruptedTurn(
 state: AgentSessionState,
 usedCloudFallback: Bool,
 continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
 ) async -> (state: AgentSessionState, exit: TurnExit) {
 var runtimeState = state
 continuation.yield(.recoveryStateChanged(.cleaningUpInterruptedTurn))
 continuation.yield(.clearProvisionalOutput)

 let interruptedResults = runtimeState.recentToolState.activeToolUses.map { snapshot in
 MessageFactory.syntheticToolInterrupted(toolUseId: snapshot.id)
 }
 if !interruptedResults.isEmpty {
 for block in interruptedResults {
 continuation.yield(.toolCallCompleted(
 toolUseId: block.toolUseId,
 result: ToolResult(
 toolUseId: block.toolUseId,
 output: block.output,
 isError: block.isError,
 metadata: block.metadata ?? [:]
 )
 ))
 }
 runtimeState.messages.append(.toolResult(interruptedResults))
 runtimeState.recentToolState.lastCompletedBatch = interruptedResults.map { block in
 ToolResultSummary(
 toolUseId: block.toolUseId,
 isError: block.isError,
 outputPreview: ToolResultSummary.preview(for: block.output),
 metadata: block.metadata
 )
 }
 runtimeState.recentToolState.lastCompletedAtTurnCount = runtimeState.turnCount
 }
 runtimeState.recentToolState.activeToolUses = []
 runtimeState.recoveryState = runtimeState.recoveryState.updated(
 exit: .interrupted,
 errorMessage: nil,
 cloudFallbackUsedLastTurn: usedCloudFallback,
 turnCount: runtimeState.turnCount,
 lastContinuationReason: .interruptCleanup
 )
 return (runtimeState, .interrupted)
 }

 private static func streamCompletion(
 client: any ModelHostAdapter,
 request: CompiledTurnRequest,
 continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
 ) async throws -> StreamAttempt {
 var completionResult: CompiledTurnResponse?
 var emittedTokens = false

 // early-abort peek. We watch the first ~80
 // chars that the primary emits; if it starts with a help-desk
 // opener for a classification that the full validator would also
 // reject, we break the for-loop NOW. Breaking deallocates the
 // outer AsyncThrowingStream's continuation on the adapter's task,
 // which via `onTermination` calls `CactusModelHost.requestStopGeneration`
 // → `cactus_stop(handle)` on the native side. User-visible effect:
 // the bubble clears within ~1 line (~0.5s on device) instead of
 // the old ~5-7s wait for Gemma to finish streaming its help-desk
 // reply.
 //
 // We only arm the peek when a classification is available and
 // cloud fallback is allowed (otherwise breaking here leaves the
 // turn with no response). The full-response validator at L479-504
 // remains a safety net for subtler failures the prefix can't see.
 let peekClassification = request.bindingContext?.classification
 let canEarlyAbort =
 peekClassification != nil &&
 request.hostOptions.allowCloudHandoff &&
 client.tier == .fast
 var peekBuffer = ""
 var earlyAbortFired = false

 // Pre-route for known-weak-model failure modes (
 // T13 device log). Conversation-summarization and conversation-
 // recall prompts hallucinate on Gemma-4-E2B past ~15 messages
 // because the model's long-context attention collapses (device
 // T13: 25 msgs → `"very brief conversation..."`). If the pattern
 // matches, skip Gemma entirely: synthesize a cloudHandoff result
 // and return so the caller's cloud-retry branch at the outer
 // call site handles it. No message-count gate — matches are
 // rare and Gemma's reliability on even short summarize-our-chat
 // prompts is inconsistent. Same eligibility guards as the
 // early-abort peek above (requires `.fast` tier + cloud allowed
 // + classification known).
 // web-search pre-route. Explicit
 // search intent ("search the web for X", "what's the latest…",
 // "current price of Y") routes to Gemini cloud which then uses
 // Google Search grounding (`tools: [{googleSearch: {}}]`) to
 // answer with fresh real-world data. Replaces the prior Brave
 // Search API tool which required a paid subscription. Runs
 // BEFORE the conversation-summarization and long-context
 // pre-routes so search intent always grounds regardless of
 // history depth.
 if canEarlyAbort,
 let latestUserText = request.diagnostics.latestNonMetaUserText,
 TurnClassifier.isWebSearchIntent(latestUserText: latestUserText) {
 let classificationLabel = peekClassification.map(String.init(describing:)) ?? "nil"
 print("[Route] WEB-SEARCH pre-routed to cloud (classification=\(classificationLabel), messages=\(request.messages.count))")
 continuation.yield(.clearProvisionalOutput)
 return StreamAttempt(
 result: CompiledTurnResponse(
 tier: client.tier,
 outputText: "",
 toolCalls: [],
 finishReason: .cloudHandoff,
 rawCompletion: nil
 ),
 emittedTokens: false
 )
 }

 // — image-bearing turn pre-route. Gemma-4-E2B's vision
 // encoder on iPhone is significantly weaker than Gemini Flash;
 // running on-device first only to obedience-fail and bounce to
 // cloud wastes compute + battery + first-response latency. If the
 // latest user turn contains any `.image` block, skip primary
 // entirely — this is the #1 fix for "why don't uploaded images
 // work?". Placed AFTER web-search (search semantics win if both
 // fire) and BEFORE summarization.
 if canEarlyAbort,
 Self.latestUserTurnContainsImage(in: request.messages) {
 let classificationLabel = peekClassification.map(String.init(describing:)) ?? "nil"
 print("[Route] IMAGE-TURN pre-routed to cloud (classification=\(classificationLabel), messages=\(request.messages.count))")
 continuation.yield(.clearProvisionalOutput)
 return StreamAttempt(
 result: CompiledTurnResponse(
 tier: client.tier,
 outputText: "",
 toolCalls: [],
 finishReason: .cloudHandoff,
 rawCompletion: nil
 ),
 emittedTokens: false
 )
 }

 if canEarlyAbort,
 let latestUserText = request.diagnostics.latestNonMetaUserText,
 TurnClassifier.isConversationSummarizationRequest(
 latestUserText: latestUserText
 ) {
 let classificationLabel = peekClassification.map(String.init(describing:)) ?? "nil"
 print("[Route] LONG-CONTEXT-SUMMARIZATION pre-routed to cloud (classification=\(classificationLabel), messages=\(request.messages.count))")
 continuation.yield(.clearProvisionalOutput)
 return StreamAttempt(
 result: CompiledTurnResponse(
 tier: client.tier,
 outputText: "",
 toolCalls: [],
 finishReason: .cloudHandoff,
 rawCompletion: nil
 ),
 emittedTokens: false
 )
 }

 // long-context pre-route. Distinct from
 // the T13 conversation-summarization pre-route above: this fires
 // on ANY classification once history grows past the threshold,
 // because Gemma-4-E2B's effective coherent-generation window is
 // ~10-12 messages. Beyond that the model either hallucinates
 // (T8/T11 device log: ignored prompt, answered prior turn) or
 // pays a 30-50s prefill cost (T16/T17). Routing to cloud caps
 // per-turn latency at the cloud round-trip (~1-2s) and avoids
 // wasted on-device compute.
 //
 // Eligibility:
 // Same `canEarlyAbort` guard as the T13 path (classification
 // present + cloud allowed + .fast tier)
 // history depth >= 10 messages (5 user-assistant pairs)
 // toolMode != .required (let tool-intent turns run on-device
 // so FunctionGemma routing isn't bypassed)
 if canEarlyAbort,
 request.messages.count >= 10,
 request.hostOptions.toolMode != .required {
 let classificationLabel = peekClassification.map(String.init(describing:)) ?? "nil"
 print("[Route] LONG-CONTEXT pre-routed to cloud (classification=\(classificationLabel), messages=\(request.messages.count))")
 continuation.yield(.clearProvisionalOutput)
 return StreamAttempt(
 result: CompiledTurnResponse(
 tier: client.tier,
 outputText: "",
 toolCalls: [],
 finishReason: .cloudHandoff,
 rawCompletion: nil
 ),
 emittedTokens: false
 )
 }

 for try await event in client.streamTurn(request) {
 switch event {
 case .token(let token):
 emittedTokens = true
 continuation.yield(.tokenReceived(token))

 if canEarlyAbort, !earlyAbortFired {
 peekBuffer += token
 if peekBuffer.count >= 40,
 let classification = peekClassification,
 ResponseObedienceValidator.isEarlyAbortCandidate(
 prefix: peekBuffer,
 classification: classification
 ) {
 earlyAbortFired = true
 print("[Obedience] EARLY-ABORT primary at \(peekBuffer.count) chars (classification=\(classification)); native cactus_stop dispatched.")
 continuation.yield(.clearProvisionalOutput)
 // Synthesize a cloud-handoff result so the caller
 // takes the existing cloud-retry branch. We do NOT
 // wait for `.finished` — the native stop is in
 // flight and the outer for-loop will fall through
 // once the adapter's task finishes unwinding.
 completionResult = CompiledTurnResponse(
 tier: client.tier,
 outputText: "",
 toolCalls: [],
 finishReason: .cloudHandoff,
 rawCompletion: nil
 )
 break
 }
 }
 case .finished(let result):
 if earlyAbortFired {
 // Native runtime returned a partial result after stop.
 // Prefer our synthesized cloudHandoff marker; discard
 // the partial.
 continue
 }
 completionResult = result
 }
 }

 return StreamAttempt(result: completionResult, emittedTokens: emittedTokens)
 }

 /// — does the latest user turn in the message history carry
 /// any `.image` block? True image-bearing turns should pre-route to
 /// cloud because Gemma-4-E2B's vision encoder is much weaker than
 /// Gemini Flash. Walks messages in reverse to find the most recent
 /// `.user` message, then inspects its blocks.
 private static func latestUserTurnContainsImage(in messages: [RelayMessage]) -> Bool {
 for message in messages.reversed() {
 guard case .user(let content) = message else { continue }
 for block in content.blocks {
 if case .image = block { return true }
 }
 return false // most recent user message had no images
 }
 return false
 }

 /// — cloud tier gets a wider output budget than on-device's
 /// default 2048. Gemini 2.5 Flash can emit up to 65K tokens; agent
 /// tool-chain + synthesis turns need >2K headroom. 8192 is a safe
 /// middle ground (avoids tail-latency blowup). Applied at every
 /// `request.with(profileID: .geminiCloud, ...)` construction point.
 private static func widenCloudMaxTokens(
 _ opts: CactusModelHost.CompletionOptions
 ) -> CactusModelHost.CompletionOptions {
 var out = opts
 out.maxTokens = max(out.maxTokens, 8192)
 return out
 }

 private static func appendingRecoveryEvents(
 _ events: [TurnRecoveryEventDiagnostic],
 to attempts: [TurnAttemptDiagnostics]
 ) -> [TurnAttemptDiagnostics] {
 guard !events.isEmpty, var last = attempts.last else { return attempts }
 var updated = attempts
 last = TurnAttemptDiagnostics(
 attemptIndex: last.attemptIndex,
 modelTier: last.modelTier,
 requestMessages: last.requestMessages,
 systemPrompt: last.systemPrompt,
 promptDiagnostics: last.promptDiagnostics,
 currentTurnFocus: last.currentTurnFocus,
 retrievalDecision: last.retrievalDecision,
 wasTruncated: last.wasTruncated,
 emittedRecoveryEvents: last.emittedRecoveryEvents + events,
 completionSnapshot: last.completionSnapshot,
 errorSummary: last.errorSummary,
 compiledRequest: last.compiledRequest,
 compiledResponse: last.compiledResponse
 )
 updated[updated.count - 1] = last
 return updated
 }

 private static func classify(error: Error, duringCloudRetry: Bool) -> RecoverableFailure {
 if error is CancellationError {
 return .interrupted
 }

 if let geminiError = error as? GeminiClient.GeminiError {
 switch geminiError {
 case .httpError(413, let body):
 return .promptTooLong(body)
 case .httpError(400, let body) where isPromptTooLongMessage(body):
 return .promptTooLong(body)
 case .networkError(let message):
 return duringCloudRetry ? .cloudRetryFailed(message) : .fatal(message)
 case .httpError(let code, let body) where duringCloudRetry && code >= 500:
 return .cloudRetryFailed(body)
 case .quotaExhausted:
 // #3 — quota errors are
 // user-facing terminal failures, NOT retryable in the
 // current turn. Surface the friendly errorDescription
 // verbatim so the bubble shows the Glass-shaped
 // sentence (no "Cloud retry error:" prefix added — see
 // the AgentRunner failure-yield sites which skip the
 // prefix when the message starts with `"Cloud quota
 // exhausted"`).
 return .fatal(geminiError.localizedDescription)
 case .missingAPIKey:
 return .fatal(GeminiClient.GeminiError.missingAPIKey.localizedDescription)
 case .httpError(_, let body), .invalidResponse(let body):
 return .fatal(body)
 }
 }

 if case CactusModelHost.HostError.inferenceFailed(let message) = error,
 Self.isPromptTooLongMessage(message) {
 return .promptTooLong(message)
 }

 return .fatal(error.localizedDescription)
 }

 private static func isPromptTooLongMessage(_ message: String) -> Bool {
 let normalized = message.lowercased()
 return promptTooLongMarkers.contains { normalized.contains($0) }
 }

 /// Text-only fallback from the on-device result. Strips tool calls to
 /// prevent state changes from a model that self-assessed as
 /// inadequate (`cloudHandoff`).
 ///
 /// Empty-output guard: when primary early-aborts (,
 /// ), the synthesized `CompiledTurnResponse` has
 /// `outputText == ""` so the UI can clear the provisional bubble. If
 /// cloud fallback is ALSO invoked and its response ALSO fails
 /// re-validation (), this function is called with an empty
 /// `result.outputText`. Guard: if the on-device text is empty or
 /// whitespace, surface `emptyFallbackMessage` instead of a near-empty
 /// bubble.
 ///
 /// Important: this helper is NOT a single "cloud unavailable"
 /// pathway. `reason` distinguishes true availability failures
 /// (`noCloudClient`, retry failure, no completion result) from the
 /// "cloud returned text but it was rejected by the validator" case.
 /// The latter intentionally does NOT append the unavailable disclaimer.
 internal static let emptyFallbackMessage =
 "I couldn't generate a reliable response for that message. Try rephrasing, or ask something more specific."

 /// body of the meta user reminder injected after
 /// every `.toolResult` batch. Wrapped in `<system-reminder>` tags by
 /// `MessageFactory.userSystemReminder(_:)` and sent as `isMeta: true`
 /// (hidden from chat transcript). Tells cloud Gemini to quote concrete
 /// values from the tool results rather than emit empty text or vague
 /// paraphrases of the structure.
 internal static let synthesisReminderBody: String =
 """
 Tool results above contain the data needed to answer the user's request.
 In your reply, answer using the concrete values from the tool results that are relevant (dates, times, titles, names, counts, numbers). Do not give a generic structural summary like "there's a list" or "it seems to be". If multiple tools ran, cover each relevant result. Keep the reply to 1-3 sentences unless the user asked for more detail.
 """

 internal static func textOnlyFallback(
 from result: CompiledTurnResponse,
 reason: TextOnlyFallbackReason
 ) -> CompiledTurnResponse {
 let trimmed = result.outputText
 .trimmingCharacters(in: .whitespacesAndNewlines)
 let isEmpty = trimmed.isEmpty
 let fallbackSuffix = reason.shouldAppendUnavailableDisclaimer
 ? "\n\n[Cloud fallback unavailable — showing on-device response]"
 : ""
 let fallbackOutputText = isEmpty
 ? emptyFallbackMessage
 : result.outputText + fallbackSuffix
 let rawCompletion = result.rawCompletion.map { snapshot in
 let snapshotText = isEmpty
 ? emptyFallbackMessage
 : snapshot.text + fallbackSuffix
 return CompletionSnapshot(
 text: snapshotText,
 toolCalls: [],
 confidence: snapshot.confidence,
 cloudHandoff: false,
 prefillTPS: snapshot.prefillTPS,
 decodeTPS: snapshot.decodeTPS,
 timeToFirstTokenMs: snapshot.timeToFirstTokenMs,
 totalTimeMs: snapshot.totalTimeMs,
 ramUsageMB: snapshot.ramUsageMB
 )
 }
 return CompiledTurnResponse(
 tier: result.tier,
 outputText: fallbackOutputText,
 toolCalls: [],
 finishReason: .message,
 rawCompletion: rawCompletion
 )
 }

 internal static func shortCircuitAllErrorToolBatch(_ toolResults: [ToolResultBlock]) -> RelayMessage? {
 guard !toolResults.isEmpty, toolResults.allSatisfy(\.isError) else {
 return nil
 }

 let firstNonEmptyError = toolResults
 .lazy
 .map(\.output)
 .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
 .first { !$0.isEmpty }

 return MessageFactory.assistantText(firstNonEmptyError ?? emptyFallbackMessage)
 }

 // MARK: - direct-dispatch shortcut

 /// Resolved shortcut: which tool to dispatch + how to format the
 /// tool's raw output as a Glass-shaped bubble sentence.
 internal struct DirectDispatchShortcut {
 let toolName: String
 let inputJson: String
 let formatter: @Sendable (String) -> String
 }

 /// 1 `calendar_list_events` shortcut.
 /// Same exact-equality semantic as `tightTimeDatePhrases`. Tool
 /// defaults handle the date range (today + 7 days) so zero-arg
 /// dispatch is safe.
 private static let tightCalendarListPhrases: Set<String> = [
 "what s on my calendar",
 "what s on my calendar today",
 "show my calendar",
 "show me my calendar",
 "my calendar",
 "what s on my schedule",
 "show my schedule",
 "my schedule",
 "what events do i have",
 "what s scheduled",
 "upcoming events",
 "upcoming calendar events",
 "calendar events",
 "what do i have today",
 "what do i have this week",
 // 3 : date-qualifier variants. Combined with
 // `calendarRangeJSON(forNormalized:)` so the shortcut respects the
 // qualifier instead of always querying the default 7-day range.
 "what s on my calendar tomorrow",
 "what is on my calendar tomorrow",
 "what do i have tomorrow",
 "my schedule tomorrow",
 "what s on my calendar this week",
 "what s on my calendar next week",
 "what do i have next week",
 "my schedule this week",
 // "in my calendar" variants — natural
 // English phrasing we missed. Isaac hit this with "What's in my
 // calendar today?" and the shortcut missed → fell into on-device
 // model loop with slow CPU prefill → looked like a hang.
 "what s in my calendar",
 "what s in my calendar today",
 "what is in my calendar today",
 "what s in my calendar tomorrow",
 "what is in my calendar tomorrow",
 "what s in my calendar this week",
 "what s in my calendar next week"
 ]

 /// 1 `reminders_list` shortcut.
 /// Tool defaults to incomplete reminders; zero-arg dispatch is safe.
 private static let tightRemindersListPhrases: Set<String> = [
 "what reminders do i have",
 "show my reminders",
 "show me my reminders",
 "my reminders",
 "list my reminders",
 "list reminders",
 "pending reminders",
 "incomplete reminders",
 "what s on my to do",
 "what s on my todo",
 "my to do list",
 "my todo list",
 "what do i need to do",
 "what tasks do i have"
 ]

 /// Tight whitelist of normalized phrases that map to
 /// `get_current_datetime`. EXACT-EQUALITY match (not substring) so
 /// longer prompts that happen to contain "the time" don't get
 /// hijacked. Normalized form: lowercase, punctuation collapsed to
 /// single spaces (matches `TurnClassifier.normalizedComparisonText`).
 private static let tightTimeDatePhrases: Set<String> = [
 "what time is it",
 "what s the time",
 "whats the time",
 "what is the time",
 "tell me the time",
 "current time",
 "the current time",
 "check the time",
 "what time",
 "time now",
 "what s today s date",
 "what is today s date",
 "what s the date",
 "what is the date",
 "today s date",
 "current date",
 "the current date",
 "check the date",
 "what day is it",
 "what s the day"
 ]

 /// Inspect the user's latest message and decide if it matches an
 /// unambiguous shortcut. Returns nil for everything that should go
 /// through the normal model loop.
 internal static func resolveDirectDispatchShortcut(
 initialUserMessage: RelayMessage
 ) -> DirectDispatchShortcut? {
 guard case .user(let content) = initialUserMessage else { return nil }
 guard !content.isMeta else { return nil }
 let text = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t }
 return nil
 }
 .joined(separator: " ")
 .trimmingCharacters(in: .whitespacesAndNewlines)
 guard !text.isEmpty else { return nil }

 let normalized = TurnClassifier.normalizedComparisonText(text)
 if tightTimeDatePhrases.contains(normalized) {
 return DirectDispatchShortcut(
 toolName: "get_current_datetime",
 inputJson: "{}",
 formatter: Self.formatDateTimeShortcutResult
 )
 }
 // 1 extend shortcut to two
 // more zero-arg-invocable read tools. Same architectural shape:
 // exact-equality match on normalized text → bypass model loop
 // → dispatch tool → format result.
 if tightCalendarListPhrases.contains(normalized) {
 return DirectDispatchShortcut(
 toolName: "calendar_list_events",
 inputJson: Self.calendarRangeJSON(forNormalized: normalized),
 formatter: Self.formatCalendarListShortcutResult
 )
 }
 if tightRemindersListPhrases.contains(normalized) {
 return DirectDispatchShortcut(
 toolName: "reminders_list",
 inputJson: "{}",
 formatter: Self.formatRemindersListShortcutResult
 )
 }
 return nil
 }

 /// 3 — translate the user's date qualifier
 /// (`tomorrow` / `this week` / `next week` / `today`) into the
 /// `start_date`/`end_date` pair the calendar tool expects. Returns
 /// `"{}"` when no qualifier is present, leaving the tool to apply
 /// its own 7-day default.
 ///
 /// "this week" = now → end of this calendar week (Sunday 23:59).
 /// "next week" = next Monday 00:00 → following Sunday 23:59.
 /// "tomorrow" = tomorrow 00:00 → tomorrow 23:59.
 /// "today" = now → today 23:59.
 internal static func calendarRangeJSON(forNormalized normalized: String) -> String {
 let cal = Calendar.current
 let now = Date()
 let iso = ISO8601DateFormatter()
 iso.formatOptions = [.withInternetDateTime]

 func endOfDay(_ start: Date) -> Date {
 cal.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
 }

 if normalized.contains("tomorrow") {
 let startOfTomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now)!)
 return #"{"start_date":"\#(iso.string(from: startOfTomorrow))","end_date":"\#(iso.string(from: endOfDay(startOfTomorrow)))"}"#
 }
 if normalized.contains("next week") {
 // Find next Monday (weekday = 2 in Calendar.current). Always
 // jump at least 1 day so "next week" on a Monday lands on the
 // FOLLOWING Monday, not today.
 let weekday = cal.component(.weekday, from: now) // 1 = Sun ... 7 = Sat
 let daysToNextMonday = ((9 - weekday) % 7 == 0) ? 7 : ((9 - weekday) % 7)
 let startOfNextWeek = cal.startOfDay(for: cal.date(byAdding: .day, value: daysToNextMonday, to: now)!)
 let endOfNextWeek = cal.date(byAdding: .day, value: 7, to: startOfNextWeek)!.addingTimeInterval(-1)
 return #"{"start_date":"\#(iso.string(from: startOfNextWeek))","end_date":"\#(iso.string(from: endOfNextWeek))"}"#
 }
 if normalized.contains("this week") {
 // Now → end of this week (next Sunday 23:59:59).
 let weekday = cal.component(.weekday, from: now)
 let daysToSunday = (8 - weekday) % 7
 let startOfNextDay = cal.startOfDay(for: cal.date(byAdding: .day, value: daysToSunday + 1, to: now)!)
 let endOfThisWeek = startOfNextDay.addingTimeInterval(-1)
 return #"{"start_date":"\#(iso.string(from: now))","end_date":"\#(iso.string(from: endOfThisWeek))"}"#
 }
 if normalized.contains("today") {
 let endOfToday = endOfDay(cal.startOfDay(for: now))
 return #"{"start_date":"\#(iso.string(from: now))","end_date":"\#(iso.string(from: endOfToday))"}"#
 }
 return "{}"
 }

 /// 1 render `CalendarListEventsTool`
 /// output as a single Glass-shaped sentence. Tool's raw shape:
 /// "Found N events:\n- HH:MM AM/PM: Title @ Location [Cal]\n..."
 /// or "No events found in the specified range."
 /// or "Error: Calendar access denied." (passed through unchanged).
 @Sendable
 internal static func formatCalendarListShortcutResult(_ raw: String) -> String {
 if raw.hasPrefix("Error:") { return raw }
 if raw.contains("No events found") {
 return "Your calendar is clear for the next 7 days."
 }
 let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
 // Header line is "Found N events:" — skip it.
 let bullets = lines.dropFirst().filter { $0.hasPrefix("- ") }
 guard !bullets.isEmpty else { return raw }
 // Each bullet shape: "- HH:MM AM/PM: Title @ Location [Cal]" or
 // "- All day: Title [Cal]". Strip the leading "- " then split on
 // the first ": " to separate time from title. Drop "[Cal]" tag
 // and "@ Location" suffix to keep the sentence short.
 let summarized: [String] = bullets.map { bullet in
 let inner = String(bullet.dropFirst(2)) // remove "- "
 let parts = inner.split(separator: ":", maxSplits: 1).map(String.init)
 guard parts.count == 2 else { return inner }
 let time = parts[0]
 var rest = parts[1].trimmingCharacters(in: .whitespaces)
 if let atIndex = rest.range(of: " @ ") {
 rest = String(rest[..<atIndex.lowerBound])
 }
 if let bracketIndex = rest.range(of: " [") {
 rest = String(rest[..<bracketIndex.lowerBound])
 }
 return "\(time) \(rest.trimmingCharacters(in: .whitespaces))"
 }
 let count = summarized.count
 let plural = count == 1 ? "event" : "events"
 return "You have \(count) \(plural) coming up: " + summarized.joined(separator: "; ") + "."
 }

 /// 1 render `RemindersListTool`
 /// output as a single Glass-shaped sentence. Tool's raw shape:
 /// "Found N reminders:\n[ ] Title (due: Date) [List]\n..."
 /// or "No reminders found."
 /// or "Error: Reminders access denied."
 @Sendable
 internal static func formatRemindersListShortcutResult(_ raw: String) -> String {
 if raw.hasPrefix("Error:") { return raw }
 if raw.contains("No reminders found") {
 return "You have no pending reminders."
 }
 let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
 // Header is "Found N reminders:". Bullets start with "[ ]" or "[x]".
 let bullets = lines.dropFirst().filter { $0.hasPrefix("[") }
 guard !bullets.isEmpty else { return raw }
 // Shape: "[ ] Title (due: Date) [ListName]". Strip the checkbox
 // and trailing "[ListName]" tag; keep the title + due hint.
 let summarized: [String] = bullets.map { bullet in
 // Drop "[ ] " or "[x] " prefix (4 chars).
 let withoutCheckbox = bullet.count >= 4
 ? String(bullet.dropFirst(4))
 : bullet
 // Strip trailing " [ListName]".
 var trimmed = withoutCheckbox
 if let lastBracketStart = trimmed.range(of: " [", options: .backwards) {
 trimmed = String(trimmed[..<lastBracketStart.lowerBound])
 }
 return trimmed.trimmingCharacters(in: .whitespaces)
 }
 let count = summarized.count
 let plural = count == 1 ? "reminder" : "reminders"
 return "You have \(count) pending \(plural): " + summarized.joined(separator: "; ") + "."
 }

 /// Render the multi-line `DateTimeTool` output (`Date: ...\nTime:
 /// ...\nWeekday: ...\nTimezone: ...\nISO8601: ...`) as a single
 /// human-readable sentence: `"It's HH:MM on Weekday, YYYY-MM-DD."`.
 /// Falls back to the raw output if the parse fails so we never
 /// produce a worse UX than today.
 @Sendable
 internal static func formatDateTimeShortcutResult(_ raw: String) -> String {
 var date = ""
 var time = ""
 var weekday = ""
 for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
 let parts = line.split(separator: ":", maxSplits: 1)
 guard parts.count == 2 else { continue }
 let key = parts[0].trimmingCharacters(in: .whitespaces)
 let value = parts[1].trimmingCharacters(in: .whitespaces)
 switch key {
 case "Date":
 date = value
 case "Time":
 // Drop seconds: "11:39:00" -> "11:39"
 time = String(value.prefix(5))
 case "Weekday":
 weekday = value
 default:
 break
 }
 }
 if !time.isEmpty, !weekday.isEmpty, !date.isEmpty {
 return "It's \(time) on \(weekday), \(date)."
 }
 return raw
 }

 /// Execute a resolved shortcut: dispatch the tool, format the
 /// result, append messages to the runtime state, return RunResult.
 /// Mirrors the success-path message shape that the normal model
 /// loop produces (assistant-with-toolUse, toolResult, assistant-
 /// with-text) so downstream consumers (TurnCommitCoordinator,
 /// SessionStore, MemoryWritebackCoordinator) see the same input
 /// shape regardless of which path served the turn.
 internal static func runDirectDispatchShortcut(
 turnID: UUID,
 runtimeState: AgentSessionState,
 acceptedUserMessage: RelayMessage,
 shortcut: DirectDispatchShortcut,
 dispatcher: ToolDispatcher,
 toolContextFor: @Sendable ([RelayMessage]) -> ToolCallContext,
 tools: [any RelayTool],
 continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
 ) async -> RunResult {
 var state = runtimeState

 let toolUse = ToolUseBlock(
 id: UUID().uuidString,
 name: shortcut.toolName,
 inputJson: shortcut.inputJson
 )
 let assistantToolMsg = RelayMessage.assistant(
 AssistantContent(blocks: [.toolUse(toolUse)])
 )
 state.messages.append(assistantToolMsg)

 print("[Tool] direct-dispatch fired for \(shortcut.toolName) (intent shortcut, no model loop)")
 continuation.yield(.toolCallStarted(
 name: shortcut.toolName,
 toolUseId: toolUse.id,
 inputJson: shortcut.inputJson
 ))

 let ctx = toolContextFor(state.messages)
 let batch = await dispatcher.execute([toolUse], tools: tools, context: ctx)

 let resultBlock: ToolResultBlock
 if let first = batch.results.first {
 resultBlock = first
 } else {
 // Tool not registered / dispatcher returned empty. Surface a
 // clear user-facing message; never crash. This is a
 // configuration bug (tool list missing get_current_datetime)
 // but the user shouldn't see a broken UI for it.
 let errMsg = "I couldn't reach the \(shortcut.toolName) tool. Try again or rephrase."
 let errAssistant = RelayMessage.assistant(
 AssistantContent(blocks: [.text(errMsg)])
 )
 state.messages.append(errAssistant)
 state.recoveryState = state.recoveryState.updated(
 exit: .completed,
 errorMessage: nil,
 cloudFallbackUsedLastTurn: false,
 turnCount: state.turnCount
 )
 continuation.yield(.done(errAssistant))
 return RunResult(
 state: state,
 artifacts: TurnRunArtifacts(
 turnID: turnID,
 exit: .completed,
 recoveryState: state.recoveryState,
 attempts: [],
 acceptedUserMessage: acceptedUserMessage,
 finalAssistantMessage: errAssistant,
 toolExecutions: batch.executions,
 approvalDecisions: batch.approvals
 )
 )
 }

 state.messages.append(.toolResult([resultBlock]))
 continuation.yield(.toolCallCompleted(
 toolUseId: toolUse.id,
 result: ToolResult(
 toolUseId: toolUse.id,
 output: resultBlock.output,
 isError: resultBlock.isError,
 metadata: resultBlock.metadata ?? [:]
 )
 ))

 let bubbleText = shortcut.formatter(resultBlock.output)
 let finalMsg = RelayMessage.assistant(
 AssistantContent(blocks: [.text(bubbleText)])
 )
 state.messages.append(finalMsg)
 state.recoveryState = state.recoveryState.updated(
 exit: .completed,
 errorMessage: nil,
 cloudFallbackUsedLastTurn: false,
 turnCount: state.turnCount
 )
 continuation.yield(.done(finalMsg))

 return RunResult(
 state: state,
 artifacts: TurnRunArtifacts(
 turnID: turnID,
 exit: .completed,
 recoveryState: state.recoveryState,
 attempts: [],
 acceptedUserMessage: acceptedUserMessage,
 finalAssistantMessage: finalMsg,
 toolExecutions: batch.executions,
 approvalDecisions: batch.approvals
 )
 )
 }
}
