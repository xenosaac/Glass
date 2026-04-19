import Foundation

/// Protocol that every callable tool implements.
///
/// Built-in tools, MCP tools, AppIntent-wrapped tools and skill-provided tools all
/// conform to `RelayTool`. The agent loop only knows about this protocol —
/// it never depends on a specific tool implementation.
///
/// Conformances live in module-specific Swift files .
public protocol RelayTool: Sendable {
 /// Unique tool identifier shown to the model in the tool list.
 var name: String { get }

 /// Short human/model-readable description (shown to the model).
 var description: String { get }

 /// JSON Schema describing the input parameters.
 var inputSchema: ToolInputSchema { get }

 /// `true` if this tool can run concurrently with other safe tools in a turn.
 var isConcurrencySafe: Bool { get }

 /// `true` if this tool performs no writes / side effects.
 var isReadOnly: Bool { get }

 /// `true` if this tool performs irreversible / destructive actions.
 /// High-stakes actions trigger Watch confirmation in .
 var isDestructive: Bool { get }

 /// per-tool cap on result size BEFORE the
 /// `ToolResultPersistor` overflow path kicks in. implements a
 /// `Tool.maxResultSizeChars` (`Tool.ts`); default 50_000 matches CC's
 /// `DEFAULT_MAX_RESULT_SIZE_CHARS` at `utils/toolLimits.ts:13`.
 /// Override per tool when output is structurally bounded (e.g. a
 /// calendar listing rendering 8 bullets ≈ 2 KB).
 var maxResultSizeChars: Int { get }

 /// Execute the tool with the given input and context.
 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult

 /// Declarative policy facts used by the host-owned approval broker.
 func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor
}

public extension RelayTool {
 /// CC-aligned default — 50_000 chars before overflow → persisted-output
 /// preview wrapper. Tools with structurally bounded output should
 /// override this to a tighter cap (calendar/reminders ≈ 2_000;
 /// grep/glob ≈ 5_000; MCP wrapper ≈ 10_000).
 var maxResultSizeChars: Int { 50_000 }
}

// MARK: - Supporting types

/// Type-erased tool input. Holds the raw JSON arguments from the model.
public struct ToolInput: Sendable, Codable, Equatable {
 public let json: Data
 public init(json: Data) { self.json = json }
}

/// Tool input schema fragment (raw JSON Schema string).
public struct ToolInputSchema: Sendable, Codable, Equatable {
 public let json: String
 public init(json: String) { self.json = json }
}

/// Result of a tool execution, fed back into the conversation history.
public struct ToolResult: Sendable, Codable, Equatable {
 public let toolUseId: String
 public let output: String
 public let isError: Bool
 public let metadata: [String: String]

 public init(
 toolUseId: String,
 output: String,
 isError: Bool = false,
 metadata: [String: String] = [:]
 ) {
 self.toolUseId = toolUseId
 self.output = output
 self.isError = isError
 self.metadata = metadata
 }
}

public enum ToolPolicyDomain: Sendable, Codable, Equatable {
 case filesystem
 case memory
 case gmail
 case calendar
 case reminders
 case messagesCompose
 case mailCompose
 case mcp(server: String)
 case builtin
 case web
 case other
}

public enum ToolPolicyOperation: String, Sendable, Codable, Equatable {
 case read
 case search
 case write
 case create
 case update
 case delete
 case send
 case compose
 case execute
}

public enum ToolPolicyRisk: String, Sendable, Codable, Equatable {
 case readOnly
 case reversible
 case destructive
 case userMediated
 case unknown
}

public struct ToolPolicyDescriptor: Sendable, Codable, Equatable {
 public let domain: ToolPolicyDomain
 public let operation: ToolPolicyOperation
 public let risk: ToolPolicyRisk
 public let summary: String
 public let targetDescription: String?

 public init(
 domain: ToolPolicyDomain,
 operation: ToolPolicyOperation,
 risk: ToolPolicyRisk,
 summary: String,
 targetDescription: String? = nil
 ) {
 self.domain = domain
 self.operation = operation
 self.risk = risk
 self.summary = summary
 self.targetDescription = targetDescription
 }
}

