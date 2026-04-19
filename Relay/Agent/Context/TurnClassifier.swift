import Foundation

internal enum TurnRecentTailStrategy: Sendable, Equatable {
 case none
 case lexicalOverlap(maxTurns: Int)
 case immediateRecent(maxTurns: Int)
}

internal struct TurnAnalysis: Sendable, Equatable {
 internal let latestUserText: String
 internal let normalizedLatestText: String
 internal let classification: TurnClassification
 internal let salientTerms: Set<String>
 internal let recentTailStrategy: TurnRecentTailStrategy
 internal let visibleFactTexts: [String]
 internal let responseDirective: String
}

internal struct TurnClassifier: Sendable {
 private enum PreviousTurnContext: Sendable, Equatable {
 case none
 case user
 case assistant
 case tool
 }

 private struct ConversationTurn: Sendable, Equatable {
 let role: String
 let text: String
 let salientTerms: Set<String>
 }

 private static let systemReminderRegex: NSRegularExpression? = try? NSRegularExpression(
 pattern: "<system-reminder>[\\s\\S]*?</system-reminder>",
 options: [.caseInsensitive, .dotMatchesLineSeparators]
 )

 private static let salientStopwords: Set<String> = [
 "a", "an", "and", "are", "as", "at", "be", "but", "by", "for",
 "from", "how", "i", "if", "in", "is", "it", "me", "my", "of",
 "on", "or", "so", "that", "the", "their", "them", "there", "they",
 "this", "to", "was", "we", "what", "when", "where", "who", "why",
 "with", "you", "your"
 ]

 private static let repairCuePhrases: [String] = [
 "are you listening", "you ignored", "you missed",
 "wrong answer", "wrong question", "not what i asked",
 "that is not what i asked", "answer my question", "read that again",
 "i asked you what", "i asked you who"
 ]

 private static let repairCueExactTexts: Set<String> = [
 "tf", "wtf", "what", "what?", "huh", "huh?",
 "bro", "bro?", "bruh", "bruh?"
 ]

 private static let transportCheckPhrases: [String] = [
 "can you hear me", "can you hear that", "did you hear me",
 "did you get that", "did you read that", "did you receive that",
 "can you process this", "can you process that", "are you there"
 ]

 private static let toolFollowupExactTexts: Set<String> = [
 "yes", "yeah", "yep", "sure", "go ahead", "do it", "send it",
 "use that", "use it", "open it", "that one", "this one"
 ]

 private static let factRecallPhrases: [String] = [
 "what's my name", "what s my name", "what is my name", "who am i",
 "what did i just tell you", "what did i tell you",
 "do you remember my name",
 // device rerun Turn 14 showed `"What my name?"` (typo,
 // missing "is") classified as `.question` → early-aborted at 80
 // chars, so the valid answer `"Your name is Isaac."` never landed
 // despite the fact being in history at msg [8] and [11]. Adding
 // typo/shortened variants so normalized `"what my name"` matches
 // via `.contains` below, routing to `.factRecallUnknown`, which
 // then upgrades to `.factRecallKnown` via `resolvedClassification`
 // when a visible fact is present.
 "what my name", "whats my name",
 "tell me my name", "say my name",
 "remind me of my name", "what did i say my name"
 ]

 private static let declarativeFactPhrases: [String] = [
 "my name is", "call me", "i go by", "remember that my name is"
 ]

 private static let questionLeadPhrases: [String] = [
 "who ", "what ", "when ", "where ", "why ", "how ", "can ",
 "could ", "would ", "should ", "do ", "does ", "did ", "is ",
 "are ", "am ", "will ", "tell me", "explain", "summarize",
 "list ", "compare "
 ]

 private static let socialOpenerExactTexts: Set<String> = [
 "hi", "hi there", "hello", "hey", "yo", "sup", "hiya",
 "how are you", "how are you doing", "how have you been",
 "what s up", "whats up"
 ]

 private static let socialOpenerPhrases: [String] = [
 "how are you", "how are you doing", "how have you been",
 "what s up", "whats up"
 ]

