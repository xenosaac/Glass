import Foundation

/// Post-generation output validator that catches weak-model response
/// failures before they reach the UI. Runs after primary Gemma produces
/// a `.message` response; on failure, `AgentRunner` rewrites the result's
/// `finishReason` to `.cloudHandoff`, letting the existing cloud-retry
/// branch route this single turn to Gemini.
///
/// Added as Option A (cloud-fallback on detected obedience
/// failure). Prompt surgery shrunk the prompt enough for Gemma-4-E2B to
/// follow instructions most of the time; this validator handles the
/// residual ~30% where ambient-history self-reinforcement overrides
/// the exampleBank few-shot.
///
/// Validation scope is intentionally narrow — only 4 classifications
/// where Gemma's help-desk bias produces clearly wrong output. Broader
/// classifications (question / referentialFollowup / ambiguous / etc.)
/// have too varied output shapes to pattern-match without false positives.
internal enum ResponseObedienceValidator {

 internal enum Verdict: Sendable, Equatable {
 case pass
 case fail(reason: String)
 }

 /// Validate a primary model response against the expected pattern for
 /// the turn's classification. Returns `.pass` for non-validated
 /// classifications and non-message finish reasons (tool calls,
 /// empty, cloudHandoff already flagged).
 internal static func validate(
 response: CompiledTurnResponse,
 classification: TurnClassification,
 visibleFacts: [VisibleFactRecord]
 ) -> Verdict {
 guard response.finishReason == .message else { return .pass }
 let text = response.outputText
 .lowercased()
 .trimmingCharacters(in: .whitespacesAndNewlines)
 guard !text.isEmpty else { return .pass }

 // top-level identity guard. Runs before
 // classification routing because identity leaks can appear on any
 // classification (T16 device log: `Tell me about yourself` was
 // classified `.question` and Gemma replied `"I am Gemma 4, a Large
 // Language Model developed by Google DeepMind."`). System prompt
 // explicitly forbids the model from naming the underlying model;
 // this validator catches the response when the rule is dropped.
 // Scans the entire response (not just first 80 chars) because
 // identity claims can follow a polite preamble.
 if containsIdentityViolation(text) {
 return .fail(reason: "identity violation: response identified self as the underlying model name (Gemma/Gemini/Google) instead of Glass")
 }

 switch classification {
 case .socialOpener:
 return validateSocialOpener(text: text)
 case .factRecallKnown:
 return validateFactRecallKnown(text: text, visibleFacts: visibleFacts)
 case .factRecallUnknown:
 return validateFactRecallUnknown(text: text)
 case .declarativeFact:
 return validateDeclarativeFact(text: text)
 case .question:
 // .question is a broad class; we only fail the obvious help-desk
 // opener shape. Narrow rule, same as socialOpener / declarativeFact —
 // a correct answer to ANY question never begins "How can I assist..."
 // or similar. Added after device rerun showed Gemma
 // replying "I am doing great... How can I assist you today?" to
 // "What is your name?" (.question classification).
 return validateSocialOpener(text: text)
 case .ambiguous:
 // Same rule, one-off turns like `"Use tool intent"` that the
 // classifier defaults into .ambiguous should still not receive a
 // bare `"How can I help you today?"` reply. Added after
 // the second device rerun showed exactly that pattern slipping
 // through the validator.
 return validateSocialOpener(text: text)
 case .referentialFollowup, .toolFollowup, .repairCue, .transportCheck:
 // device rerun showed `Explain more clearly`
 // (classified `.referentialFollowup`) producing
 // `"Please provide me with the text, concept, idea..."` — a
 // help-desk opener that slipped through because these four
 // classifications were returning `.pass` unconditionally.
 // They have varied output shapes, but none of them should
 // legitimately START with a help-desk opener, so running the
 // same narrow check here is safe and closes the hole without
 // opening new false-positive surfaces.
 return validateSocialOpener(text: text)
 }
 }

 // MARK: - Rules

 /// drastically narrowed list. The previous 40-entry
 /// pattern list was catching too many legitimate social openers
 /// ("How can I help?" is a valid greeting) and routing them through
 /// cloud handoff / canned-text substitution, which both (a) masked
 /// the model's real output from the raw log and (b) burned cloud
 /// calls on turns where the on-device reply was actually fine.
 ///
 /// Only two patterns are kept: the "Please provide the/me with X"
 /// hallucination where Gemma asks the user to paste an image/text
 /// that was never requested — that remains a genuine bug the user
 /// sees. Everything else (greetings, "How can I help", "I'm doing
 /// great") is allowed through so the user actually sees the model's
 /// response, and the raw log (`[DEBUG_GEMMA_RAW]`) remains the
 /// ground-truth evidence for any future tuning.
 private static let helpDeskOpeners: [String] = [
 "please provide me with",
 "please provide the"
 ]

