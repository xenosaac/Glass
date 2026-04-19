import Foundation

internal enum HostToolMode: String, Sendable, Codable, Equatable {
 case disabled
 case allowed
 case required

 internal var forceTools: Bool {
 self == .required
 }
}

internal struct HostExecutionOptions: Sendable, Codable, Equatable {
 internal let completionOptions: CactusModelHost.CompletionOptions
 internal let toolMode: HostToolMode
 internal let emitVisibleTokens: Bool
 internal let allowCloudHandoff: Bool

 internal init(
 completionOptions: CactusModelHost.CompletionOptions,
 toolMode: HostToolMode,
 emitVisibleTokens: Bool,
 allowCloudHandoff: Bool
 ) {
 self.completionOptions = completionOptions
 self.toolMode = toolMode
 self.emitVisibleTokens = emitVisibleTokens
 self.allowCloudHandoff = allowCloudHandoff
 }
}

internal struct TurnExecutionPlan: Sendable, Codable, Equatable {
 internal let maxLoops: Int
 internal let allowCloudFallback: Bool
 internal let allowToolSpecialist: Bool
 internal let profileID: PromptProfileID
 internal let hostOptions: HostExecutionOptions

 internal init(
 maxLoops: Int,
 allowCloudFallback: Bool,
 allowToolSpecialist: Bool,
 profileID: PromptProfileID,
 hostOptions: HostExecutionOptions
 ) {
 self.maxLoops = maxLoops
 self.allowCloudFallback = allowCloudFallback
 self.allowToolSpecialist = allowToolSpecialist
 self.profileID = profileID
 self.hostOptions = hostOptions
 }
}

internal struct ParsedToolCall: Sendable, Codable, Equatable {
 internal let id: String
 internal let name: String
 internal let inputJSON: String

 internal init(id: String, name: String, inputJSON: String) {
 self.id = id
 self.name = name
 self.inputJSON = inputJSON
 }

 internal init(_ block: ToolUseBlock) {
 self.init(id: block.id, name: block.name, inputJSON: block.inputJson)
 }

 internal func asToolUseBlock() -> ToolUseBlock {
 ToolUseBlock(id: id, name: name, inputJson: inputJSON)
 }
}

internal enum FinishReason: String, Sendable, Codable, Equatable {
 case message
 case toolCalls
 case cloudHandoff
 case empty
}

internal struct CompletionSnapshot: Sendable, Codable, Equatable {
 internal let text: String
 internal let toolCalls: [ParsedToolCall]
 internal let confidence: Double
 internal let cloudHandoff: Bool
 internal let prefillTPS: Double
 internal let decodeTPS: Double
 internal let timeToFirstTokenMs: Double
 internal let totalTimeMs: Double
 internal let ramUsageMB: Double

 internal init(
 text: String,
 toolCalls: [ParsedToolCall],
 confidence: Double,
 cloudHandoff: Bool,
 prefillTPS: Double,
 decodeTPS: Double,
 timeToFirstTokenMs: Double,
 totalTimeMs: Double,
 ramUsageMB: Double
 ) {
 self.text = text
 self.toolCalls = toolCalls
 self.confidence = confidence
 self.cloudHandoff = cloudHandoff
 self.prefillTPS = prefillTPS
 self.decodeTPS = decodeTPS
 self.timeToFirstTokenMs = timeToFirstTokenMs
 self.totalTimeMs = totalTimeMs
 self.ramUsageMB = ramUsageMB
 }

 internal init(result: CactusModelHost.CompletionResult) {
 self.init(
 text: result.text,
 toolCalls: result.toolUses.map(ParsedToolCall.init()),
 confidence: result.confidence,
 cloudHandoff: result.cloudHandoff,
 prefillTPS: result.prefillTPS,
 decodeTPS: result.decodeTPS,
 timeToFirstTokenMs: result.timeToFirstTokenMs,
 totalTimeMs: result.totalTimeMs,
 ramUsageMB: result.ramUsageMB
 )
 }

 internal func asCompletionResult() -> CactusModelHost.CompletionResult {
 CactusModelHost.CompletionResult(
 text: text,
 toolUses: toolCalls.map { $0.asToolUseBlock },
 confidence: confidence,
 cloudHandoff: cloudHandoff,
 prefillTPS: prefillTPS,
 decodeTPS: decodeTPS,
 timeToFirstTokenMs: timeToFirstTokenMs,
 totalTimeMs: totalTimeMs,
 ramUsageMB: ramUsageMB
 )
 }
}

internal enum HostStreamEvent: Sendable, Equatable {
 case token(String)
 case finished(CompiledTurnResponse)
}

public struct RetrievedArtifactRef: Sendable, Codable, Equatable {
 public let kind: ContextArtifactKind
 public let sourceDisplayName: String
 public let artifactID: String
 public let position: Int?
 public let totalParts: Int?
 public let tokenEstimate: Int
 public let score: Double