 private static let referentialFollowupExactTexts: Set<String> = [
 "explain more clearly", "explain that", "say more", "go on",
 "continue", "what do you mean", "why", "more detail",
 "clarify", "clarify that", "expand", "elaborate"
 ]

 private static let referentialFollowupPhrases: [String] = [
 "explain more clearly", "explain that", "say more", "go on",
 "what do you mean", "more detail", "clarify that",
 "can you clarify", "can you explain that", "expand on that",
 "elaborate on that"
 ]

 internal init() {}

 internal func analyze(messages: [RelayMessage]) -> TurnAnalysis? {
 guard let lastUserIndex = lastNonMetaUserIndex(in: messages),
 let latestUserText = Self.userText(from: messages[lastUserIndex]),
 !latestUserText.isEmpty else {
 return nil
 }

 let normalizedLatestText = Self.normalizedComparisonText(latestUserText)
 let previousContext = previousTurnContext(in: messages, before: lastUserIndex)
 let classification = classify(
 latestUserText,
 normalizedLatestText: normalizedLatestText,
 previousContext: previousContext
 )
 let salientTerms = Self.salientTerms(in: latestUserText)
 let visibleFactTexts = visibleFactTexts(
 in: messages,
 before: lastUserIndex,
 for: classification
 )

 let effectiveClassification = resolvedClassification(
 baseClassification: classification,
 visibleFactTexts: visibleFactTexts
 )

 return TurnAnalysis(
 latestUserText: latestUserText,
 normalizedLatestText: normalizedLatestText,
 classification: effectiveClassification,
 salientTerms: salientTerms,
 recentTailStrategy: recentTailStrategy(
 for: effectiveClassification,
 visibleFactTexts: visibleFactTexts
 ),
 visibleFactTexts: visibleFactTexts,
 responseDirective: responseDirective(
 for: effectiveClassification,
 latestUserText: latestUserText,
 normalizedLatestText: normalizedLatestText,
 visibleFactTexts: visibleFactTexts
 )
 )
 }

 internal func recentConversationTail(
 for analysis: TurnAnalysis,
 in messages: [RelayMessage]
 ) -> [(role: String, text: String)] {
 guard let lastUserIndex = lastNonMetaUserIndex(in: messages), lastUserIndex > 0 else {
 return []
 }

 switch analysis.recentTailStrategy {
 case .none:
 return []

 case .immediateRecent(let maxTurns):
 var selected: [ConversationTurn] = []
 for i in stride(from: lastUserIndex - 1, through: 0, by: -1) {
 guard let turn = Self.conversationalTurn(from: messages[i]) else { continue }
 selected.append(turn)
 if selected.count == maxTurns { break }
 }
 return selected.reversed().map { ($0.role, $0.text) }

 case .lexicalOverlap(let maxTurns):
 var selected: [ConversationTurn] = []
 for i in stride(from: lastUserIndex - 1, through: 0, by: -1) {
 guard let turn = Self.conversationalTurn(from: messages[i]) else { continue }
 guard !analysis.salientTerms.isEmpty else { break }
 if !analysis.salientTerms.intersection(turn.salientTerms).isEmpty {
 selected.append(turn)
 if selected.count == maxTurns { break }
 }
 }
 return selected.reversed().map { ($0.role, $0.text) }
 }
 }

 internal static func userText(from message: RelayMessage) -> String? {
 guard case .user(let content) = message else { return nil }
 let joined = content.blocks.compactMap { block -> String? in
 if case .text(let text) = block { return text }
 return nil
 }
 .joined(separator: " ")
 let stripped = stripSystemReminders(from: joined)
 .trimmingCharacters(in: .whitespacesAndNewlines)
 return stripped.isEmpty ? nil : stripped
 }

 private static func stripSystemReminders(from text: String) -> String {
 guard let regex = systemReminderRegex else { return text }
 let range = NSRange(text.startIndex..., in: text)
 let stripped = regex.stringByReplacingMatches(
 in: text,
 options: [],
 range: range,
 withTemplate: ""
 )
 return stripped.replacingOccurrences(
 of: #"\s+"#,
 with: " ",
 options: .regularExpression
 )
 }

