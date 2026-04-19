import Foundation

public struct AgentSessionState: Sendable {
 public var messages: [RelayMessage]
 public var turnCount: Int
 public var autoCompactTracking: AutoCompactTrackingState
 public var summaryState: SessionSummaryState
 public var recentToolState: RecentToolState
 public var pendingApprovalState: PendingApprovalState
 public var retrievalState: RetrievalState
 public var recoveryState: RecoveryState

 public init(
 messages: [RelayMessage],
 turnCount: Int,
 autoCompactTracking: AutoCompactTrackingState = .empty,
 summaryState: SessionSummaryState = .empty,
 recentToolState: RecentToolState = .empty,
 pendingApprovalState: PendingApprovalState = .empty,
 retrievalState: RetrievalState = .empty,
 recoveryState: RecoveryState = .empty
 ) {
 self.messages = messages
 self.turnCount = turnCount
 self.autoCompactTracking = autoCompactTracking
 self.summaryState = summaryState
 self.recentToolState = recentToolState
 self.pendingApprovalState = pendingApprovalState
 self.retrievalState = retrievalState
 self.recoveryState = recoveryState
 }

 public static var empty: AgentSessionState {
 AgentSessionState(messages: [], turnCount: 0)
 }

 public static func derivedTurnCount(from messages: [RelayMessage]) -> Int {
 messages.reduce(into: 0) { count, message in
 guard case .user(let content) = message, !content.isMeta else { return }
 count += 1
 }
 }

 public static func hydrated(from repairedHistory: [RelayMessage]) -> AgentSessionState {
 let turnCount = derivedTurnCount(from: repairedHistory)
 return AgentSessionState(
 messages: repairedHistory,
 turnCount: turnCount,
 summaryState: deriveSummaryState(from: repairedHistory, turnCount: turnCount),
 recentToolState: deriveRecentToolState(from: repairedHistory, turnCount: turnCount)
 )
 }

 public static func deriveSummaryState(
 from messages: [RelayMessage],
 turnCount: Int
 ) -> SessionSummaryState {
 _ = turnCount
 for (index, message) in messages.enumerated().reversed() {
 guard case .user(let content) = message, content.isMeta else { continue }
 let joinedText = content.blocks.compactMap { block -> String? in
 if case .text(let text) = block { return text }
 return nil
 }.joined(separator: "\n")

 guard let summary = compactBoundaryBody(from: joinedText) else { continue }
 return SessionSummaryState(
 latestBoundarySummary: summary,
 lastCompactedAtTurnCount: derivedTurnCount(through: index, messages: messages),
 latestBoundaryMessageIndex: index
 )
 }
 return .empty
 }

 public static func deriveRecentToolState(
 from messages: [RelayMessage],
 turnCount: Int
 ) -> RecentToolState {
 _ = turnCount
 guard let toolResultIndex = messages.lastIndex(where: {
 if case .toolResult = $0 { return true }
 return false
 }) else {
 return .empty
 }

 guard case .toolResult(let blocks) = messages[toolResultIndex] else {
 return .empty
 }

 let summaries = blocks.map { block in
 ToolResultSummary(
 toolUseId: block.toolUseId,
 isError: block.isError,
 outputPreview: ToolResultSummary.preview(for: block.output),
 metadata: block.metadata
 )
 }

 return RecentToolState(
 activeToolUses: [],
 lastCompletedBatch: summaries,
 lastCompletedAtTurnCount: derivedTurnCount(through: toolResultIndex, messages: messages)
 )
 }

 public static func retrievalDecisionSummary(from decision: RetrievalDecision) -> RetrievalDecisionSummary? {
 guard !decision.artifacts.isEmpty else { return nil }
 let selectedArtifacts = decision.artifacts.map { selected in
 RetrievedArtifactRef(
 kind: selected.artifact.kind,
 sourceDisplayName: selected.artifact.sourceDisplayName,
 artifactID: selected.artifact.id,
 position: selected.artifact.position,
 totalParts: selected.artifact.totalParts,
 tokenEstimate: selected.artifact.tokenEstimate,
 score: selected.score
 )
 }
 return RetrievalDecisionSummary(
 selectedArtifacts: selectedArtifacts,
 injectedArtifactCount: selectedArtifacts.count
 )
 }

 private static func compactBoundaryBody(from text: String) -> String? {
 guard let open = text.range(of: "<compact-boundary>"),
 let close = text.range(of: "</compact-boundary>", options: .backwards),
 open.upperBound <= close.lowerBound else {
 return nil
 }
 let body = text[open.upperBound..<close.lowerBound]
 .trimmingCharacters(in: .whitespacesAndNewlines)
 return body.isEmpty ? nil : body
 }

 private static func derivedTurnCount(through index: Int, messages: [RelayMessage]) -> Int {
 guard index >= 0 else { return 0 }
 return derivedTurnCount(from: Array(messages.prefix(index + 1)))
 }
}

