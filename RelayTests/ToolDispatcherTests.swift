import XCTest
@testable import Relay

final class ToolDispatcherTests: XCTestCase {
 private actor PromptRecorder {
 private var prompts: [String] = []

 func append(_ prompt: String) {
 prompts.append(prompt)
 }

 func values() -> [String] {
 prompts
 }
 }

 private struct ReadOnlyTool: RelayTool {
 var name: String { "read_only_tool" }
 var description: String { "Always safe test tool" }
 var inputSchema: ToolInputSchema { ToolInputSchema(json: #"{"type":"object","properties":{}}"#) }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 ToolResult(toolUseId: "", output: "executed", isError: false)
 }
 }

 private struct WorkspaceWriteTool: RelayTool {
 var name: String { "workspace_write" }
 var description: String { "Write to a workspace file" }
 var inputSchema: ToolInputSchema { ToolInputSchema(json: #"{"type":"object","properties":{"path":{"type":"string"}}}"#) }
 var isConcurrencySafe: Bool { false }
 var isReadOnly: Bool { false }
 var isDestructive: Bool { true }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 ToolResult(toolUseId: "", output: "write-ok", isError: false)
 }

 func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .destructive(
 domain: .filesystem,
 operation: .write,
 summary: description,
 targetDescription: "/tmp/test.txt"
 )
 }
 }

 private struct DenyAllBroker: ApprovalBroker, Sendable {
 let reason: String

 func evaluate(
 tool: any RelayTool,
 input: ToolInput,
 context: ToolCallContext
 ) async -> ApprovalDecision {
 .deny(reason: reason)
 }
 }

 private struct ConfirmAllBroker: ApprovalBroker, Sendable {
 func evaluate(
 tool: any RelayTool,
 input: ToolInput,
 context: ToolCallContext
 ) async -> ApprovalDecision {
 .confirm(ApprovalRequest(
 prompt: "Approve tool?",
 category: .workspaceWrite,
 policy: NormalizedToolPolicy(
 toolName: tool.name,
 domain: .filesystem,
 operation: .write,
 risk: .destructive,
 summary: tool.description,
 targetDescription: "/tmp/test.txt",
 approvalCategory: .workspaceWrite
 )
 ))
 }
 }

 private func makeContext(with broker: any ApprovalBroker) -> ToolCallContext {
 ToolCallContext(
 messages: [],
 session: AgentSession(id: "t", startedAt: Date),
 approvalBroker: broker,
 progress: { _ in },
 services: DefaultServiceLocator
 )
 }

 func test_dispatcher_consultsApprovalBroker() async {
 let tool = ReadOnlyTool
 let use = ToolUseBlock(id: "call_1", name: tool.name, inputJson: "{}")
 let context = makeContext(with: DenyAllBroker(reason: "nope"))

 let dispatcher = ToolDispatcher
 let batch = await dispatcher.execute([use], tools: [tool], context: context)
 let results = batch.results
 let expected = MessageFactory.syntheticToolDenied(toolUseId: "call_1", reason: "nope")

 XCTAssertEqual(results.count, 1)
 XCTAssertEqual(results[0].toolUseId, expected.toolUseId)
 XCTAssertEqual(results[0].output, expected.output)
 XCTAssertEqual(results[0].isError, expected.isError)

 XCTAssertEqual(batch.executions.count, 1)
 XCTAssertFalse(batch.executions[0].approved)
 XCTAssertEqual(batch.executions[0].toolName, tool.name)

 XCTAssertEqual(batch.approvals.count, 1)
 XCTAssertEqual(batch.approvals[0].outcome, .brokerDenied)
 XCTAssertEqual(batch.approvals[0].reason, "nope")
 XCTAssertEqual(batch.approvals[0].toolName, tool.name)
 }