 private static func conversationalTurn(from message: RelayMessage) -> ConversationTurn? {
 switch message {
 case .user(let content):
 guard !content.isMeta, let text = userText(from: message) else { return nil }
 return ConversationTurn(role: "user", text: text, salientTerms: salientTerms(in: text))

 case .assistant(let content):
 let joined = content.blocks.compactMap { block -> String? in
 if case .text(let text) = block { return text }
 return nil
 }
 .joined(separator: " ")
 .trimmingCharacters(in: .whitespacesAndNewlines)
 guard !joined.isEmpty else { return nil }
 return ConversationTurn(role: "assistant", text: joined, salientTerms: salientTerms(in: joined))

 case .toolResult(let results):
 let joined = results
 .map(\.output)
 .joined(separator: "\n")
 .trimmingCharacters(in: .whitespacesAndNewlines)
 guard !joined.isEmpty else { return nil }
 return ConversationTurn(role: "tool", text: joined, salientTerms: salientTerms(in: joined))
 }
 }

 private func classify(
 _ latestUserText: String,
 normalizedLatestText: String,
 previousContext: PreviousTurnContext
 ) -> TurnClassification {
 if isSocialOpener(normalizedLatestText) {
 return .socialOpener
 }
 if isReferentialFollowup(normalizedLatestText, previousContext: previousContext) {
 return .referentialFollowup
 }
 if isRepairCue(normalizedLatestText) {
 return .repairCue
 }
 if isTransportCheck(normalizedLatestText) {
 return .transportCheck
 }
 if isToolFollowup(normalizedLatestText, previousContext: previousContext) {
 return .toolFollowup
 }
 if isFactRecall(normalizedLatestText) {
 return .factRecallUnknown
 }
 if isDeclarativeFact(normalizedLatestText) {
 return .declarativeFact
 }
 if isQuestion(latestUserText, normalizedLatestText: normalizedLatestText) {
 return .question
 }
 return .ambiguous
 }

 private func resolvedClassification(
 baseClassification: TurnClassification,
 visibleFactTexts: [String]
 ) -> TurnClassification {
 guard baseClassification == .factRecallUnknown else { return baseClassification }
 return visibleFactTexts.isEmpty ? .factRecallUnknown : .factRecallKnown
 }

 private func recentTailStrategy(
 for classification: TurnClassification,
 visibleFactTexts: [String]
 ) -> TurnRecentTailStrategy {
 switch classification {
 case .question:
 return .lexicalOverlap(maxTurns: 3)
 case .declarativeFact, .transportCheck, .socialOpener:
 return .none
 case .factRecallKnown, .factRecallUnknown:
 return visibleFactTexts.isEmpty ? .none : .immediateRecent(maxTurns: 3)
 case .repairCue, .toolFollowup:
 return .immediateRecent(maxTurns: 4)
 case .referentialFollowup:
 return .immediateRecent(maxTurns: 2)
 case .ambiguous:
 return .immediateRecent(maxTurns: 2)
 }
 }

 private func responseDirective(
 for classification: TurnClassification,
 latestUserText: String,
 normalizedLatestText: String,
 visibleFactTexts: [String]
 ) -> String {
 switch classification {
 case .question:
 return "answer the latest question directly"
 case .declarativeFact:
 return "acknowledge the fact directly in one sentence"
 case .factRecallUnknown:
 return "say you do not know the requested fact yet in one or two sentences and invite the user to tell you"
 case .factRecallKnown:
 return "answer by restating the visible fact directly in one sentence"
 case .repairCue:
 return "correct the missed point using the immediately previous relevant turn"
 case .socialOpener:
 return "reply warmly in two to four natural sentences and optionally ask one light follow-up"
 case .referentialFollowup:
 return "clarify or expand the immediately previous answer using the recent conversation"
 case .transportCheck:
 return "answer briefly about message receipt or processing"
 case .toolFollowup:
 return "treat the message as continuation of the immediately previous result or action"
 case .ambiguous:
 return "ask one focused clarifying question"
 }
 }

