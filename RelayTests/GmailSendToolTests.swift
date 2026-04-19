import XCTest
@testable import Relay

/// 2 — `GmailSendTool.policyDescriptor` previously
/// fell back to the developer-doc class `description` when the subject
/// was missing/empty. The fallback now uses a clean action sentence
/// suitable for an approval prompt.
final class GmailSendToolTests: XCTestCase {

 private struct AlwaysAllowBroker: ApprovalBroker, Sendable {
 func evaluate(
 tool: any RelayTool,
 input: ToolInput,
 context: ToolCallContext
 ) async -> ApprovalDecision {
 .allow
 }
 }

 private static func makeContext() -> ToolCallContext {
 ToolCallContext(
 messages: [],
 session: AgentSession(id: "gmail-test", startedAt: Date),
 approvalBroker: AlwaysAllowBroker,
 progress: { _ in },
 services: DefaultServiceLocator
 )
 }

 private static func policyJson(_ dict: [String: Any]) -> ToolInput {
 let data = try! JSONSerialization.data(withJSONObject: dict)
 return ToolInput(json: data)
 }

 func test_gmailSend_policyDescriptor_subjectEmpty_usesFriendlyFallback() async {
 let tool = GmailSendTool
 let input = Self.policyJson(["to": "x@y.com", "subject": "", "body": "hi"])
 let descriptor = await tool.policyDescriptor(input: input, context: Self.makeContext)

 XCTAssertEqual(descriptor.summary, "Send an email.")
 XCTAssertFalse(
 descriptor.summary.contains("in_reply_to_message_id"),
 "developer-doc string must not leak into approval summary"
 )
 XCTAssertFalse(
 descriptor.summary.contains("Supports replies via"),
 "developer-doc string must not leak into approval summary"
 )
 XCTAssertEqual(descriptor.targetDescription, "x@y.com")
 }

 func test_gmailSend_policyDescriptor_subjectPresent_unchangedSummary() async {
 let tool = GmailSendTool
 let input = Self.policyJson(["to": "x@y.com", "subject": "Test", "body": "hi"])
 let descriptor = await tool.policyDescriptor(input: input, context: Self.makeContext)

 XCTAssertEqual(descriptor.summary, "Send an email with subject \"Test\".")
 XCTAssertEqual(descriptor.targetDescription, "x@y.com")
 }
}
