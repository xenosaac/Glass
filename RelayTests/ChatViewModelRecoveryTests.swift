import XCTest
@testable import Relay

@MainActor
final class ChatViewModelRecoveryTests: XCTestCase {
 private func makeViewModel() -> ChatViewModel {
 ChatViewModel(
 sessionId: "session-recovery-tests",
 sessionIndex: SessionIndex,
 sharedServices: SharedServices
 )
 }

 func test_handleEvent_clearProvisionalOutput_resetsStreamingBuffers() {
 let viewModel = makeViewModel

 viewModel.handleEvent(.tokenReceived("hello"))
 XCTAssertEqual(viewModel.streamingText, "hello")

 viewModel.handleEvent(.clearProvisionalOutput)
 viewModel.handleEvent(.tokenReceived("new"))

 XCTAssertEqual(viewModel.streamingText, "new")
 }

 func test_handleEvent_recoveryStateChanged_setsRecoveringStatusWithoutError() {
 let viewModel = makeViewModel

 viewModel.handleEvent(.recoveryStateChanged(.retryingWithCloud))

 XCTAssertEqual(viewModel.agentStatus, .recovering(.retryingWithCloud))
 XCTAssertNil(viewModel.error)
 }

 func test_handleEvent_failure_clearsStreamingBuffersAndSetsVisibleError() {
 let viewModel = makeViewModel

 viewModel.handleEvent(.tokenReceived("hello"))
 viewModel.handleEvent(.failure(message: "boom"))

 XCTAssertEqual(viewModel.streamingText, "")
 XCTAssertEqual(viewModel.error, "boom")
 XCTAssertEqual(viewModel.agentStatus, .error("boom"))
 }
}