public struct NormalizedToolPolicy: Sendable, Codable, Equatable {
 public let toolName: String
 public let domain: ToolPolicyDomain
 public let operation: ToolPolicyOperation
 public let risk: ToolPolicyRisk
 public let summary: String
 public let targetDescription: String?
 public let approvalCategory: ApprovalCategory?

 public init(
 toolName: String,
 domain: ToolPolicyDomain,
 operation: ToolPolicyOperation,
 risk: ToolPolicyRisk,
 summary: String,
 targetDescription: String?,
 approvalCategory: ApprovalCategory?
 ) {
 self.toolName = toolName
 self.domain = domain
 self.operation = operation
 self.risk = risk
 self.summary = summary
 self.targetDescription = targetDescription
 self.approvalCategory = approvalCategory
 }
}

public extension ToolPolicyDescriptor {
 static func readOnly(
 domain: ToolPolicyDomain,
 operation: ToolPolicyOperation,
 summary: String,
 targetDescription: String? = nil
 ) -> ToolPolicyDescriptor {
 ToolPolicyDescriptor(
 domain: domain,
 operation: operation,
 risk: .readOnly,
 summary: summary,
 targetDescription: targetDescription
 )
 }

 static func reversible(
 domain: ToolPolicyDomain,
 operation: ToolPolicyOperation,
 summary: String,
 targetDescription: String? = nil
 ) -> ToolPolicyDescriptor {
 ToolPolicyDescriptor(
 domain: domain,
 operation: operation,
 risk: .reversible,
 summary: summary,
 targetDescription: targetDescription
 )
 }

 static func destructive(
 domain: ToolPolicyDomain,
 operation: ToolPolicyOperation,
 summary: String,
 targetDescription: String? = nil
 ) -> ToolPolicyDescriptor {
 ToolPolicyDescriptor(
 domain: domain,
 operation: operation,
 risk: .destructive,
 summary: summary,
 targetDescription: targetDescription
 )
 }

 static func userMediated(
 domain: ToolPolicyDomain,
 operation: ToolPolicyOperation,
 summary: String,
 targetDescription: String? = nil
 ) -> ToolPolicyDescriptor {
 ToolPolicyDescriptor(
 domain: domain,
 operation: operation,
 risk: .userMediated,
 summary: summary,
 targetDescription: targetDescription
 )
 }
}

public extension RelayTool {
 func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 let risk: ToolPolicyRisk
 if isReadOnly {
 risk = .readOnly
 } else if isDestructive {
 risk = .destructive
 } else {
 risk = .unknown
 }
 return ToolPolicyDescriptor(
 domain: .other,
 operation: isReadOnly ? .read : .execute,
 risk: risk,
 summary: description
 )
 }
}

// MARK: - Module C canonical catalog projection

public extension RelayTool {
 /// Project this tool into its canonical `ToolCatalogEntry`. The `source`
 /// comes from the owning provider (`ToolProvider.source`); `ToolRegistry`
 /// threads it through when building the catalog. Broker still recomputes
 /// per-call policy via `policyDescriptor(input:context:)` at execution time.
 func catalogEntry(source: ToolSource) -> ToolCatalogEntry {
 let neutralPolicy: ToolPolicyDescriptor
 if isReadOnly {
 neutralPolicy = .readOnly(
 domain: .other,
 operation: .read,
 summary: description
 )
 } else if isDestructive {
 neutralPolicy = .destructive(
 domain: .other,
 operation: .execute,
 summary: description
 )
 } else {
 neutralPolicy = ToolPolicyDescriptor(
 domain: .other,
 operation: .execute,
 risk: .unknown,
 summary: description
 )
 }
 return ToolCatalogEntry(
 name: name,
 title: description,
 source: source,
 inputSchema: inputSchema.json,
 policy: neutralPolicy
 )
 }
}
