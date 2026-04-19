import XCTest
@testable import Relay

final class ApprovalBrokerTests: XCTestCase {
 private struct StubTool: RelayTool {
 let name: String
 let description: String
 let descriptor: ToolPolicyDescriptor

 var inputSchema: ToolInputSchema { ToolInputSchema(json: #"{"type":"object","properties":{}}"#) }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { descriptor.risk == .readOnly }
 var isDestructive: Bool { descriptor.risk == .destructive }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 ToolResult(toolUseId: "", output: "unused")
 }

 func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 descriptor
 }
 }

 private let broker = DefaultApprovalBroker

 private func context() -> ToolCallContext {
 ToolCallContext(
 messages: [],
 session: AgentSession(id: "approval", startedAt: Date),
 approvalBroker: broker,
 progress: { _ in },
 services: DefaultServiceLocator
 )
 }

 func test_broker_confirmsGmailSendAsExternalSend() async {
 let tool = GmailSendTool
 let input = ToolInput(json: Data(#"{"to":"alice@example.com","subject":"Hi","body":"Hello"}"#.utf8))

 let decision = await broker.evaluate(tool: tool, input: input, context: context)

 guard case .confirm(let request) = decision else {
 return XCTFail("Expected confirm, got \(decision)")
 }
 XCTAssertEqual(request.category, .externalSend)
 XCTAssertEqual(request.prompt, "Send email to alice@example.com? This cannot be recalled after sending.")
 }

 func test_broker_confirmsFileWriteAsWorkspaceWrite() async {
 let tool = FileWriteTool
 let input = ToolInput(json: Data(#"{"path":"/tmp/demo.txt","content":"hello"}"#.utf8))

 let decision = await broker.evaluate(tool: tool, input: input, context: context)

 guard case .confirm(let request) = decision else {
 return XCTFail("Expected confirm, got \(decision)")
 }
 XCTAssertEqual(request.category, .workspaceWrite)
 XCTAssertEqual(request.prompt, "Allow writing to '/tmp/demo.txt'?")
 }

 func test_broker_confirmsCalendarDeleteAsDestructiveDelete() async {
 let tool = CalendarDeleteEventTool
 let input = ToolInput(json: Data(#"{"event_id":"abc123"}"#.utf8))

 let decision = await broker.evaluate(tool: tool, input: input, context: context)

 guard case .confirm(let request) = decision else {
 return XCTFail("Expected confirm, got \(decision)")
 }
 XCTAssertEqual(request.category, .destructiveDelete)
 XCTAssertEqual(request.prompt, "Delete calendar event abc123? This cannot be undone.")
 }

 func test_broker_allowsUserMediatedComposeTools() async {
 let emailDraft = EmailDraftTool
 let smsSend = SMSSendTool
 let emailInput = ToolInput(json: Data(#"{"to":["a@example.com"],"subject":"Hi","body":"Hello"}"#.utf8))
 let smsInput = ToolInput(json: Data(#"{"to":["123"],"body":"Hello"}"#.utf8))

 let emailDecision = await broker.evaluate(tool: emailDraft, input: emailInput, context: context)
 let smsDecision = await broker.evaluate(tool: smsSend, input: smsInput, context: context)

 XCTAssertEqual(emailDecision, .allow)
 XCTAssertEqual(smsDecision, .allow)
 }

 func test_broker_allowsMemoryWrite() async {
 let tool = MemoryWriteTool
 let input = ToolInput(json: Data(#"{"path":"user_name.md","content":"hello"}"#.utf8))

 let decision = await broker.evaluate(tool: tool, input: input, context: context)
 XCTAssertEqual(decision, .allow)
 }

 func test_broker_allowsReadOnlyMCPAndConfirmsMutation() async {
 let readTool = MCPToolWrapper(
 serverName: "demo",
 definition: MCPToolDefinition(
 name: "list_items",
 description: "List items",
 inputSchema: MCPInputSchema,
 annotations: MCPToolAnnotations(
 readOnlyHint: true,
 destructiveHint: nil,
 idempotentHint: nil,
 longRunningHint: nil,
 sideEffectDescription: nil
 )
 ),
 client: MCPClient(config: MCPServerConfig(name: "demo", baseURL: URL(string: "https://example.com")!))
 )
 let mutatingTool = MCPToolWrapper(
 serverName: "demo",
 definition: MCPToolDefinition(
 name: "delete_item",
 description: "Delete item",
 inputSchema: MCPInputSchema,
 annotations: MCPToolAnnotations(
 readOnlyHint: nil,
 destructiveHint: true,
 idempotentHint: nil,
 longRunningHint: nil,
 sideEffectDescription: "Deletes a remote resource."
 )
 ),
 client: MCPClient(config: MCPServerConfig(name: "demo", baseURL: URL(string: "https://example.com")!))
 )

 let readDecision = await broker.evaluate(tool: readTool, input: ToolInput(json: Data), context: context)
 let mutatingDecision = await broker.evaluate(tool: mutatingTool, input: ToolInput(json: Data), context: context)

 XCTAssertEqual(readDecision, .allow)
 guard case .confirm(let request) = mutatingDecision else {
 return XCTFail("Expected confirm, got \(mutatingDecision)")
 }
 XCTAssertEqual(request.category, .mcpMutation)
 XCTAssertEqual(request.prompt, "Allow MCP tool 'mcp_demo_delete_item' to modify external state? Deletes a remote resource.")
 }

 func test_broker_confirmsUncertainMCPPolicyConservatively() async {
 let tool = MCPToolWrapper(
 serverName: "demo",
 definition: MCPToolDefinition(
 name: "run_workflow",
 description: "Execute workflow",
 inputSchema: MCPInputSchema,
 annotations: nil
 ),
 client: MCPClient(config: MCPServerConfig(name: "demo", baseURL: URL(string: "https://example.com")!))
 )

 let decision = await broker.evaluate(tool: tool, input: ToolInput(json: Data), context: context)

 guard case .confirm(let request) = decision else {
 return XCTFail("Expected confirm, got \(decision)")
 }
 XCTAssertEqual(request.category, .mcpMutation)
 }

 func test_broker_deniesUnsupportedPolicyShape() async {
 let tool = StubTool(
 name: "weird_delete",
 description: "Unsupported delete",
 descriptor: ToolPolicyDescriptor(
 domain: .other,
 operation: .delete,
 risk: .unknown,
 summary: "Unsupported shape."
 )
 )

 let decision = await broker.evaluate(tool: tool, input: ToolInput(json: Data), context: context)

 guard case .deny(let reason) = decision else {
 return XCTFail("Expected deny, got \(decision)")
 }
 XCTAssertEqual(reason, "Unsupported tool policy for weird_delete.")
 }

 // MARK: - Glass 2.0 Module C — decisionRecord helper

 func test_normalizer_decisionRecord_emitsShapePerOutcome() {
 let normalizer = ToolPolicyNormalizer
 let tool = StubTool(
 name: "probe_tool",
 description: "Probe",
 descriptor: ToolPolicyDescriptor(
 domain: .other,
 operation: .read,
 risk: .readOnly,
 summary: "probe"
 )
 )
 let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

 for outcome in ApprovalOutcome.allCases {
 let reason: String? = (outcome == .brokerDenied || outcome == .userDenied || outcome == .deferredNoHandler)
 ? "demo reason"
 : nil

 let record = normalizer.decisionRecord(
 for: tool,
 outcome: outcome,
 reason: reason,
 decidedAt: fixedDate
 )

 XCTAssertEqual(record.toolName, "probe_tool", "outcome=\(outcome.rawValue)")
 XCTAssertEqual(record.outcome, outcome)
 XCTAssertEqual(record.reason, reason, "outcome=\(outcome.rawValue)")
 XCTAssertEqual(record.decidedAt, fixedDate)
 }

 // Ensure every defined ApprovalOutcome case is covered by this test.
 XCTAssertEqual(ApprovalOutcome.allCases.count, 5)
 }
}
