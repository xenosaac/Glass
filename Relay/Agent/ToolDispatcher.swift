import Foundation

/// Executes a batch of tool uses from a single model turn.
///
/// Tools marked `isConcurrencySafe` run in parallel via `TaskGroup`.
/// All others run serially. Results are returned in the original call order
/// regardless of execution order. implements a `StreamingToolExecutor`
/// dispatch pattern.
///
/// Glass 2.0 Module C: `execute(...)` returns a `ToolDispatchBatch` whose
/// `results` field preserves the legacy surface for `AgentRunner`, while
/// `executions` and `approvals` carry the canonical typed records. The
/// typed records are produced for every tool use (and every broker
/// evaluation); `TurnRunArtifacts` / storage wiring is deferred to
/// Modules B / D.
public struct ToolDispatcher: Sendable {
 /// Async confirmation handler: (toolUseId, toolName, prompt) → approved?
 /// If nil, .askUser falls back to returning an error (legacy behavior).
 let confirmationHandler: (@Sendable (_ toolUseId: String, _ toolName: String, _ prompt: String) async -> Bool)?

 public init(confirmationHandler: (@Sendable (_ toolUseId: String, _ toolName: String, _ prompt: String) async -> Bool)? = nil) {
 self.confirmationHandler = confirmationHandler
 }

 public func execute(
 _ toolUses: [ToolUseBlock],
 tools: [any RelayTool],
 context: ToolCallContext
 ) async -> ToolDispatchBatch {
 guard !toolUses.isEmpty else {
 return ToolDispatchBatch(results: [], executions: [], approvals: [])
 }

 let toolByName: [String: any RelayTool] = Dictionary(
 tools.map { ($0.name, $0) },
 uniquingKeysWith: { first, _ in first }
 )

 var concurrentIndices: [Int] = []
 var serialIndices: [Int] = []
 for (i, use) in toolUses.enumerated() {
 if toolByName[use.name]?.isConcurrencySafe == true {
 concurrentIndices.append(i)
 } else {
 serialIndices.append(i)
 }
 }

 var outcomes: [CallOutcome?] = Array(repeating: nil, count: toolUses.count)

 // Concurrent-safe tools run in parallel
 if !concurrentIndices.isEmpty {
 await withTaskGroup(of: (Int, CallOutcome).self) { group in
 for idx in concurrentIndices {
 let use = toolUses[idx]
 if let tool = toolByName[use.name] {
 group.addTask {
 let outcome = await Self.callTool(
 use: use,
 tool: tool,
 context: context,
 confirmationHandler: self.confirmationHandler
 )
 return (idx, outcome)
 }
 } else {
 outcomes[idx] = Self.notFoundOutcome(use)
 }
 }
 for await (idx, outcome) in group {
 outcomes[idx] = outcome
 }
 }
 }

 // Serial tools run one at a time
 for idx in serialIndices {
 let use = toolUses[idx]
 if let tool = toolByName[use.name] {
 outcomes[idx] = await Self.callTool(
 use: use,
 tool: tool,
 context: context,
 confirmationHandler: confirmationHandler
 )
 } else {
 outcomes[idx] = Self.notFoundOutcome(use)
 }
 }

 var results: [ToolResultBlock] = []
 results.reserveCapacity(toolUses.count)
 var executions: [ToolExecutionRecord] = []
 executions.reserveCapacity(toolUses.count)
 var approvals: [ApprovalDecisionRecord] = []

 for (i, outcome) in outcomes.enumerated() {
 if let outcome {
 results.append(outcome.result)
 executions.append(outcome.execution)
 if let approval = outcome.approval {
 approvals.append(approval)
 }
 } else {
 // Defensive: should be unreachable because every index is filled above.
 let fallback = ToolResultBlock(
 toolUseId: toolUses[i].id,
 output: "dispatch error",
 isError: true
 )
 results.append(fallback)
 executions.append(ToolExecutionRecord(
 toolName: toolUses[i].name,
 approved: false,
 startedAt: Date(),
 finishedAt: Date(),
 inputPreview: "",
 outputPreview: "dispatch error",
 source: .other
 ))
 }
 }

 // aggregate-budget enforcement. Even with each
 // tool under its per-tool cap, multi-tool turns can blow the per-
 // message budget (CC's MAX_TOOL_RESULTS_PER_MESSAGE_CHARS = 200K
 // at `utils/toolLimits.ts:49`). Largest-first eviction matches CC
 // `selectFreshToReplace` at `toolResultStorage.ts:675-691`.
 let outputs = results.enumerated().map { (i, block) in
 (toolName: toolUses[i].name, toolUseId: block.toolUseId, output: block.output)
 }
 let bounded = ToolResultPersistor.enforceAggregateBudget(
 outputs: outputs,
 sessionId: context.session.id
 )
 results = results.enumerated().map { (i, block) in
 ToolResultBlock(
 toolUseId: block.toolUseId,
 output: bounded[i],
 isError: block.isError,
 metadata: block.metadata
 )
 }

 return ToolDispatchBatch(
 results: results,
 executions: executions,
 approvals: approvals
 )
 }

