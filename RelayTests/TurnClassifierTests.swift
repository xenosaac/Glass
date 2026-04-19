import XCTest
@testable import Relay

final class TurnClassifierTests: XCTestCase {

 func test_analyze_standaloneHello_isSocialOpener() {
 let analysis = TurnClassifier.analyze(messages: [
 .user(UserContent(blocks: [.text("hello")]))
 ])

 XCTAssertEqual(analysis?.classification, .socialOpener)
 XCTAssertEqual(
 analysis?.responseDirective,
 "reply warmly in two to four natural sentences and optionally ask one light follow-up"
 )
 }

 func test_analyze_howAreYou_isSocialOpenerEvenWithQuestionMark() {
 let analysis = TurnClassifier.analyze(messages: [
 .user(UserContent(blocks: [.text("How are you?")]))
 ])

 XCTAssertEqual(analysis?.classification, .socialOpener)
 }

 func test_analyze_explainMoreClearly_afterAssistantAnswer_isReferentialFollowup() {
 let analysis = TurnClassifier.analyze(messages: [
 .user(UserContent(blocks: [.text("Summarize this architecture plan")])),
 .assistant(AssistantContent(blocks: [.text("It is a plan to refactor nine areas of the system.")])),
 .user(UserContent(blocks: [.text("Explain more clearly")]))
 ])

 XCTAssertEqual(analysis?.classification, .referentialFollowup)
 XCTAssertEqual(
 analysis?.responseDirective,
 "clarify or expand the immediately previous answer using the recent conversation"
 )
 }

 func test_analyze_explainMoreClearly_withoutReferent_remainsQuestion() {
 let analysis = TurnClassifier.analyze(messages: [
 .user(UserContent(blocks: [.text("Explain more clearly")]))
 ])

 XCTAssertEqual(analysis?.classification, .question)
 }

 func test_analyze_whatIsMyName_withoutVisibleFact_isFactRecallUnknown() {
 let analysis = TurnClassifier.analyze(messages: [
 .user(UserContent(blocks: [.text("What is my name?")]))
 ])

 XCTAssertEqual(analysis?.classification, .factRecallUnknown)
 XCTAssertEqual(
 analysis?.responseDirective,
 "say you do not know the requested fact yet in one or two sentences and invite the user to tell you"
 )
 }

 func test_analyze_whatIsMyName_withVisibleFact_isFactRecallKnown() {
 let analysis = TurnClassifier.analyze(messages: [
 .user(UserContent(blocks: [.text("My name is Isaac")])),
 .assistant(AssistantContent(blocks: [.text("Okay.")])),
 .user(UserContent(blocks: [.text("What is my name?")]))
 ])

 XCTAssertEqual(analysis?.classification, .factRecallKnown)
 XCTAssertEqual(
 analysis?.responseDirective,
 "answer by restating the visible fact directly in one sentence"
 )
 }

 // MARK: - isConversationSummarizationRequest (T13 )

 func test_isConversationSummarizationRequest_matchesSummarizeOurConversation() {
 // Core device T13 pattern.
 XCTAssertTrue(
 TurnClassifier.isConversationSummarizationRequest(
 latestUserText: "Summarize our conversation so far"
 )
 )
 }

 func test_isConversationSummarizationRequest_matchesSummarizeSoFar() {
 // "so far" alone binds conversation-scope even without a noun
 // like "conversation" or "chat".
 XCTAssertTrue(
 TurnClassifier.isConversationSummarizationRequest(
 latestUserText: "Please summarize everything so far."
 )
 )
 }

 func test_isConversationSummarizationRequest_matchesWhatHaveWeDiscussed() {
 // Recall-phrase fast path — no verb-match required.
 XCTAssertTrue(
 TurnClassifier.isConversationSummarizationRequest(
 latestUserText: "What have we discussed?"
 )
 )
 }

 func test_isConversationSummarizationRequest_doesNotMatchSummarizeThisArticle() {
 // Critical negative: short-context summarization of an attached
 // document must stay on Gemma. Verb match ✓, scope match ✗.
 XCTAssertFalse(
 TurnClassifier.isConversationSummarizationRequest(
 latestUserText: "Summarize this article for me"
 )
 )
 }

 func test_isConversationSummarizationRequest_doesNotMatchSummarizeYourClaim() {
 // Device T11 shape: short-range referential ("your claim above"),
 // not conversation-scope. Must NOT pre-route — the user is asking
 // about the last turn only, and Gemma can handle that in-context.
 XCTAssertFalse(
 TurnClassifier.isConversationSummarizationRequest(
 latestUserText: "Summarize your claim above in one sentence"
 )
 )
 }

 func test_analyze_whatMyName_typo_withVisibleFact_isFactRecallKnown() {
 // device rerun round 4, Turn 14: user typed
 // `"What my name?"` (dropped "is"). Prior factRecallPhrases list
 // required "what is" or apostrophe-s, so this typo fell through
 // to .question and early-aborted at 80 chars instead of returning
 // the known fact. New phrase `"what my name"` catches the typo;
 // resolvedClassification upgrades to .factRecallKnown when the
 // fact is visible in history.
 let analysis = TurnClassifier.analyze(messages: [
 .user(UserContent(blocks: [.text("My name is Isaac")])),
 .assistant(AssistantContent(blocks: [.text("Okay.")])),
 .user(UserContent(blocks: [.text("What my name?")]))
 ])

 XCTAssertEqual(analysis?.classification, .factRecallKnown)
 XCTAssertEqual(
 analysis?.responseDirective,
 "answer by restating the visible fact directly in one sentence"
 )
 }

