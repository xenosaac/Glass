import XCTest
@testable import Relay

/// Whisper-small hallucination filter tests.
///
/// Backstop for the device-log bug where Whisper returned 163 chars of
/// `". . . . . . . . . . . . . . . . . . . . "` and the pipeline
/// accepted it as a USER message.
final class VoiceEngineHallucinationTests: XCTestCase {

 func test_isLikelyWhisperHallucination_rejectsDotWall() {
 // Verbatim shape from the device log (40-char prefix, then more).
 let dotWall = String(repeating: ". ", count: 80)
 XCTAssertTrue(
 VoiceEngine.isLikelyWhisperHallucination(dotWall),
 "dot/space wall should be rejected as hallucination"
 )
 }

 func test_isLikelyWhisperHallucination_rejectsBlacklistedBoilerplate() {
 // Common Whisper training-data leaks.
 XCTAssertTrue(VoiceEngine.isLikelyWhisperHallucination("Thank you."))
 XCTAssertTrue(VoiceEngine.isLikelyWhisperHallucination("thank you"))
 XCTAssertTrue(VoiceEngine.isLikelyWhisperHallucination("Subscribe to my channel."))
 XCTAssertTrue(VoiceEngine.isLikelyWhisperHallucination("Bye bye."))
 XCTAssertTrue(VoiceEngine.isLikelyWhisperHallucination("[Music]"))
 XCTAssertTrue(VoiceEngine.isLikelyWhisperHallucination("..."))
 }

 func test_isLikelyWhisperHallucination_acceptsRealSpeech() {
 // The kinds of phrases we actually want to accept.
 XCTAssertFalse(VoiceEngine.isLikelyWhisperHallucination("What's on my calendar today?"))
 XCTAssertFalse(VoiceEngine.isLikelyWhisperHallucination("My name is Isaac"))
 XCTAssertFalse(VoiceEngine.isLikelyWhisperHallucination("Show me my reminders"))
 XCTAssertFalse(VoiceEngine.isLikelyWhisperHallucination("Send a text to mom"))
 }

 func test_isLikelyWhisperHallucination_acceptsPunctuationHeavyButRealSpeech() {
 // High-punctuation real speech must still pass — the 30% ratio
 // gate is intentionally lenient about question marks, exclamation
 // marks, and ellipses inside a real sentence.
 XCTAssertFalse(VoiceEngine.isLikelyWhisperHallucination("Hi! How are you?"))
 XCTAssertFalse(VoiceEngine.isLikelyWhisperHallucination("Wait... what?"))
 XCTAssertFalse(VoiceEngine.isLikelyWhisperHallucination("Yes!!!"))
 }

 func test_isLikelyWhisperHallucination_rejectsLowAlphanumericRatio() {
 // Edge cases the dot wall doesn't cover but are still noise.
 XCTAssertTrue(VoiceEngine.isLikelyWhisperHallucination(". . . a . . ."))
 XCTAssertTrue(VoiceEngine.isLikelyWhisperHallucination("- - - - - - -"))
 XCTAssertTrue(VoiceEngine.isLikelyWhisperHallucination("?? ?? ?? ??"))
 }
}
