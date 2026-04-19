import Foundation

// NOTE: `ApprovalCategory` was rehomed to `Contracts/ToolContracts.swift` as
// part of Glass 2.0 Module C on The type name is unchanged and
// remains visible across the module, so callers need no edits. Swift does not
// permit a self-referencing `typealias ApprovalCategory = ApprovalCategory`
// within a single module; the rehome is recorded in `worklog.md` instead.

public protocol ApprovalBroker: Sendable {
 func evaluate(
 tool: any RelayTool,
 input: ToolInput,
 context: ToolCallContext
 ) async -> ApprovalDecision
}

public enum ApprovalDecision: Sendable, Equatable {
 case allow
 case deny(reason: String)
 case confirm(ApprovalRequest)
}

public struct ApprovalRequest: Sendable, Equatable {
 public let prompt: String
 public let category: ApprovalCategory
 public let policy: NormalizedToolPolicy

 public init(prompt: String, category: ApprovalCategory, policy: NormalizedToolPolicy) {
 self.prompt = prompt
 self.category = category
 self.policy = policy
 }
}

public struct ToolPolicyNormalizer: Sendable {
 public init() {}

 /// Build the canonical approval decision record for one broker evaluation.
 /// The dispatcher calls this once per tool use that reaches the broker,
 /// populating `outcome` with the realized branch of `ApprovalDecision`.
 public func decisionRecord(
 for tool: any RelayTool,
 outcome: ApprovalOutcome,
 reason: String?,
 decidedAt: Date = Date()
 ) -> ApprovalDecisionRecord {
 ApprovalDecisionRecord(
 toolName: tool.name,
 outcome: outcome,
 reason: reason,
 decidedAt: decidedAt
 )
 }

 public func normalize(
 tool: any RelayTool,
 descriptor: ToolPolicyDescriptor
 ) -> NormalizedToolPolicy {
 let approvalCategory: ApprovalCategory?
 switch (descriptor.domain, descriptor.operation, descriptor.risk) {
 case (.filesystem, .write, _):
 approvalCategory = .workspaceWrite
 case (.gmail, .send, _):
 approvalCategory = .externalSend
 case (.calendar, .delete, _):
 approvalCategory = .destructiveDelete
 case (.mcp(server: _), _, .readOnly):
 approvalCategory = nil
 case (.mcp(server: _), _, _):
 approvalCategory = .mcpMutation
 default:
 approvalCategory = nil
 }

 return NormalizedToolPolicy(
 toolName: tool.name,
 domain: descriptor.domain,
 operation: descriptor.operation,
 risk: descriptor.risk,
 summary: descriptor.summary,
 targetDescription: descriptor.targetDescription,
 approvalCategory: approvalCategory
 )
 }
}

public struct DefaultApprovalBroker: ApprovalBroker, Sendable {
 private let normalizer: ToolPolicyNormalizer

 public init(normalizer: ToolPolicyNormalizer = ToolPolicyNormalizer) {
 self.normalizer = normalizer
 }

 public func evaluate(
 tool: any RelayTool,
 input: ToolInput,
 context: ToolCallContext
 ) async -> ApprovalDecision {
 let descriptor = await tool.policyDescriptor(input: input, context: context)
 let policy = normalizer.normalize(tool: tool, descriptor: descriptor)

 switch (policy.domain, policy.operation, policy.risk, policy.approvalCategory) {
 case (_, _, .readOnly, _):
 return .allow
 case (_, _, .userMediated, _):
 return .allow
 case (.memory, .write, _, _):
 return .allow
 case (.filesystem, .write, _, .workspaceWrite):
 return .confirm(ApprovalRequest(
 prompt: "Allow writing to '\(policy.targetDescription ?? policy.summary)'?",
 category: .workspaceWrite,
 policy: policy
 ))
 case (.gmail, .send, _, .externalSend):
 return .confirm(ApprovalRequest(
 prompt: "Send email to \(policy.targetDescription ?? "the recipient")? This cannot be recalled after sending.",
 category: .externalSend,
 policy: policy
 ))
 case (.calendar, .delete, _, .destructiveDelete):
 return .confirm(ApprovalRequest(
 prompt: "Delete \(policy.targetDescription ?? "the selected item")? This cannot be undone.",
 category: .destructiveDelete,
 policy: policy
 ))
 case (.mcp(server: _), _, _, .mcpMutation):
 let detail = policy.summary.trimmingCharacters(in: .whitespacesAndNewlines)
 let prompt = detail.isEmpty
 ? "Allow MCP tool '\(policy.toolName)' to modify external state?"
 : "Allow MCP tool '\(policy.toolName)' to modify external state? \(detail)"
 return .confirm(ApprovalRequest(
 prompt: prompt,
 category: .mcpMutation,
 policy: policy
 ))
 case (.calendar, .create, .reversible, _),
 (.reminders, .create, .reversible, _),
 (.reminders, .update, .reversible, _),
 (.gmail, .create, .reversible, _):
 return .allow
 default:
 return .deny(reason: "Unsupported tool policy for \(policy.toolName).")
 }
 }
}