 func test_analyze_iAskedYouWhatIsMyName_isRepairCue() {
 let analysis = TurnClassifier.analyze(messages: [
 .user(UserContent(blocks: [.text("What is my name?")])),
 .assistant(AssistantContent(blocks: [.text("How can I help you today?")])),
 .user(UserContent(blocks: [.text("I asked you what is my name?")]))
 ])

 XCTAssertEqual(analysis?.classification, .repairCue)
 }

 func test_analyze_tf_remainsRepairCue() {
 let analysis = TurnClassifier.analyze(messages: [
 .user(UserContent(blocks: [.text("My name is Isaac")])),
 .assistant(AssistantContent(blocks: [.text("Please provide the text or image you would like me to work with.")])),
 .user(UserContent(blocks: [.text("tf")]))
 ])

 XCTAssertEqual(analysis?.classification, .repairCue)
 XCTAssertEqual(
 analysis?.responseDirective,
 "correct the missed point using the immediately previous relevant turn"
 )
 }

 // MARK: - Tool-intent detection (DEBUG.md F2)

 func test_isToolIntent_recognizesExplicitToolAsksAndSkipsNeutralText() {
 let positives: [String] = [
 "Find the latest working entry about module B",
 "Search my file and tell me where Model B is described.",
 "Can you list my files?",
 "Read my worklog",
 "Show me the documents in this folder",
 "Look up the log for last week",
 "Summarize my notes",
 "Open the attachment",
 ]
 let negatives: [String] = [
 "Hi, how are you?",
 "What's up?",
 "What is my name?",
 "Explain more clearly",
 "Find a way to solve this",
 "Can you show me love?",
 "Summarize this in one sentence",
 "Read between the lines",
 "My name is Isaac",
 ]

 for text in positives {
 XCTAssertTrue(
 TurnClassifier.isToolIntent(latestUserText: text),
 "Expected '\(text)' to be classified as tool intent"
 )
 }
 for text in negatives {
 XCTAssertFalse(
 TurnClassifier.isToolIntent(latestUserText: text),
 "Expected '\(text)' NOT to be classified as tool intent"
 )
 }
 }

 // MARK: - Round-5 time/date fast-path

 func test_isToolIntent_recognizesTimeDatePhrases() {
 // S2 T21 device-log shape — Gemma replied with text instead of
 // calling get_current_datetime. These prompts must elevate
 // toolMode to .required so the model is forced into tool emission.
 let positives: [String] = [
 "What time is it?",
 "What's the time?",
 "Whats the time",
 "What is the time?",
 "Tell me the time",
 "Check the time",
 "What's the date?",
 "What is the date?",
 "What's today's date?",
 "Today's date please",
 "Check the date",
 "What day is it?",
 "What's the day today?"
 ]
 for text in positives {
 XCTAssertTrue(
 TurnClassifier.isToolIntent(latestUserText: text),
 "Expected '\(text)' to be classified as tool intent (time/date fast-path)"
 )
 }
 }

 // MARK: - Round-6 web-search intent

 func test_isWebSearchIntent_recognizesExplicitSearchAsks() {
 let positives: [String] = [
 "Search the web for the YC W26 batch announcement",
 "Search for recent papers on Gemma 4",
 "Google for cactus compute",
 "Look up online how Tavily MCP works",
 "Find online a free MCP server",
 "What's the latest news about OpenAI?",
 "What is the latest on the YC project?",
 "Recent news about Apple Intelligence",
 "Current price of NVDA",
 "Stock price of AAPL today",
 "Weather in San Francisco",
 "Who won the 2025 Super Bowl?",
 "According to the web, what is the situation?"
 ]
 for text in positives {
 XCTAssertTrue(
 TurnClassifier.isWebSearchIntent(latestUserText: text),
 "Expected '\(text)' to be classified as web-search intent"
 )
 }
 }

 func test_isWebSearchIntent_doesNotMatchGenericQuestions() {
 let negatives: [String] = [
 "Tell me about quantum tunneling",
 "What's 47 × 83?",
 "What is the capital of France?",
 "Explain how attention works in transformers",
 "Hi, how are you?",
 "My name is Isaac",
 "Summarize our conversation so far",
 "Search my memory for past sessions", // memory, not web
 "Look up the value of variable X in this code" // code, not web
 ]
 for text in negatives {
 XCTAssertFalse(
 TurnClassifier.isWebSearchIntent(latestUserText: text),
 "Expected '\(text)' NOT to be classified as web-search intent"
 )
 }
 }

 func test_isToolIntent_doesNotMatchAdjacentPhrases() {
 // Negative guard: superficially time-adjacent text that is not
 // actually a time/date query must still pass through to the
 // verb+noun gate (and likely fall through to .question).
 let negatives: [String] = [
 "I have a great time at conferences",
 "It's about time we shipped this",
 "Save the date for next week",
 "Time flies when you're coding"
 ]
 for text in negatives {
 XCTAssertFalse(
 TurnClassifier.isToolIntent(latestUserText: text),
 "Expected '\(text)' NOT to be classified as tool intent"
 )
 }
 }
}