 func test_dispatcher_confirmApproval_executesSameToolUseWhenApproved() async {
 let tool = WorkspaceWriteTool
 let use = ToolUseBlock(id: "call_1", name: tool.name, inputJson: #"{"path":"/tmp/test.txt"}"#)
 let context = makeContext(with: ConfirmAllBroker)
 let recorder = PromptRecorder
 let dispatcher = ToolDispatcher(confirmationHandler: { _, _, prompt in
 await recorder.append(prompt)
 return true
 })

 let batch = await dispatcher.execute([use], tools: [tool], context: context)
 let results = batch.results
 let prompts = await recorder.values

 XCTAssertEqual(prompts, ["Approve tool?"])
 XCTAssertEqual(results.count, 1)
 XCTAssertEqual(results[0].toolUseId, "call_1")
 XCTAssertEqual(results[0].output, "write-ok")
 XCTAssertFalse(results[0].isError)

 XCTAssertEqual(batch.executions.count, 1)
 XCTAssertTrue(batch.executions[0].approved)
 XCTAssertEqual(batch.executions[0].toolName, tool.name)
 XCTAssertEqual(batch.executions[0].outputPreview, "write-ok")

 XCTAssertEqual(batch.approvals.count, 1)
 XCTAssertEqual(batch.approvals[0].outcome, .userApproved)
 XCTAssertNil(batch.approvals[0].reason)
 }

 func test_dispatcher_deniedConfirmation_returnsSyntheticUserDenied() async {
 let tool = WorkspaceWriteTool
 let use = ToolUseBlock(id: "call_1", name: tool.name, inputJson: #"{"path":"/tmp/test.txt"}"#)
 let context = makeContext(with: ConfirmAllBroker)
 let dispatcher = ToolDispatcher(confirmationHandler: { _, _, _ in false })

 let batch = await dispatcher.execute([use], tools: [tool], context: context)
 let results = batch.results
 let expected = MessageFactory.syntheticUserDenied(toolUseId: "call_1", prompt: "Approve tool?")

 XCTAssertEqual(results.count, 1)
 XCTAssertEqual(results[0].toolUseId, expected.toolUseId)
 XCTAssertEqual(results[0].output, expected.output)
 XCTAssertEqual(results[0].isError, expected.isError)

 XCTAssertEqual(batch.executions.count, 1)
 XCTAssertFalse(batch.executions[0].approved)

 XCTAssertEqual(batch.approvals.count, 1)
 XCTAssertEqual(batch.approvals[0].outcome, .userDenied)
 XCTAssertEqual(batch.approvals[0].reason, "Approve tool?")
 }

 func test_dispatcher_missingConfirmationHandler_returnsSyntheticConfirmationRequired() async {
 let tool = WorkspaceWriteTool
 let use = ToolUseBlock(id: "call_1", name: tool.name, inputJson: #"{"path":"/tmp/test.txt"}"#)
 let context = makeContext(with: ConfirmAllBroker)
 let dispatcher = ToolDispatcher

 let batch = await dispatcher.execute([use], tools: [tool], context: context)
 let results = batch.results
 let expected = MessageFactory.syntheticConfirmationRequired(toolUseId: "call_1", prompt: "Approve tool?")

 XCTAssertEqual(results.count, 1)
 XCTAssertEqual(results[0].toolUseId, expected.toolUseId)
 XCTAssertEqual(results[0].output, expected.output)
 XCTAssertEqual(results[0].isError, expected.isError)

 XCTAssertEqual(batch.executions.count, 1)
 XCTAssertFalse(batch.executions[0].approved)

 XCTAssertEqual(batch.approvals.count, 1)
 XCTAssertEqual(batch.approvals[0].outcome, .deferredNoHandler)
 XCTAssertEqual(batch.approvals[0].reason, "Approve tool?")
 }

 // MARK: - Glass 2.0 Module C — new coverage

 private struct AllowingBroker: ApprovalBroker, Sendable {
 func evaluate(
 tool: any RelayTool,
 input: ToolInput,
 context: ToolCallContext
 ) async -> ApprovalDecision {
 .allow
 }
 }

 private struct ThrowingTool: RelayTool {
 var name: String { "throwing_tool" }
 var description: String { "Always throws" }
 var inputSchema: ToolInputSchema { ToolInputSchema(json: #"{"type":"object","properties":{}}"#) }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }

 struct Boom: Error, LocalizedError {
 var errorDescription: String? { "boom" }
 }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 throw Boom
 }
 }

 func test_dispatcher_allowPath_emitsAutoAllowed() async {
 let tool = ReadOnlyTool
 let use = ToolUseBlock(id: "call_1", name: tool.name, inputJson: "{}")
 let context = makeContext(with: AllowingBroker)

 let dispatcher = ToolDispatcher
 let batch = await dispatcher.execute([use], tools: [tool], context: context)

 XCTAssertEqual(batch.results.count, 1)
 XCTAssertEqual(batch.results[0].output, "executed")
 XCTAssertFalse(batch.results[0].isError)

 XCTAssertEqual(batch.executions.count, 1)
 XCTAssertTrue(batch.executions[0].approved)
 XCTAssertEqual(batch.executions[0].toolName, tool.name)
 XCTAssertEqual(batch.executions[0].outputPreview, "executed")
 XCTAssertEqual(batch.executions[0].source, .other)

 XCTAssertEqual(batch.approvals.count, 1)
 XCTAssertEqual(batch.approvals[0].outcome, .autoAllowed)
 XCTAssertNil(batch.approvals[0].reason)
 XCTAssertEqual(batch.approvals[0].toolName, tool.name)
 }

 func test_dispatcher_allowPathThrow_emitsAutoAllowedIsError() async {
 let tool = ThrowingTool
 let use = ToolUseBlock(id: "call_1", name: tool.name, inputJson: "{}")
 let context = makeContext(with: AllowingBroker)

 let dispatcher = ToolDispatcher
 let batch = await dispatcher.execute([use], tools: [tool], context: context)

 XCTAssertEqual(batch.results.count, 1)
 XCTAssertTrue(batch.results[0].isError)
 XCTAssertTrue(batch.results[0].output.contains("boom"))

 XCTAssertEqual(batch.executions.count, 1)
 // Approved path that failed — approved still true, outputPreview carries the error.
 XCTAssertTrue(batch.executions[0].approved)
 XCTAssertTrue(batch.executions[0].outputPreview.contains("boom"))

 XCTAssertEqual(batch.approvals.count, 1)
 XCTAssertEqual(batch.approvals[0].outcome, .autoAllowed)
 }

 func test_dispatcher_toolNotFound_emitsExecutionWithoutApproval() async {
 let use = ToolUseBlock(id: "call_1", name: "unknown_tool", inputJson: "{}")
 let context = makeContext(with: AllowingBroker)

 let dispatcher = ToolDispatcher
 let batch = await dispatcher.execute([use], tools: [], context: context)

 XCTAssertEqual(batch.results.count, 1)
 XCTAssertTrue(batch.results[0].isError)

 XCTAssertEqual(batch.executions.count, 1)
 XCTAssertFalse(batch.executions[0].approved)
 XCTAssertEqual(batch.executions[0].toolName, "unknown_tool")
 XCTAssertEqual(batch.executions[0].outputPreview, "tool not found")
 XCTAssertEqual(batch.executions[0].source, .other)

 // Tool-not-found is the documented single exception: broker was never
 // consulted, so no ApprovalDecisionRecord is emitted.
 XCTAssertTrue(batch.approvals.isEmpty)
 }
}
