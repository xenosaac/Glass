import XCTest
@testable import Relay

@MainActor
final class ChatViewModelSendTests: XCTestCase {

 private func makeViewModel(sessionId: String = UUID().uuidString) -> ChatViewModel {
 let core = AgentCore(
 host: CactusModelHost(modelPath: "/tmp/relay-test-model.gguf"),
 registry: ToolRegistry
 )
 return ChatViewModel(
 sessionId: sessionId,
 sessionIndex: SessionIndex,
 sharedServices: SharedServices,
 agentCore: core
 )
 }

 func test_send_invokesAcceptedCallback_forTextTurn() async {
 let viewModel = makeViewModel
 var acceptedCallbacks = 0

 let accepted = await viewModel.send(
 envelope: TurnEnvelope(
 kind: .text,
 visibleText: "hi",
 source: .composerText
 ),
 onAccepted: {
 acceptedCallbacks += 1
 }
 )

 XCTAssertTrue(accepted)
 XCTAssertEqual(acceptedCallbacks, 1)
 XCTAssertTrue(viewModel.displayMessages.contains {
 if case .user(_, let content) = $0 {
 return content.blocks.contains {
 if case .text(let text) = $0 {
 return text.contains("hi")
 }
 return false
 }
 }
 return false
 })
 }

 func test_send_invokesAcceptedCallback_forTextAndFileTurn() async {
 let viewModel = makeViewModel
 var acceptedCallbacks = 0
 let file = PendingFileIngestion(
 sourceURL: URL(fileURLWithPath: "/tmp/demo.txt"),
 displayName: "demo.txt",
 contentTypeIdentifier: "public.plain-text"
 )

 let accepted = await viewModel.send(
 envelope: TurnEnvelope(
 kind: .mixed,
 visibleText: "read this",
 fileRefs: [file],
 source: .composerFile
 ),
 onAccepted: {
 acceptedCallbacks += 1
 }
 )

 XCTAssertTrue(accepted)
 XCTAssertEqual(acceptedCallbacks, 1)
 }

 func test_send_doesNotInvokeAcceptedCallback_whenPrepareTurnFails() async {
 let viewModel = makeViewModel
 var acceptedCallbacks = 0

 let accepted = await viewModel.send(
 envelope: TurnEnvelope(
 kind: .image,
 visibleText: "",
 imageRefs: [URL(fileURLWithPath: "/tmp/missing-image.jpg")],
 source: .composerImage
 ),
 onAccepted: {
 acceptedCallbacks += 1
 }
 )

 XCTAssertFalse(accepted)
 XCTAssertEqual(acceptedCallbacks, 0)
 XCTAssertNotNil(viewModel.error)
 }

 func test_send_rejectsWhitespaceOnlyTextTurn() async {
 let viewModel = makeViewModel
 var acceptedCallbacks = 0

 let accepted = await viewModel.send(
 envelope: TurnEnvelope(
 kind: .text,
 visibleText: " \n\t ",
 source: .composerText
 ),
 onAccepted: {
 acceptedCallbacks += 1
 }
 )

 XCTAssertFalse(accepted)
 XCTAssertEqual(acceptedCallbacks, 0)
 XCTAssertTrue(viewModel.displayMessages.isEmpty)
 XCTAssertFalse(viewModel.isRunning)
 }
}
