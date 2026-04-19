import XCTest
@testable import Relay

// this file was trimmed after the help-desk opener list was
// intentionally narrowed from ~40 entries to 2 ("please provide me with" /
// "please provide the"). Tests that previously asserted `.fail` on normal
// social openers ("How can I assist you today?", "I'm doing great, thank
// you for asking", "How can Glass help", etc.) now assert `.pass` because
// those phrases are legitimate output and were causing cloud handoff + canned
// text substitution on turns where the model was actually fine.
//
// Identity-violation guard, `please provide` hallucination guard, third-
// person echo guard, and fact-recall guards are all UNCHANGED and still
// tested below.

final class ResponseObedienceValidatorTests: XCTestCase {

 private func makeResponse(
 _ text: String,
 finishReason: FinishReason = .message
 ) -> CompiledTurnResponse {
 CompiledTurnResponse(
 tier: .fast,
 outputText: text,
 toolCalls: [],
 finishReason: finishReason,
 rawCompletion: nil
 )
 }

 private func makeFact(_ text: String) -> VisibleFactRecord {
 VisibleFactRecord(
 text: text,
 sourceTurnIndex: 0,
 sourceClassification: .declarativeFact
 )
 }

 // MARK: - socialOpener (post-D.1: help-desk shapes now ALLOWED)

 func test_socialOpener_passesOnWarmReply() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("Hey! Doing well, thanks. What's on your mind?"),
 classification: .socialOpener,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 func test_socialOpener_passesOnHelpDeskOpener_postRelaxation() {
 // Post-D.1 this no longer fails — we let normal social openers
 // through so the user actually sees the model's reply.
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("How can I assist you today?"),
 classification: .socialOpener,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 func test_socialOpener_failsOnPleaseProvideTheText() {
 // Genuine hallucination pattern (asking user to paste something that
 // was never requested). Kept as a hard fail.
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("Please provide the text or image you would like me to work with."),
 classification: .socialOpener,
 visibleFacts: []
 )
 guard case .fail = v else {
 return XCTFail("expected .fail, got \(v)")
 }
 }