 private func visibleFactTexts(
 in messages: [RelayMessage],
 before lastUserIndex: Int,
 for classification: TurnClassification
 ) -> [String] {
 guard classification == .factRecallKnown
 || classification == .factRecallUnknown
 || classification == .repairCue else {
 return []
 }

 var facts: [String] = []
 for i in stride(from: lastUserIndex - 1, through: 0, by: -1) {
 guard let text = Self.userText(from: messages[i]) else { continue }
 let priorClassification = classify(
 text,
 normalizedLatestText: Self.normalizedComparisonText(text),
 previousContext: .user
 )
 guard priorClassification == .declarativeFact else { continue }
 facts.append(text)
 if facts.count == 2 { break }
 }
 return facts.reversed()
 }

 private func previousTurnContext(
 in messages: [RelayMessage],
 before lastUserIndex: Int
 ) -> PreviousTurnContext {
 guard lastUserIndex > 0 else { return .none }
 for i in stride(from: lastUserIndex - 1, through: 0, by: -1) {
 switch messages[i] {
 case .user(let content):
 if !content.isMeta, Self.userText(from: messages[i]) != nil {
 return .user
 }
 case .assistant:
 if Self.conversationalTurn(from: messages[i]) != nil {
 return .assistant
 }
 case .toolResult:
 if Self.conversationalTurn(from: messages[i]) != nil {
 return .tool
 }
 }
 }
 return .none
 }

 private func lastNonMetaUserIndex(in messages: [RelayMessage]) -> Int? {
 for i in stride(from: messages.count - 1, through: 0, by: -1) {
 if case .user(let content) = messages[i], !content.isMeta {
 return i
 }
 }
 return nil
 }

 private func isRepairCue(_ normalizedText: String) -> Bool {
 if Self.repairCuePhrases.contains(where: { normalizedText.contains($0) }) {
 return true
 }
 if Self.repairCueExactTexts.contains(normalizedText) {
 return true
 }
 let noSpace = normalizedText.replacingOccurrences(of: " ", with: "")
 return Self.repairCueExactTexts.contains(noSpace)
 }

 private func isTransportCheck(_ normalizedText: String) -> Bool {
 Self.transportCheckPhrases.contains(where: { normalizedText.contains($0) })
 }

 private func isToolFollowup(
 _ normalizedText: String,
 previousContext: PreviousTurnContext
 ) -> Bool {
 guard previousContext == .assistant || previousContext == .tool else { return false }
 return Self.toolFollowupExactTexts.contains(normalizedText)
 }

 private func isFactRecall(_ normalizedText: String) -> Bool {
 Self.factRecallPhrases.contains(where: { normalizedText.contains($0) })
 }

 private func isDeclarativeFact(_ normalizedText: String) -> Bool {
 Self.declarativeFactPhrases.contains(where: { normalizedText.contains($0) })
 }

 private func isQuestion(_ rawText: String, normalizedLatestText: String) -> Bool {
 if rawText.contains("?") {
 return true
 }
 return Self.questionLeadPhrases.contains(where: { normalizedLatestText.hasPrefix($0) })
 }

 private func isSocialOpener(_ normalizedText: String) -> Bool {
 if Self.socialOpenerExactTexts.contains(normalizedText) {
 return true
 }
 let wordCount = normalizedText.split(separator: " ").count
 if wordCount > 6 {
 return false
 }
 if Self.socialOpenerPhrases.contains(where: { normalizedText.contains($0) }) {
 return true
 }
 guard let firstWord = normalizedText.split(separator: " ").first else {
 return false
 }
 return wordCount <= 2 && ["hi", "hello", "hey", "yo", "sup", "hiya"].contains(String(firstWord))
 }

 private func isReferentialFollowup(
 _ normalizedText: String,
 previousContext: PreviousTurnContext
 ) -> Bool {
 guard previousContext == .assistant || previousContext == .tool else {
 return false
 }
 if Self.referentialFollowupExactTexts.contains(normalizedText) {
 return true
 }
 let wordCount = normalizedText.split(separator: " ").count
 guard wordCount <= 6 else {
 return false
 }
 return Self.referentialFollowupPhrases.contains(where: { normalizedText.contains($0) })
 }

