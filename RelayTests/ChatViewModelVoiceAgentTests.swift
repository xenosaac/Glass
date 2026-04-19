import XCTest
@testable import Relay

/// voice-agent mode regression guards.
/// The voice path now auto-submits transcripts via `send(envelope:)` with
/// `kind: .voice` + `source: .composerVoice` instead of dropping them
/// into `pendingComposerText`. These tests lock that contract.
@MainActor
final class ChatViewModelVoiceAgentTests: XCTestCase {

 private func makeViewModel() -> ChatViewModel {
 let core = AgentCore(
 host: CactusModelHost(modelPath: "/tmp/relay-test-model.gguf"),
 registry: ToolRegistry
 )
 return ChatViewModel(
 sessionId: UUID.uuidString,
 sessionIndex: SessionIndex,
 sharedServices: SharedServices,
 agentCore: core
 )
 }

 func test_voiceEnvelope_landsAsUserMessage_notInComposer() async {
 let viewModel = makeViewModel
 let accepted = await viewModel.send(envelope: TurnEnvelope(
 kind: .voice,
 visibleText: "What time is it?",
 source: .composerVoice
 ))
 XCTAssertTrue(accepted, "voice envelope should be accepted")
 XCTAssertNil(
 viewModel.pendingComposerText,
 "voice agent mode must NOT route through pendingComposerText"
 )
 // The user message must appear in display messages.
 let containsUserText = viewModel.displayMessages.contains { msg in
 if case .user(_, let content) = msg {
 return content.blocks.contains {
 if case .text(let t) = $0 { return t.contains("What time is it") }
 return false
 }
 }
 return false
 }
 XCTAssertTrue(containsUserText, "voice transcript must appear as a user message")
 }

 func test_voiceEnvelope_emptyTranscript_isRejected() async {
 let viewModel = makeViewModel
 let accepted = await viewModel.send(envelope: TurnEnvelope(
 kind: .voice,
 visibleText: " ",
 source: .composerVoice
 ))
 XCTAssertFalse(
 accepted,
 "empty/whitespace-only voice transcript must be rejected by the send guard"
 )
 }
}