 public init(
 kind: ContextArtifactKind,
 sourceDisplayName: String,
 artifactID: String,
 position: Int?,
 totalParts: Int?,
 tokenEstimate: Int,
 score: Double
 ) {
 self.kind = kind
 self.sourceDisplayName = sourceDisplayName
 self.artifactID = artifactID
 self.position = position
 self.totalParts = totalParts
 self.tokenEstimate = tokenEstimate
 self.score = score
 }
}

public struct RetrievalDecisionSummary: Sendable, Codable, Equatable {
 public let selectedArtifacts: [RetrievedArtifactRef]
 public let injectedArtifactCount: Int

 public init(selectedArtifacts: [RetrievedArtifactRef], injectedArtifactCount: Int) {
 self.selectedArtifacts = selectedArtifacts
 self.injectedArtifactCount = injectedArtifactCount
 }
}

public enum TurnExitSummary: String, Sendable, Codable, Equatable {
 case completed
 case maxTurns
 case modelError
 case noCompletion
 case interrupted
}

public enum RecoveryContinuationReason: String, Sendable, Codable, Equatable {
 case toolFollowup
 case toolSpecialist
 case cloudRetry
 case promptTooLongRetry
 case interruptCleanup
 case completed
 case fatalError
}

public struct RecoveryState: Sendable, Codable, Equatable {
 public var lastExit: TurnExitSummary?
 public var lastErrorMessage: String?
 public var cloudFallbackUsedLastTurn: Bool
 public var consecutiveFailures: Int
 public var lastCompletedAtTurnCount: Int?
 public var lastContinuationReason: RecoveryContinuationReason?
 public var lastWithheldRecoverableError: String?
 public var recoveryAttemptCountLastTurn: Int

 public init(
 lastExit: TurnExitSummary? = nil,
 lastErrorMessage: String? = nil,
 cloudFallbackUsedLastTurn: Bool = false,
 consecutiveFailures: Int = 0,
 lastCompletedAtTurnCount: Int? = nil,
 lastContinuationReason: RecoveryContinuationReason? = nil,
 lastWithheldRecoverableError: String? = nil,
 recoveryAttemptCountLastTurn: Int = 0
 ) {
 self.lastExit = lastExit
 self.lastErrorMessage = lastErrorMessage
 self.cloudFallbackUsedLastTurn = cloudFallbackUsedLastTurn
 self.consecutiveFailures = consecutiveFailures
 self.lastCompletedAtTurnCount = lastCompletedAtTurnCount
 self.lastContinuationReason = lastContinuationReason
 self.lastWithheldRecoverableError = lastWithheldRecoverableError
 self.recoveryAttemptCountLastTurn = recoveryAttemptCountLastTurn
 }

 public static var empty: RecoveryState { RecoveryState }

 public func beganTurn() -> RecoveryState {
 RecoveryState(
 lastExit: lastExit,
 lastErrorMessage: nil,
 cloudFallbackUsedLastTurn: false,
 consecutiveFailures: consecutiveFailures,
 lastCompletedAtTurnCount: lastCompletedAtTurnCount,
 lastContinuationReason: nil,
 lastWithheldRecoverableError: nil,
 recoveryAttemptCountLastTurn: 0
 )
 }

 public func recordingContinuation(
 reason: RecoveryContinuationReason,
 withheldRecoverableError: String? = nil,
 incrementAttemptCount: Bool = false
 ) -> RecoveryState {
 RecoveryState(
 lastExit: lastExit,
 lastErrorMessage: nil,
 cloudFallbackUsedLastTurn: cloudFallbackUsedLastTurn,
 consecutiveFailures: consecutiveFailures,
 lastCompletedAtTurnCount: lastCompletedAtTurnCount,
 lastContinuationReason: reason,
 lastWithheldRecoverableError: withheldRecoverableError ?? lastWithheldRecoverableError,
 recoveryAttemptCountLastTurn: recoveryAttemptCountLastTurn + (incrementAttemptCount ? 1 : 0)
 )
 }

 public func updated(
 exit: TurnExitSummary,
 errorMessage: String?,
 cloudFallbackUsedLastTurn: Bool,
 turnCount: Int,
 lastContinuationReason: RecoveryContinuationReason? = nil
 ) -> RecoveryState {
 let nextConsecutiveFailures: Int
 let nextLastCompletedAtTurnCount: Int?
 switch exit {
 case .completed:
 nextConsecutiveFailures = 0
 nextLastCompletedAtTurnCount = turnCount
 case .interrupted:
 nextConsecutiveFailures = consecutiveFailures
 nextLastCompletedAtTurnCount = lastCompletedAtTurnCount
 case .maxTurns, .modelError, .noCompletion:
 nextConsecutiveFailures = consecutiveFailures + 1
 nextLastCompletedAtTurnCount = lastCompletedAtTurnCount
 }
 return RecoveryState(
 lastExit: exit,
 lastErrorMessage: errorMessage,
 cloudFallbackUsedLastTurn: cloudFallbackUsedLastTurn,
 consecutiveFailures: nextConsecutiveFailures,
 lastCompletedAtTurnCount: nextLastCompletedAtTurnCount,
 lastContinuationReason: lastContinuationReason ?? self.lastContinuationReason ?? (errorMessage == nil ? .completed : .fatalError),
 lastWithheldRecoverableError: lastWithheldRecoverableError,
 recoveryAttemptCountLastTurn: recoveryAttemptCountLastTurn
 )
 }
}