 internal static func salientTerms(in text: String) -> Set<String> {
 Set(
 text.lowercased()
 .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
 .map(String.init())
 .filter { $0.count >= 3 }
 .filter { !salientStopwords.contains($0) }
 )
 }

 internal static func normalizedComparisonText(_ text: String) -> String {
 text.lowercased()
 .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
 .trimmingCharacters(in: .whitespacesAndNewlines)
 }

 // MARK: - Tool-intent detection (DEBUG.md F2)

 /// Detects whether the latest user text is an explicit tool-intent request
 /// (search / find / read in a file / worklog / memory / etc.). Used by
 /// `ContextBuilder.selectToolMode` to lift `HostExecutionOptions.toolMode`
 /// to `.required` on tool-intent turns so primary Gemma is forced into
 /// tool emission instead of a plain-text fallback. Conservative AND gate:
 /// requires a verb match AND a noun match from the lists below.
 internal static func isToolIntent(latestUserText: String) -> Bool {
 let normalized = normalizedComparisonText(latestUserText)
 let words = Set(normalized.split(separator: " ").map(String.init()))

 // fast path for time/date queries.
 // S2 T21 device log: `What time is it?` produced text-only
 // response from Gemma instead of calling `get_current_datetime`,
 // because the verb+noun gate below didn't match (`time` is not
 // a tool-intent noun; `is` / `it` aren't tool-intent verbs).
 // These phrases bind unambiguously to the `get_current_datetime`
 // tool, so elevate `toolMode` to `.required` without requiring
 // the verb+noun composition.
 if toolIntentTimeDatePhrases.contains(where: { normalized.contains($0) }) {
 return true
 }

 let hasVerb = !words.isDisjoint(with: toolIntentVerbWords)
 || toolIntentVerbPhrases.contains(where: { normalized.contains($0) })
 guard hasVerb else { return false }

 return !words.isDisjoint(with: toolIntentNouns)
 }

 // MARK: - Web-search intent (Round-6 Search via Gemini grounding)

 /// Detects whether the latest user text is an explicit web-search
 /// intent ("search the web", "what's the latest news", "current
 /// price of X"). Used by `AgentRunner.streamCompletion` to pre-route
 /// the turn to cloud, AND by `GeminiClient.generate` to add the
 /// `googleSearch` grounding tool to the request body so Gemini does
 /// the search natively (no Brave API key required).
 ///
 /// Conservative — only fires on EXPLICIT search intent. Generic
 /// curiosity ("tell me about X") still answers from training data
 /// unless the user asks for fresh / online info explicitly. Phrase
 /// matching uses substring containment on the same normalized
 /// (lowercased, punctuation-stripped) text used by the rest of the
 /// classifier.
 internal static func isWebSearchIntent(latestUserText: String) -> Bool {
 let normalized = normalizedComparisonText(latestUserText)
 return webSearchIntentPhrases.contains { normalized.contains($0) }
 }

 private static let webSearchIntentPhrases: [String] = [
 // Explicit search verbs
 "search the web",
 "search online",
 "search for",
 "google for",
 "google it",
 "google this",
 "look up online",
 "look it up online",
 "look on the web",
 "find online",
 "find on the web",
 // Recency / news
 "what s the latest",
 "whats the latest",
 "what is the latest",
 "what is happening with",
 "what s happening with",
 "news about",
 "recent news",
 "latest news",
 "current price",
 "current rate",
 "current value",
 "current score",
 "stock price",
 // Real-world facts that change
 "weather in",
 "weather today",
 "who won",
 "who is winning",
 // "According to the web" hints
 "according to the web",
 "according to google",
 "on the internet",
 "on google"
 ]

 /// Time/date phrases that bind to `get_current_datetime`. Matching
 /// uses substring containment on the normalized (lowercased,
 /// punctuation-stripped) text, so `What's the time?` and
 /// `whats the time` both match `"the time"`-anchored phrases.
 private static let toolIntentTimeDatePhrases: [String] = [
 "what time is it",
 "what s the time",
 "what is the time",
 "tell me the time",
 "current time",
 "the current time",
 "check the time",
 "what s today s date",
 "what is today s date",
 "what s the date",
 "what is the date",
 "today s date",
 "current date",
 "the current date",
 "check the date",
 "what day is it",
 "what s the day"
 ]

