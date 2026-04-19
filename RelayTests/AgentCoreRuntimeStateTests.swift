import XCTest
@testable import Relay

final class AgentCoreRuntimeStateTests: XCTestCase {

 private actor ApprovalProbe {
 private var startedContinuation: CheckedContinuation<Void, Never>?
 private var decisionContinuation: CheckedContinuation<Bool, Never>?
 private var started = false

 func handler(toolUseId: String, toolName: String, prompt: String) async -> Bool {
 started = true
 startedContinuation?.resume
 startedContinuation = nil
 return await withCheckedContinuation { continuation in
 decisionContinuation = continuation
 }
 }

 func waitUntilStarted() async {
 if started { return }
 await withCheckedContinuation { continuation in
 startedContinuation = continuation
 }
 }

 func resolve(approved: Bool) {
 decisionContinuation?.resume(returning: approved)
 decisionContinuation = nil
 }
 }

 func test_agentCore_tracksPendingApprovalStateWhileAwaitingResolution() async {
 let core = AgentCore(host: CactusModelHost(modelPath: "/dev/null"))
 let probe = ApprovalProbe

 let task = Task {
 await core.handleApprovalRequest(
 toolUseId: "call_1",
 toolName: "send_email",
 prompt: "Send the message?",
 requestedAtTurnCount: 3,
 handler: { toolUseId, toolName, prompt in
 await probe.handler(toolUseId: toolUseId, toolName: toolName, prompt: prompt)
 }
 )
 }

 await probe.waitUntilStarted
 let waitingState = await core.runtimeStateForTesting
 XCTAssertEqual(waitingState.pendingApprovalState.current?.toolUseId, "call_1")
 XCTAssertEqual(waitingState.pendingApprovalState.current?.toolName, "send_email")
 XCTAssertEqual(waitingState.pendingApprovalState.current?.prompt, "Send the message?")
 XCTAssertEqual(waitingState.pendingApprovalState.current?.requestedAtTurnCount, 3)

 await probe.resolve(approved: true)
 let approved = await task.value
 XCTAssertTrue(approved)

 let resolvedState = await core.runtimeStateForTesting
 XCTAssertNil(resolvedState.pendingApprovalState.current)
 XCTAssertEqual(resolvedState.pendingApprovalState.lastResolution?.toolUseId, "call_1")
 XCTAssertEqual(resolvedState.pendingApprovalState.lastResolution?.approved, true)
 XCTAssertEqual(resolvedState.pendingApprovalState.lastResolution?.resolvedAtTurnCount, 3)
 }
}