 // MARK: - Private

 /// Bundle of records produced per tool use. Approval is nil only on the
 /// tool-not-found path, where the broker is never consulted.
 private struct CallOutcome {
 let result: ToolResultBlock
 let execution: ToolExecutionRecord
 let approval: ApprovalDecisionRecord?
 }

 private static func callTool(
 use: ToolUseBlock,
 tool: any RelayTool,
 context: ToolCallContext,
 confirmationHandler: (@Sendable (_ toolUseId: String, _ toolName: String, _ prompt: String) async -> Bool)? = nil
 ) async -> CallOutcome {
 let input = ToolInput(json: use.inputJson.data(using: .utf8) ?? Data())
 let startedAt = Date()

 // Per-tool context with toolUseId-injected progress callback (unchanged).
 let toolContext = ToolCallContext(
 messages: context.messages,
 session: context.session,
 approvalBroker: context.approvalBroker,
 progress: { progress in
 let realProgress = ToolProgress(
 toolUseId: use.id,
 message: progress.message,
 percent: progress.percent
 )
 context.progress(realProgress)
 },
 services: context.services
 )

 let decision = await toolContext.approvalBroker.evaluate(
 tool: tool,
 input: input,
 context: toolContext
 )

 switch decision {
 case .deny(let reason):
 let finishedAt = Date()
 let normalizer = ToolPolicyNormalizer()
 return CallOutcome(
 result: MessageFactory.syntheticToolDenied(toolUseId: use.id, reason: reason),
 execution: ToolExecutionRecord(
 toolName: tool.name,
 approved: false,
 startedAt: startedAt,
 finishedAt: finishedAt,
 inputPreview: use.inputJson,
 outputPreview: "Permission denied: \(reason)",
 source: .other
 ),
 approval: normalizer.decisionRecord(
 for: tool,
 outcome: .brokerDenied,
 reason: reason,
 decidedAt: finishedAt
 )
 )

 case .confirm(let request):
 // Emit progress showing the tool is waiting for approval.
 toolContext.progress(ToolProgress(
 toolUseId: use.id,
 message: "Awaiting approval: \(request.prompt)"
 ))

 if let handler = confirmationHandler {
 let approved = await handler(use.id, tool.name, request.prompt)
 if approved {
 return await Self.runApprovedCall(
 use: use,
 tool: tool,
 input: input,
 toolContext: toolContext,
 startedAt: startedAt,
 approvalOutcome: .userApproved,
 approvalReason: nil
 )
 } else {
 let finishedAt = Date()
 let normalizer = ToolPolicyNormalizer()
 return CallOutcome(
 result: MessageFactory.syntheticUserDenied(
 toolUseId: use.id,
 prompt: request.prompt
 ),
 execution: ToolExecutionRecord(
 toolName: tool.name,
 approved: false,
 startedAt: startedAt,
 finishedAt: finishedAt,
 inputPreview: use.inputJson,
 outputPreview: "User denied: \(request.prompt)",
 source: .other
 ),
 approval: normalizer.decisionRecord(
 for: tool,
 outcome: .userDenied,
 reason: request.prompt,
 decidedAt: finishedAt
 )
 )
 }
 }

 // Fallback: no confirmation handler registered.
 let finishedAt = Date()
 let normalizer = ToolPolicyNormalizer()
 return CallOutcome(
 result: MessageFactory.syntheticConfirmationRequired(
 toolUseId: use.id,
 prompt: request.prompt
 ),
 execution: ToolExecutionRecord(
 toolName: tool.name,
 approved: false,
 startedAt: startedAt,
 finishedAt: finishedAt,
 inputPreview: use.inputJson,
 outputPreview: "Confirmation required: \(request.prompt). No confirmation handler available.",
 source: .other
 ),
 approval: normalizer.decisionRecord(
 for: tool,
 outcome: .deferredNoHandler,
 reason: request.prompt,
 decidedAt: finishedAt
 )
 )

 case .allow:
 return await Self.runApprovedCall(
 use: use,
 tool: tool,
 input: input,
 toolContext: toolContext,
 startedAt: startedAt,
 approvalOutcome: .autoAllowed,
 approvalReason: nil
 )
 }
 }

