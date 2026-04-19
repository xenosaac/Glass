import Foundation

internal enum TurnFailureKind: String, Sendable, Codable, Equatable {
 case modelError
 case noCompletion
 case maxTurns
 case interrupted
}

internal enum TurnRecoveryEventDiagnostic: String, Sendable, Codable, Equatable {
 case retryingWithCloud
 case compactingContext
 case retryingAfterContextReduction
 case cleaningUpInterruptedTurn
 case clearProvisionalOutput
}

internal struct AttemptCompletionSnapshot: Sendable, Codable {
 internal let text: String
 internal let toolUses: [ToolUseBlock]
 internal let cloudHandoff: Bool

 internal init(
 text: String,
 toolUses: [ToolUseBlock],
 cloudHandoff: Bool
 ) {
 self.text = text
 self.toolUses = toolUses
 self.cloudHandoff = cloudHandoff
 }

 internal init(result: CactusModelHost.CompletionResult) {
 self.init(
 text: result.text,
 toolUses: result.toolUses,
 cloudHandoff: result.cloudHandoff
 )
 }

 internal init(snapshot: CompletionSnapshot) {
 self.init(
 text: snapshot.text,
 toolUses: snapshot.toolCalls.map { $0.asToolUseBlock() },
 cloudHandoff: snapshot.cloudHandoff
 )
 }

 internal func asCompletionResult() -> CactusModelHost.CompletionResult {
 CactusModelHost.CompletionResult(
 text: text,
 toolUses: toolUses,
 confidence: 1.0,
 cloudHandoff: cloudHandoff,
 prefillTPS: 0,
 decodeTPS: 0,
 timeToFirstTokenMs: 0,
 totalTimeMs: 0,
 ramUsageMB: 0
 )
 }
}

internal struct TurnAttemptDiagnostics: Sendable, Codable {
 internal let attemptIndex: Int
 internal let modelTier: ModelTier
 internal let requestMessages: [RelayMessage]
 internal let systemPrompt: String
 internal let promptDiagnostics: PromptCompositionDiagnostics
 internal let currentTurnFocus: String?
 internal let retrievalDecision: RetrievalDecisionSummary?
 internal let wasTruncated: Bool
 internal let emittedRecoveryEvents: [TurnRecoveryEventDiagnostic]
 internal let completionSnapshot: AttemptCompletionSnapshot?
 internal let errorSummary: String?
 internal let compiledRequest: CompiledTurnRequest?
 internal let compiledResponse: CompiledTurnResponse?

 internal init(
 attemptIndex: Int,
 modelTier: ModelTier,
 requestMessages: [RelayMessage],
 systemPrompt: String,
 promptDiagnostics: PromptCompositionDiagnostics,
 currentTurnFocus: String?,
 retrievalDecision: RetrievalDecisionSummary?,
 wasTruncated: Bool,
 emittedRecoveryEvents: [TurnRecoveryEventDiagnostic] = [],
 completionSnapshot: AttemptCompletionSnapshot? = nil,
 errorSummary: String? = nil,
 compiledRequest: CompiledTurnRequest? = nil,
 compiledResponse: CompiledTurnResponse? = nil
 ) {
 self.attemptIndex = attemptIndex
 self.modelTier = modelTier
 self.requestMessages = requestMessages
 self.systemPrompt = systemPrompt
 self.promptDiagnostics = promptDiagnostics
 self.currentTurnFocus = currentTurnFocus
 self.retrievalDecision = retrievalDecision
 self.wasTruncated = wasTruncated
 self.emittedRecoveryEvents = emittedRecoveryEvents
 self.completionSnapshot = completionSnapshot
 self.errorSummary = errorSummary
 self.compiledRequest = compiledRequest
 self.compiledResponse = compiledResponse
 }
}

internal struct TurnRunArtifacts: Sendable, Codable {
 internal let turnID: UUID
 internal let exit: TurnExitSummary
 internal let recoveryState: RecoveryState
 internal let attempts: [TurnAttemptDiagnostics]
 internal let acceptedUserMessage: RelayMessage
 internal let finalAssistantMessage: RelayMessage?
 internal let toolExecutions: [ToolExecutionRecord]?
 internal let approvalDecisions: [ApprovalDecisionRecord]?

 internal init(
 turnID: UUID,
 exit: TurnExitSummary,
 recoveryState: RecoveryState,
 attempts: [TurnAttemptDiagnostics],
 acceptedUserMessage: RelayMessage,
 finalAssistantMessage: RelayMessage?,
 toolExecutions: [ToolExecutionRecord]? = nil,
 approvalDecisions: [ApprovalDecisionRecord]? = nil
 ) {
 self.turnID = turnID
 self.exit = exit
 self.recoveryState = recoveryState
 self.attempts = attempts
 self.acceptedUserMessage = acceptedUserMessage
 self.finalAssistantMessage = finalAssistantMessage
 self.toolExecutions = toolExecutions
 self.approvalDecisions = approvalDecisions
 }
}

internal enum TurnCommitStage: String, Sendable, Codable, Equatable {
 case acceptedUserTranscriptAppended
 case acceptedUserIndexed
 case completedAssistantTranscriptAppended
 case completedAssistantIndexed
 case completedMemoryWriteback
 case failureSidecarWritten
}

internal struct TurnCommitStageEntry: Sendable, Codable, Equatable {
 internal let stage: TurnCommitStage
 internal let recordedAt: Date
 internal let succeeded: Bool
 internal let detail: String?

 internal init(
 stage: TurnCommitStage,
 recordedAt: Date = Date(),
 succeeded: Bool,
 detail: String? = nil
 ) {
 self.stage = stage
 self.recordedAt = recordedAt
 self.succeeded = succeeded
 self.detail = detail
 }
}

internal struct TurnCommitTrace: Sendable, Codable, Equatable {
 internal var entries: [TurnCommitStageEntry]

 internal init(entries: [TurnCommitStageEntry] = []) {
 self.entries = entries
 }

 internal mutating func append(
 stage: TurnCommitStage,
 succeeded: Bool,
 detail: String? = nil,
 recordedAt: Date = Date()
 ) {
 entries.append(
 TurnCommitStageEntry(
 stage: stage,
 recordedAt: recordedAt,
 succeeded: succeeded,
 detail: detail
 )
 )
 }

 internal func didSucceed(_ stage: TurnCommitStage) -> Bool {
 entries.last(where: { $0.stage == stage })?.succeeded == true
 }
}

internal extension AgentRunner.TurnExit {
 var summary: TurnExitSummary {
 switch self {
 case .completed:
 return .completed
 case .maxTurns:
 return .maxTurns
 case .modelError:
 return .modelError
 case .noCompletion:
 return .noCompletion
 case .interrupted:
 return .interrupted
 }
 }
}

internal extension TurnExitSummary {
 func asTurnExit(errorMessage: String?) -> AgentRunner.TurnExit {
 switch self {
 case .completed:
 return .completed
 case .maxTurns:
 return .maxTurns
 case .modelError:
 return .modelError(errorMessage ?? "Unknown model error")
 case .noCompletion:
 return .noCompletion
 case .interrupted:
 return .interrupted
 }
 }

 var failureKind: TurnFailureKind? {
 switch self {
 case .completed:
 return nil
 case .maxTurns:
 return .maxTurns
 case .modelError:
 return .modelError
 case .noCompletion:
 return .noCompletion
 case .interrupted:
 return .interrupted
 }
 }
}