 func test_socialOpener_failsOnPleaseProvideMeWith() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("Please provide me with the concept you would like me to explain."),
 classification: .socialOpener,
 visibleFacts: []
 )
 guard case .fail = v else {
 return XCTFail("expected .fail, got \(v)")
 }
 }

 // MARK: - factRecallKnown

 func test_factRecallKnown_passesWhenFactTokenMentioned() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("Your name is Isaac."),
 classification: .factRecallKnown,
 visibleFacts: [makeFact("My name is Isaac.")]
 )
 XCTAssertEqual(v, .pass)
 }

 func test_factRecallKnown_failsWhenFactTokenMissing() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("I'm not sure who you are."),
 classification: .factRecallKnown,
 visibleFacts: [makeFact("My name is Isaac.")]
 )
 guard case .fail = v else {
 return XCTFail("expected .fail, got \(v)")
 }
 }

 // MARK: - factRecallUnknown

 func test_factRecallUnknown_passesOnDontKnow() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("I don't know your name yet. Tell me and I'll remember it."),
 classification: .factRecallUnknown,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 func test_factRecallUnknown_failsOnResponseWithoutUnknownPhrase() {
 // factRecallUnknown checks for an "I don't know"-style phrase,
 // independent of help-desk openers.
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("Your favorite color is definitely blue!"),
 classification: .factRecallUnknown,
 visibleFacts: []
 )
 guard case .fail = v else {
 return XCTFail("expected .fail, got \(v)")
 }
 }

 // MARK: - declarativeFact (post-D.1: help-desk shapes now ALLOWED)

 func test_declarativeFact_passesOnAcknowledgement() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("Got it, Isaac. I'll remember that."),
 classification: .declarativeFact,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 func test_declarativeFact_passesOnHelpDeskOpener_postRelaxation() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("How can I assist you today?"),
 classification: .declarativeFact,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 func test_declarativeFact_failsOnPleaseProvide() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("Please provide the fact you would like me to remember."),
 classification: .declarativeFact,
 visibleFacts: []
 )
 guard case .fail = v else {
 return XCTFail("expected .fail, got \(v)")
 }
 }

 // MARK: - .question (post-D.1: non-help-desk shapes pass)

 func test_question_passesOnLegitAnswer() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("The capital of France is Paris."),
 classification: .question,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 func test_question_passesOnHelpDeskOpener_postRelaxation() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("How can I help you today?"),
 classification: .question,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 func test_question_failsOnPleaseProvideHallucination() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("Please provide the question you would like me to answer."),
 classification: .question,
 visibleFacts: []
 )
 guard case .fail = v else {
 return XCTFail("expected .fail, got \(v)")
 }
 }

 // MARK: - third-person echo (UNCHANGED)

 func test_referentialFollowup_failsOnThirdPersonEcho() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("The user is asking me to summarize my previous statement in one sentence."),
 classification: .referentialFollowup,
 visibleFacts: []
 )
 guard case .fail = v else {
 return XCTFail("expected .fail, got \(v)")
 }
 }

 func test_thirdPersonEcho_doesNotFireOnLegitAnswer() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("The capital of France is Paris. The user experience of the city is famously romantic."),
 classification: .referentialFollowup,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 // MARK: - Non-message finish reasons bypass

 func test_toolCallsFinishReason_bypassesValidation() {
 let response = makeResponse(
 "Please provide the text.",
 finishReason: .toolCalls
 )
 let v = ResponseObedienceValidator.validate(
 response: response,
 classification: .socialOpener,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 // MARK: - early-abort candidate (post-D.1: only fires on the narrow list)

 func test_isEarlyAbortCandidate_firesOnPleaseProvideTheOpener() {
 let prefix = "Please provide the text or image you would like me to"
 XCTAssertTrue(
 ResponseObedienceValidator.isEarlyAbortCandidate(
 prefix: prefix,
 classification: .socialOpener
 )
 )
 }

 func test_isEarlyAbortCandidate_doesNotFireOnHelpDeskOpener_postRelaxation() {
 // "How can I assist" is no longer on the list — should NOT abort.
 let prefix = "Hello! How can I assist you today? I'm ready"
 XCTAssertFalse(
 ResponseObedienceValidator.isEarlyAbortCandidate(
 prefix: prefix,
 classification: .socialOpener
 )
 )
 }

 func test_isEarlyAbortCandidate_doesNotFireOnLegitAnswer() {
 let prefix = "The capital of France is Paris, and its population is about"
 XCTAssertFalse(
 ResponseObedienceValidator.isEarlyAbortCandidate(
 prefix: prefix,
 classification: .question
 )
 )
 }

 func test_isEarlyAbortCandidate_skipsWhenPrefixTooShort() {
 let prefix = "Please"
 XCTAssertFalse(
 ResponseObedienceValidator.isEarlyAbortCandidate(
 prefix: prefix,
 classification: .socialOpener
 )
 )
 }

 func test_isEarlyAbortCandidate_skipsFactRecallClassifications() {
 let prefix = "Please provide the fact you would like me to remember."
 XCTAssertFalse(
 ResponseObedienceValidator.isEarlyAbortCandidate(
 prefix: prefix,
 classification: .factRecallKnown
 )
 )
 }

 // MARK: - Identity guard (UNCHANGED)

 func test_validate_failsOnIamGemma4_question() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("I am Gemma 4, a Large Language Model developed by Google DeepMind."),
 classification: .question,
 visibleFacts: []
 )
 guard case .fail(let reason) = v else {
 return XCTFail("expected .fail, got \(v)")
 }
 XCTAssertTrue(reason.contains("identity"))
 }

 func test_validate_failsOnLargeLanguageModelClaim() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("Sure! As a large language model trained by Google, I have access to a wide variety of information."),
 classification: .question,
 visibleFacts: []
 )
 guard case .fail(let reason) = v else {
 return XCTFail("expected .fail, got \(v)")
 }
 XCTAssertTrue(reason.contains("identity"))
 }

 func test_validate_failsOnDevelopedByGoogle_socialOpener() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("Hi! I was developed by Google DeepMind to assist you with everyday tasks."),
 classification: .socialOpener,
 visibleFacts: []
 )
 guard case .fail = v else {
 return XCTFail("expected .fail, got \(v)")
 }
 }

 func test_validate_passesOnGlassReply() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("I'm Glass, an on-device assistant on your iPhone. Ask me anything and I'll help."),
 classification: .question,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 func test_validate_passesOnIncidentalGemmaMention() {
 let v = ResponseObedienceValidator.validate(
 response: makeResponse("You can run Gemma locally on a recent iPhone if you have at least 8GB of RAM."),
 classification: .question,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 // MARK: - Fallback constants

 func test_postCloudObedienceFallbackText_isGlassShaped() {
 let txt = ResponseObedienceValidator.postCloudObedienceFallbackText
 XCTAssertFalse(txt.isEmpty)
 // The fallback must NOT itself be flagged (would cause infinite
 // substitution loops in the runner).
 let v = ResponseObedienceValidator.validate(
 response: makeResponse(txt),
 classification: .question,
 visibleFacts: []
 )
 XCTAssertEqual(v, .pass)
 }

 func test_identityFallbackText_isGlassShaped() {
 XCTAssertTrue(ResponseObedienceValidator.identityFallbackText.contains("Glass"))
 XCTAssertFalse(ResponseObedienceValidator.identityFallbackText.lowercased().contains("gemma"))
 XCTAssertFalse(ResponseObedienceValidator.identityFallbackText.lowercased().contains("gemini"))
 }

 // MARK: - Identity-question detection

 func test_isIdentityQuestion_detectsCommonPhrases() {
 XCTAssertTrue(ResponseObedienceValidator.isIdentityQuestion("Who are you?"))
 XCTAssertTrue(ResponseObedienceValidator.isIdentityQuestion("What's your name?"))
 XCTAssertTrue(ResponseObedienceValidator.isIdentityQuestion("Introduce yourself please."))
 XCTAssertTrue(ResponseObedienceValidator.isIdentityQuestion("Hey, what is your name?"))
 XCTAssertTrue(ResponseObedienceValidator.isIdentityQuestion("Tell me about yourself."))
 }

 func test_isIdentityQuestion_doesNotDetectCalendarOrGenericQuestions() {
 XCTAssertFalse(ResponseObedienceValidator.isIdentityQuestion("What's on my calendar tomorrow?"))
 XCTAssertFalse(ResponseObedienceValidator.isIdentityQuestion("What time is it?"))
 XCTAssertFalse(ResponseObedienceValidator.isIdentityQuestion("Search my files for project notes."))
 XCTAssertFalse(ResponseObedienceValidator.isIdentityQuestion(""))
 }

 func test_identityFallbackTexts_areDistinct() {
 XCTAssertNotEqual(
 ResponseObedienceValidator.identityFallbackText,
 ResponseObedienceValidator.identityFallbackForNonIdentityQuestionText
 )
 XCTAssertFalse(ResponseObedienceValidator.identityFallbackForNonIdentityQuestionText.isEmpty)
 XCTAssertFalse(
 ResponseObedienceValidator.identityFallbackForNonIdentityQuestionText.contains("Glass"),
 "non-identity fallback should NOT introduce the assistant; it's a neutral retry signal"
 )
 }
}