public struct SessionSummaryState: Sendable, Equatable {
 public var latestBoundarySummary: String?
 public var lastCompactedAtTurnCount: Int?
 public var latestBoundaryMessageIndex: Int?

 public init(
 latestBoundarySummary: String? = nil,
 lastCompactedAtTurnCount: Int? = nil,
 latestBoundaryMessageIndex: Int? = nil
 ) {
 self.latestBoundarySummary = latestBoundarySummary
 self.lastCompactedAtTurnCount = lastCompactedAtTurnCount
 self.latestBoundaryMessageIndex = latestBoundaryMessageIndex
 }

 public static var empty: SessionSummaryState { SessionSummaryState() }
}

public struct RecentToolState: Sendable, Equatable {
 public var activeToolUses: [ToolUseSnapshot]
 public var lastCompletedBatch: [ToolResultSummary]
 public var lastCompletedAtTurnCount: Int?

 public init(
 activeToolUses: [ToolUseSnapshot] = [],
 lastCompletedBatch: [ToolResultSummary] = [],
 lastCompletedAtTurnCount: Int? = nil
 ) {
 self.activeToolUses = activeToolUses
 self.lastCompletedBatch = lastCompletedBatch
 self.lastCompletedAtTurnCount = lastCompletedAtTurnCount
 }

 public static var empty: RecentToolState { RecentToolState() }
}

public struct ToolUseSnapshot: Sendable, Equatable {
 public let id: String
 public let name: String
 public let inputJson: String

 public init(id: String, name: String, inputJson: String) {
 self.id = id
 self.name = name
 self.inputJson = inputJson
 }
}

public struct ToolResultSummary: Sendable, Equatable {
 public let toolUseId: String
 public let isError: Bool
 public let outputPreview: String
 public let metadata: [String: String]?

 public init(
 toolUseId: String,
 isError: Bool,
 outputPreview: String,
 metadata: [String: String]? = nil
 ) {
 self.toolUseId = toolUseId
 self.isError = isError
 self.outputPreview = outputPreview
 self.metadata = metadata
 }

 public static func preview(for output: String, limit: Int = 200) -> String {
 guard output.count > limit else { return output }
 let end = output.index(output.startIndex, offsetBy: limit)
 return String(output[..<end]) + "..."
 }
}

public struct PendingApprovalState: Sendable, Equatable {
 public var current: PendingApprovalRequest?
 public var lastResolution: ApprovalResolution?

 public init(
 current: PendingApprovalRequest? = nil,
 lastResolution: ApprovalResolution? = nil
 ) {
 self.current = current
 self.lastResolution = lastResolution
 }

 public static var empty: PendingApprovalState { PendingApprovalState() }
}

public struct PendingApprovalRequest: Sendable, Equatable {
 public let toolUseId: String
 public let toolName: String
 public let prompt: String
 public let requestedAtTurnCount: Int

 public init(toolUseId: String, toolName: String, prompt: String, requestedAtTurnCount: Int) {
 self.toolUseId = toolUseId
 self.toolName = toolName
 self.prompt = prompt
 self.requestedAtTurnCount = requestedAtTurnCount
 }
}

public struct ApprovalResolution: Sendable, Equatable {
 public let toolUseId: String
 public let toolName: String
 public let prompt: String
 public let approved: Bool
 public let resolvedAtTurnCount: Int

 public init(
 toolUseId: String,
 toolName: String,
 prompt: String,
 approved: Bool,
 resolvedAtTurnCount: Int
 ) {
 self.toolUseId = toolUseId
 self.toolName = toolName
 self.prompt = prompt
 self.approved = approved
 self.resolvedAtTurnCount = resolvedAtTurnCount
 }
}

public struct RetrievalState: Sendable, Equatable {
 public var lastQuery: String?
 public var lastDecision: RetrievalDecisionSummary?
 public var lastPlannedAtTurnCount: Int?

 public init(
 lastQuery: String? = nil,
 lastDecision: RetrievalDecisionSummary? = nil,
 lastPlannedAtTurnCount: Int? = nil
 ) {
 self.lastQuery = lastQuery
 self.lastDecision = lastDecision
 self.lastPlannedAtTurnCount = lastPlannedAtTurnCount
 }

 public static var empty: RetrievalState { RetrievalState() }

 public static func planned(
 query: String?,
 decision: RetrievalDecision,
 turnCount: Int
 ) -> RetrievalState {
 guard let query, !query.isEmpty else { return .empty }
 return RetrievalState(
 lastQuery: query,
 lastDecision: AgentSessionState.retrievalDecisionSummary(from: decision),
 lastPlannedAtTurnCount: turnCount
 )
 }
}

// Glass 2.0 Module B moved the canonical retrieval/recovery summary
// contracts into `Contracts/HostContracts.swift`. `AgentSessionState`
// remains the consumer of those shared types.