internal struct CompiledTurnDiagnostics: Sendable, Codable, Equatable {
 internal let promptAssembly: PromptAssembly
 internal let turnOverlay: TurnOverlayBundle?
 internal let currentTurnFocus: String?
 internal let latestNonMetaUserText: String?
 internal let turnClassification: TurnClassification?
 internal let retrievalQuery: String?
 internal let retrievalDecision: RetrievalDecisionSummary?

 internal init(
 promptAssembly: PromptAssembly,
 turnOverlay: TurnOverlayBundle?,
 currentTurnFocus: String?,
 latestNonMetaUserText: String?,
 turnClassification: TurnClassification?,
 retrievalQuery: String?,
 retrievalDecision: RetrievalDecisionSummary?
 ) {
 self.promptAssembly = promptAssembly
 self.turnOverlay = turnOverlay
 self.currentTurnFocus = currentTurnFocus
 self.latestNonMetaUserText = latestNonMetaUserText
 self.turnClassification = turnClassification
 self.retrievalQuery = retrievalQuery
 self.retrievalDecision = retrievalDecision
 }
}

internal struct CompiledTurnRequest: Sendable, Codable, Equatable {
 internal let turnID: UUID
 internal let sessionID: String
 internal let profileID: PromptProfileID
 internal let messages: [RelayMessage]
 internal let promptAssembly: PromptAssembly
 internal let toolCatalog: [ToolCatalogEntry]
 internal let hostOptions: HostExecutionOptions
 internal let wasTruncated: Bool
 internal let retrievalPlan: RetrievalDecisionSummary?
 internal let bindingContext: TurnOverlayBundle?
 internal let recoveryPlan: RecoveryState?
 internal let diagnostics: CompiledTurnDiagnostics

 internal init(
 turnID: UUID,
 sessionID: String,
 profileID: PromptProfileID,
 messages: [RelayMessage],
 promptAssembly: PromptAssembly,
 toolCatalog: [ToolCatalogEntry],
 hostOptions: HostExecutionOptions,
 wasTruncated: Bool,
 retrievalPlan: RetrievalDecisionSummary?,
 bindingContext: TurnOverlayBundle?,
 recoveryPlan: RecoveryState?,
 diagnostics: CompiledTurnDiagnostics
 ) {
 self.turnID = turnID
 self.sessionID = sessionID
 self.profileID = profileID
 self.messages = messages
 self.promptAssembly = promptAssembly
 self.toolCatalog = toolCatalog
 self.hostOptions = hostOptions
 self.wasTruncated = wasTruncated
 self.retrievalPlan = retrievalPlan
 self.bindingContext = bindingContext
 self.recoveryPlan = recoveryPlan
 self.diagnostics = diagnostics
 }

 internal func with(
 profileID: PromptProfileID? = nil,
 toolCatalog: [ToolCatalogEntry]? = nil,
 hostOptions: HostExecutionOptions? = nil
 ) -> CompiledTurnRequest {
 CompiledTurnRequest(
 turnID: turnID,
 sessionID: sessionID,
 profileID: profileID ?? self.profileID,
 messages: messages,
 promptAssembly: promptAssembly,
 toolCatalog: toolCatalog ?? self.toolCatalog,
 hostOptions: hostOptions ?? self.hostOptions,
 wasTruncated: wasTruncated,
 retrievalPlan: retrievalPlan,
 bindingContext: bindingContext,
 recoveryPlan: recoveryPlan,
 diagnostics: diagnostics
 )
 }
}

internal struct CompiledTurnResponse: Sendable, Codable, Equatable {
 internal let tier: ModelTier
 internal let outputText: String
 internal let toolCalls: [ParsedToolCall]
 internal let finishReason: FinishReason
 internal let rawCompletion: CompletionSnapshot?

 internal init(
 tier: ModelTier,
 outputText: String,
 toolCalls: [ParsedToolCall],
 finishReason: FinishReason,
 rawCompletion: CompletionSnapshot?
 ) {
 self.tier = tier
 self.outputText = outputText
 self.toolCalls = toolCalls
 self.finishReason = finishReason
 self.rawCompletion = rawCompletion
 }
}

internal protocol ModelHostAdapter: Sendable {
 var profileID: PromptProfileID { get }
 var tier: ModelTier { get }

 func streamTurn(_ request: CompiledTurnRequest) -> AsyncThrowingStream<HostStreamEvent, Error>
}
