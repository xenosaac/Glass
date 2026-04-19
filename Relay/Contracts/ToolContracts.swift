import Foundation

/// Canonical tool + approval contracts for Glass 2.0 Module C.
/// See `docs/architecture/glass-2-interface-consistency-execution-plan.md`.
///
/// `RelayTool` stays canonical at the tool-definition layer (in `RelayTool.swift`).
/// Everything around tool selection, catalog projection, execution, and approval
/// flows through the typed records defined here.

// MARK: - Tool source

/// Origin of a tool. Tags catalog entries and execution records so that
/// downstream diagnostics / storage can attribute a tool back to its provider.
public enum ToolSource: Codable, Sendable, Equatable {
 case builtin
 case files
 case appIntents
 case gmail
 case mcp(server: String)
 case other
}

// MARK: - Catalog

/// Published view of one tool available to the model for this turn.
///
/// Produced by `ToolRegistry.catalog(for:)`. The `policy` field here is the
/// advertised default; per-call policy is still recomputed by the broker via
/// `tool.policyDescriptor(input:context:)` at execution time.
public struct ToolCatalogEntry: Sendable, Codable, Equatable {
 public let name: String
 public let title: String
 public let source: ToolSource
 public let inputSchema: String
 public let policy: ToolPolicyDescriptor

 public init(
 name: String,
 title: String,
 source: ToolSource,
 inputSchema: String,
 policy: ToolPolicyDescriptor
 ) {
 self.name = name
 self.title = title
 self.source = source
 self.inputSchema = inputSchema
 self.policy = policy
 }
}

// MARK: - Execution plan

/// Intended invocation of a single tool on this turn. Not persisted today;
/// used by the dispatcher to thread a typed plan through `callTool`.
public struct ToolExecutionPlan: Sendable, Codable, Equatable {
 public let toolName: String
 public let input: ToolInput
 public let requiresApproval: Bool
 public let policy: ToolPolicyDescriptor

 public init(
 toolName: String,
 input: ToolInput,
 requiresApproval: Bool,
 policy: ToolPolicyDescriptor
 ) {
 self.toolName = toolName
 self.input = input
 self.requiresApproval = requiresApproval
 self.policy = policy
 }
}

// MARK: - Execution record

/// Post-hoc record of one tool execution attempt. Produced by the dispatcher
/// for every tool use, including error and not-found paths.
///
/// `inputPreview` and `outputPreview` are truncated to `ToolExecutionRecord.previewLimit`
/// characters so the record stays small enough for transcript storage.
public struct ToolExecutionRecord: Codable, Sendable, Equatable {
 public static let previewLimit: Int = 256

 public let toolName: String
 public let approved: Bool
 public let startedAt: Date
 public let finishedAt: Date
 public let inputPreview: String
 public let outputPreview: String
 public let source: ToolSource

 public init(
 toolName: String,
 approved: Bool,
 startedAt: Date,
 finishedAt: Date,
 inputPreview: String,
 outputPreview: String,
 source: ToolSource
 ) {
 self.toolName = toolName
 self.approved = approved
 self.startedAt = startedAt
 self.finishedAt = finishedAt
 self.inputPreview = Self.truncate(inputPreview)
 self.outputPreview = Self.truncate(outputPreview)
 self.source = source
 }

 public static func truncate(_ s: String, limit: Int = previewLimit) -> String {
 guard s.count > limit else { return s }
 return String(s.prefix(limit))
 }
}

// MARK: - Approval

/// Category of approval required when a tool action needs user confirmation.
/// Rehomed from `ApprovalBroker.swift` on per Glass 2.0 Module C;
/// the canonical home is now `Contracts/ToolContracts.swift`. See worklog.
public enum ApprovalCategory: String, Codable, Sendable, Equatable {
 case workspaceWrite
 case externalSend
 case destructiveDelete
 case mcpMutation
}

/// Outcome of one broker evaluation. All five cases map 1:1 to the branches
/// of `ToolDispatcher.callTool`. Tool-not-found is the single exception where
/// no broker evaluation happens and no approval record is produced.
public enum ApprovalOutcome: String, Codable, Sendable, Equatable, CaseIterable {
 case autoAllowed
 case brokerDenied
 case userApproved
 case userDenied
 case deferredNoHandler
}

/// Post-hoc record of one broker decision. Produced for every broker
/// evaluation so downstream diagnostics/replay see a symmetric surface.
public struct ApprovalDecisionRecord: Codable, Sendable, Equatable {
 public let toolName: String
 public let outcome: ApprovalOutcome
 public let reason: String?
 public let decidedAt: Date

 public init(
 toolName: String,
 outcome: ApprovalOutcome,
 reason: String?,
 decidedAt: Date
 ) {
 self.toolName = toolName
 self.outcome = outcome
 self.reason = reason
 self.decidedAt = decidedAt
 }
}

// MARK: - Dispatcher return shape

/// Result of one `ToolDispatcher.execute(...)` call.
///
/// `results` preserves the legacy return shape used by `AgentRunner`.
/// `executions` and `approvals` are the canonical typed records; they are
/// intentionally unused in the runtime path today — Module B / D wire them
/// into `TurnRunArtifacts` and storage headers.
public struct ToolDispatchBatch: Sendable, Codable, Equatable {
 public let results: [ToolResultBlock]
 public let executions: [ToolExecutionRecord]
 public let approvals: [ApprovalDecisionRecord]

 public init(
 results: [ToolResultBlock],
 executions: [ToolExecutionRecord],
 approvals: [ApprovalDecisionRecord]
 ) {
 self.results = results
 self.executions = executions
 self.approvals = approvals
 }
}