 /// Execute the tool and build its records for the already-approved path.
 /// Shared between `.allow` and `.confirm + userApproved`. On throw, the
 /// execution record still carries `approved = true` (the call was
 /// approved — it just failed to produce a non-error result).
 private static func runApprovedCall(
 use: ToolUseBlock,
 tool: any RelayTool,
 input: ToolInput,
 toolContext: ToolCallContext,
 startedAt: Date,
 approvalOutcome: ApprovalOutcome,
 approvalReason: String?
 ) async -> CallOutcome {
 let normalizer = ToolPolicyNormalizer()

 // pre-dispatch input validation. Matches CC's
 // `inputSchema.safeParse(input)` pattern at
 // `services/tools/toolOrchestration.ts:97`. Catches malformed JSON
 // and missing-required-field bugs with a clean error the model
 // can retry on, instead of letting the tool fail with a cryptic
 // internal error string.
 switch ToolInputValidator.validate(input: input, against: tool.inputSchema) {
 case .success:
 break
 case .failure(let validationError):
 print("[Validator] rejected tool=\(tool.name) use_id=\(use.id) error=\(validationError.userFacingMessage)")
 let finishedAt = Date()
 let errorBody = "Tool input validation failed: \(validationError.userFacingMessage)\nExpected schema:\n\(tool.inputSchema.json)"
 return CallOutcome(
 result: ToolResultBlock(
 toolUseId: use.id,
 output: errorBody,
 isError: true,
 metadata: nil
 ),
 execution: ToolExecutionRecord(
 toolName: tool.name,
 approved: true,
 startedAt: startedAt,
 finishedAt: finishedAt,
 inputPreview: use.inputJson,
 outputPreview: "Validation failed: \(validationError.userFacingMessage)",
 source: .other
 ),
 approval: normalizer.decisionRecord(
 for: tool,
 outcome: approvalOutcome,
 reason: approvalReason,
 decidedAt: finishedAt
 )
 )
 }

 do {
 let result = try await tool.call(input: input, context: toolContext)
 let finishedAt = Date()
 // boundary layer: per-tool maxResultSizeChars
 // cap. Errors are passed through verbatim so the model sees the
 // original failure text; success outputs over the cap get
 // wrapped in a `<persisted-output>` preview pointing to the
 // full text on disk under MemoryStore.defaultRoot/tool-results.
 let boundedOutput: String
 if result.isError {
 boundedOutput = result.output
 } else {
 boundedOutput = ToolResultPersistor.persistIfOversized(
 toolName: tool.name,
 toolUseId: use.id,
 sessionId: toolContext.session.id,
 output: result.output,
 maxResultSizeChars: tool.maxResultSizeChars
 )
 }
 return CallOutcome(
 result: ToolResultBlock(
 toolUseId: use.id,
 output: boundedOutput,
 isError: result.isError,
 metadata: result.metadata.isEmpty ? nil : result.metadata
 ),
 execution: ToolExecutionRecord(
 toolName: tool.name,
 approved: true,
 startedAt: startedAt,
 finishedAt: finishedAt,
 inputPreview: use.inputJson,
 outputPreview: result.output,
 source: .other
 ),
 approval: normalizer.decisionRecord(
 for: tool,
 outcome: approvalOutcome,
 reason: approvalReason,
 decidedAt: finishedAt
 )
 )
 } catch {
 let finishedAt = Date()
 return CallOutcome(
 result: MessageFactory.syntheticToolError(toolUseId: use.id, error: error),
 execution: ToolExecutionRecord(
 toolName: tool.name,
 approved: true,
 startedAt: startedAt,
 finishedAt: finishedAt,
 inputPreview: use.inputJson,
 outputPreview: "Tool error: \(error.localizedDescription)",
 source: .other
 ),
 approval: normalizer.decisionRecord(
 for: tool,
 outcome: approvalOutcome,
 reason: approvalReason,
 decidedAt: finishedAt
 )
 )
 }
 }

 private static func notFoundOutcome(_ use: ToolUseBlock) -> CallOutcome {
 let now = Date()
 return CallOutcome(
 result: MessageFactory.syntheticToolNotFound(
 toolUseId: use.id,
 toolName: use.name
 ),
 execution: ToolExecutionRecord(
 toolName: use.name,
 approved: false,
 startedAt: now,
 finishedAt: now,
 inputPreview: use.inputJson,
 outputPreview: "tool not found",
 source: .other
 ),
 approval: nil
 )
 }
}