 private static let toolIntentVerbWords: Set<String> = [
 "search", "searching",
 "find", "finding", "found",
 "grep",
 "read", "reading",
 "open", "opens", "opened",
 "list", "lists", "listed",
 "fetch", "fetching", "fetched",
 "retrieve", "retrieves", "retrieved",
 "summarize", "summarise", "summarizes", "summarises",
 "extract", "extracts", "extracted",
 ]

 private static let toolIntentVerbPhrases: [String] = [
 "show me",
 "look for",
 "look up",
 "looking for",
 "pull up",
 ]

 private static let toolIntentNouns: Set<String> = [
 "file", "files",
 "folder", "folders",
 "directory", "directories",
 "worklog", "worklogs",
 "note", "notes",
 "entry", "entries",
 "document", "documents", "doc", "docs",
 "memory", "memories",
 "attachment", "attachments",
 "disk",
 "log", "logs",
 "journal", "journals",
 ]

 // MARK: - Long-context conversation-summarization detection

 /// Detects whether the latest user text asks Gemma to summarize or
 /// recall the current conversation. These prompts fail on Gemma-4-E2B
 /// past ~15 messages because the model's long-context attention
 /// collapses — device log Turn 13 (25 msgs) produced
 /// `"So far, we have had a very brief conversation..."` as output
 /// despite the conversation being long.
 ///
 /// Used by `AgentRunner.streamCompletion` to pre-route the turn to
 /// Gemini before Gemma is invoked. No message-count gate — every
 /// match pre-routes regardless of history length, because matches
 /// are rare and Gemma's quality on even short summarize-our-chat
 /// prompts is inconsistent.
 ///
 /// Conservative AND gate (same shape as `isToolIntent`):
 /// recall-phrase OR (verb-match AND scope-match)
 internal static func isConversationSummarizationRequest(
 latestUserText: String
 ) -> Bool {
 let normalized = normalizedComparisonText(latestUserText)
 let words = Set(normalized.split(separator: " ").map(String.init()))

 // Fast path: explicit recall phrases whose NP already binds
 // conversation-scope. No verb-match required — the phrase is
 // self-scoping.
 if conversationRecallPhrases.contains(where: { normalized.contains($0) }) {
 return true
 }

 let hasVerb = !words.isDisjoint(with: conversationSummarizeVerbWords)
 || conversationSummarizeVerbPhrases.contains(where: { normalized.contains($0) })
 guard hasVerb else { return false }

 return !words.isDisjoint(with: conversationScopeNouns)
 || conversationScopePhrases.contains(where: { normalized.contains($0) })
 }

 private static let conversationSummarizeVerbWords: Set<String> = [
 "summarize", "summarise", "summarizes", "summarises",
 "recap", "recaps",
 "review", "reviews"
 ]

 private static let conversationSummarizeVerbPhrases: [String] = [
 "sum up", "sums up", "summing up"
 ]

 /// Nouns that bind scope to "the current conversation". `"article"`,
 /// `"notes"`, `"text"` are intentionally excluded — those are legit
 /// on-device summarization targets.
 private static let conversationScopeNouns: Set<String> = [
 "conversation", "conversations",
 "chat", "chats",
 "discussion", "discussions",
 "dialogue", "dialogues",
 "exchange", "exchanges"
 ]

 /// Multi-word scope markers where a single noun isn't enough.
 /// `"so far"` is the key disambiguator — it binds any verb to the
 /// conversation timeline regardless of noun.
 private static let conversationScopePhrases: [String] = [
 "our messages", "this session", "so far"
 ]

 /// Natural-language recall phrases with conversation-scope built in.
 /// Do not require a separate verb-match; the phrase IS the signal.
 private static let conversationRecallPhrases: [String] = [
 "what have we discussed",
 "what have we talked about",
 "what did we discuss",
 "what did we talk about",
 "what did we just discuss",
 "remind me what we discussed",
 "remind me what we talked about",
 "remind me of our conversation",
 "what have we covered"
 ]
}