 private static func startsWithHelpDesk(_ text: String) -> Bool {
 let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init()) ?? text
 let prefix = String(firstLine.prefix(80))
 return helpDeskOpeners.contains { prefix.contains($0) }
 }

 /// Streaming-time peek: can we abort the primary generation NOW based
 /// on only the first ~80 chars produced? Called by
 /// `AgentRunner.streamCompletion` after each token while the peek
 /// buffer is still short. Applies only to classifications where the
 /// full validator would also fail on a help-desk opener — otherwise we
 /// risk aborting legit outputs that happen to begin with a help-desk
 /// substring for a valid reason.
 ///
 /// The rule set intentionally matches `validateSocialOpener` here so
 /// early-abort is never stricter than the post-completion validator;
 /// any prefix that trips this function would also trip the normal
 /// validator at `.finished` time.
 internal static func isEarlyAbortCandidate(
 prefix: String,
 classification: TurnClassification
 ) -> Bool {
 guard prefix.count >= 40 else { return false }
 switch classification {
 case .socialOpener,
 .declarativeFact,
 .question,
 .ambiguous,
 .referentialFollowup,
 .toolFollowup,
 .repairCue,
 .transportCheck:
 // Use the same help-desk-opener check these classifications
 // use at `.finished` time. See  — `.referentialFollowup`
 // and friends now run `validateSocialOpener` too, so early
 // abort covers the same set by design.
 let lower = prefix.lowercased()
 .trimmingCharacters(in: .whitespacesAndNewlines)
 return startsWithHelpDesk(lower)
 case .factRecallKnown, .factRecallUnknown:
 // Fact-recall validators depend on the full response (token
 // presence / unknown-phrase presence). Do not abort early for
 // these — the 80-char prefix is not enough signal.
 return false
 }
 }

 private static func validateSocialOpener(text: String) -> Verdict {
 if startsWithHelpDesk(text) {
 return .fail(reason: "socialOpener opened with help-desk boilerplate")
 }
 if startsWithThirdPersonEcho(text) {
 return .fail(reason: "response opened with third-person self-narration")
 }
 return .pass
 }

 /// Third-person self-narration prefixes. Gemma-4-E2B occasionally
 /// responds to an instruction by describing what the user asked
 /// instead of performing it — e.g., to `"Summarize your claim above
 /// in one sentence"` it produced `"The user is asking me to summarize
 /// my previous statement in one sentence."` (device log, ,
 /// Turn 11). The response shape is never correct for any
 /// classification the validator runs against; catching it here shares
 /// the same early-abort + cloud-fallback path as help-desk openers.
 private static let thirdPersonEchoPrefixes: [String] = [
 "the user is asking",
 "the user wants",
 "the user would like",
 "the user is requesting",
 "the user's request"
 ]

 private static func startsWithThirdPersonEcho(_ text: String) -> Bool {
 let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init()) ?? text
 let prefix = String(firstLine.prefix(80))
 return thirdPersonEchoPrefixes.contains { prefix.contains($0) }
 }

 /// First-person identity-violation phrases. The system prompt instructs
 /// the model to call itself "Glass" and never the underlying model
 /// name; these patterns catch the leak. Scanned over the entire
 /// response because an identity claim can sit after a polite preamble
 /// (`"Sure! I am Gemma 4..."`).
 private static let identityViolationPhrases: [String] = [
 "i am gemma",
 "i'm gemma",
 "i am gemini",
 "i'm gemini",
 "i am a large language model",
 "i'm a large language model",
 "i am an ai language model",
 "i'm an ai language model",
 "i am an open weights model",
 "i'm an open weights model",
 "developed by google",
 "developed by google deepmind",
 "developed by deepmind",
 "i was created by google",
 "i was made by google",
 "google deepmind"
 ]

 internal static func containsIdentityViolation(_ text: String) -> Bool {
 identityViolationPhrases.contains { text.contains($0) }
 }

 /// Hardcoded fallback used when both primary and cloud responses leak
 /// model identity. Replaces the bad text rather than echoing it via
 /// `textOnlyFallback`. Kept short and Glass-shaped so the user still
 /// gets a coherent sentence even in this terminal branch.
 ///
 /// Use ONLY when the user actually asked an identity question — see
 /// `isIdentityQuestion(_:)`. For non-identity questions (calendar,
 /// search, etc.) where the cloud nonetheless leaked model identity,
 /// use `identityFallbackForNonIdentityQuestionText` instead so the
 /// user doesn't get a confusing introduction in response to e.g. a
 /// calendar query.
 internal static let identityFallbackText: String =
 "I'm Glass, an on-device assistant on your iPhone. Ask me anything and I'll help."

 /// 3 : substituted when an identity-violation
 /// cloud failure fires on a NON-identity user question (calendar,
 /// search, file-list, etc.). The introduction text
 /// `identityFallbackText` is a non-sequitur in that context (device
 /// log: user asked "What's on my calendar tomorrow?" and got
 /// "I'm Glass, an on-device assistant on your iPhone. Ask me
 /// anything and I'll help." — totally unrelated to the question).
 /// This neutral retry signal is correct for any non-identity intent.
 internal static let identityFallbackForNonIdentityQuestionText: String =
 "Sorry, I had trouble with that. Could you try asking again or rephrasing?"

 /// 3 : cheap phrase match for "the user's most
 /// recent question is genuinely about Glass's identity," which is
 /// the only context in which `identityFallbackText`'s "I'm Glass..."
 /// reply is on-topic. Substring contains-check matches phrasings
 /// like "introduce yourself please" and "hey what's your name?".
 private static let identityQuestionPhrases: [String] = [
 "who are you",
 "what are you",
 "what s your name",
 "whats your name",
 "what is your name",
 "introduce yourself",
 "tell me about yourself",
 "who am i talking to",
 "what should i call you"
 ]

 /// Returns true if the user's most recent message is an identity
 /// question. Used by `AgentRunner` to pick between the two identity
 /// fallback constants when the cloud response leaks model identity.
 internal static func isIdentityQuestion(_ userText: String) -> Bool {
 let normalized = TurnClassifier.normalizedComparisonText(userText)
 return identityQuestionPhrases.contains { normalized.contains($0) }
 }

 /// #2 : substituted when a post-cloud
 /// on-device iteration produces help-desk text (e.g. iter 2 of a
 /// turn that successfully wrote memory in iter 1). Without this,
 /// the user would see `"What can I help you with today?"` right
 /// after sharing a personal fact — exactly the bad UX Isaac
 /// reported on the device test. Generic enough to fit any post-
 /// tool turn shape (memory write, calendar add, reminder, etc.).
 internal static let postCloudObedienceFallbackText: String =
 "Got it. What else can I help with?"

 /// Stopwords excluded from salient-fact-token extraction.
 private static let factStopwords: Set<String> = [
 "the", "and", "but", "for", "you", "your", "name", "what", "that",
 "this", "have", "has", "with", "from", "into", "are", "my", "me",
 "call", "called", "say", "said", "tell", "told", "know", "remember"
 ]

 private static func validateFactRecallKnown(
 text: String,
 visibleFacts: [VisibleFactRecord]
 ) -> Verdict {
 let factTokens: Set<String> = Set(
 visibleFacts.flatMap { fact in
 fact.text
 .lowercased()
 .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
 .map(String.init())
 .filter { $0.count >= 3 && !factStopwords.contains($0) }
 }
 )
 guard !factTokens.isEmpty else {
 // No salient tokens to check. Don't block.
 return .pass
 }
 let mentioned = factTokens.contains { text.contains($0) }
 if !mentioned {
 return .fail(reason: "factRecallKnown response did not reference any visible fact token")
 }
 if startsWithHelpDesk(text) && text.count < 120 {
 return .fail(reason: "factRecallKnown response was a short help-desk menu even though fact was visible")
 }
 return .pass
 }

 private static let unknownFactPhrases: [String] = [
 "don't know",
 "do not know",
 "don t know",
 "haven't told",
 "haven t told",
 "haven't shared",
 "haven t shared",
 "you have not told",
 "not told me",
 "no information about",
 "don't have information",
 "do not have information",
 "i don't have"
 ]

 private static func validateFactRecallUnknown(text: String) -> Verdict {
 let hasUnknownPhrase = unknownFactPhrases.contains { text.contains($0) }
 if !hasUnknownPhrase {
 return .fail(reason: "factRecallUnknown did not include an 'I don't know' style phrase")
 }
 return .pass
 }

 private static func validateDeclarativeFact(text: String) -> Verdict {
 if startsWithHelpDesk(text) {
 return .fail(reason: "declarativeFact opened with help-desk boilerplate")
 }
 return .pass
 }
}
