import Foundation

/// post-turn bookkeeping coordinator. A thin extraction of the
/// former private `ChatViewModel.persistMemoryForCompletedTurn(...)`
/// method so the writeback path is not buried inside the view-model.
///
/// Two responsibilities:
/// 1. Advance `metadata.lastIndexedMessageCount` to track `messageCount`
/// (the original behavior).
/// 2. deterministic writeback for canonical
/// declarative-fact patterns ("My name is X" / "I work at X" /
/// "My birthday is X"). Runs WITHOUT trusting the model to call
/// `memory_write` — Gemini in cloud handoff often produces a polite
/// acknowledgement instead of the tool call, silently dropping the
/// fact and breaking cross-session memory. Belt + suspenders to the
/// `toolConfig.mode = "ANY"` change in `GeminiClient`.
///
/// Real model-driven memory writes (topic-file updates, retrieval-side
/// indexing) still go through the `memory_write` tool. This coordinator
/// only fires for a narrow set of high-signal patterns to avoid noise.
public struct MemoryWritebackCoordinator: Sendable {
 public let sessionIndex: SessionIndex
 public let memoryStore: MemoryStore?

 public init(sessionIndex: SessionIndex, memoryStore: MemoryStore? = nil) {
 self.sessionIndex = sessionIndex
 self.memoryStore = memoryStore
 }

 /// Run post-turn bookkeeping after a completed user → assistant
 /// exchange. Called from `ChatViewModel.send` once `.done` has
 /// fired and the assistant message has been persisted to
 /// `SessionStore`.
 ///
 /// Semantics:
 /// Advance `metadata.lastIndexedMessageCount`.
 /// If `memoryStore` is configured AND the user message matches
 /// a canonical declarative-fact pattern, write a topic file
 /// and append a one-line MEMORY.md index entry.
 ///
 /// No-op when the session's metadata is missing (covers the edge
 /// case where the session was deleted between send and writeback).
 public func afterTurn(
 sessionId: String,
 userMessage: RelayMessage,
 assistantMessage: RelayMessage,
 wasVoiceTurn: Bool
 ) async {
 if let store = memoryStore,
 let userText = Self.firstUserText(in: userMessage),
 let extracted = Self.extractCanonicalFact(from: userText) {
 do {
 try await store.writeFile(extracted.fileName, content: extracted.content)
 try await store.appendToIndex(extracted.indexLine)
 print("[Memory] writeback wrote \(extracted.fileName) (\(extracted.indexLine))")
 } catch {
 // also log to disk so Isaac
 // has a durable signal beyond Xcode console. The console
 // log goes away with each app launch; the on-disk log
 // survives and can be inspected via Files.app or Xcode
 // device file browser.
 print("[Memory] writeback failed for \(extracted.fileName): \(error.localizedDescription)")
 await store.appendErrorLog(
 fileName: extracted.fileName,
 errorMessage: error.localizedDescription
 )
 }
 }

 guard var metadata = await sessionIndex.get(sessionId) else { return }
 metadata.lastIndexedMessageCount = metadata.messageCount
 try? await sessionIndex.update(metadata)
 }

 // MARK: - Canonical-pattern extraction

 internal struct CanonicalFact: Equatable {
 let fileName: String
 let content: String
 let indexLine: String
 }

 private static func firstUserText(in message: RelayMessage) -> String? {
 guard case .user(let user) = message else { return nil }
 for block in user.blocks {
 if case .text(let t) = block,
 !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
 return t
 }
 }
 return nil
 }

 /// Match a single canonical declarative-fact pattern. Returns the
 /// topic-file write spec, or nil for unmatched / unsupported text.
 /// Patterns are deliberately narrow; expanding to arbitrary
 /// declarative facts would create memory noise.
 internal static func extractCanonicalFact(from text: String) -> CanonicalFact? {
 let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
 guard !trimmed.isEmpty else { return nil }
 let lower = trimmed.lowercased()

 // Pattern 1: name. "My name is X" / "I'm X" / "I am X" with X =
 // 1-3 alpha tokens. Anchored to message start (no leading filler)
 // so casual references like "my friend's name is..." don't fire.
 if let name = matchName(in: lower, original: trimmed) {
 return CanonicalFact(
 fileName: "user_name.md",
 content: nameBody(name: name),
 indexLine: "- [User name](user_name.md) — current user's preferred name"
 )
 }

 // Pattern 2: employer. "I work at X" / "I work for X" — X is the
 // remainder of the sentence (stripped at . / , / ;).
 if let employer = matchEmployer(in: lower, original: trimmed) {
 return CanonicalFact(
 fileName: "user_employer.md",
 content: employerBody(employer: employer),
 indexLine: "- [User employer](user_employer.md) — current user's employer"
 )
 }

 // Pattern 3: birthday. "My birthday is X" / "I was born X".
 if let birthday = matchBirthday(in: lower, original: trimmed) {
 return CanonicalFact(
 fileName: "user_birthday.md",
 content: birthdayBody(birthday: birthday),
 indexLine: "- [User birthday](user_birthday.md) — current user's birthday"
 )
 }

 return nil
 }

 private static func matchName(in lower: String, original: String) -> String? {
 // Permitted prefixes — anchored to message start. Casing matched
 // on lowercased copy; the captured X is reconstructed from the
 // original-case string so "Isaac" stays "Isaac".
 let prefixes: [String] = ["my name is ", "i'm ", "i am "]
 for prefix in prefixes {
 guard lower.hasPrefix(prefix) else { continue }
 let after = original.index(original.startIndex, offsetBy: prefix.count)
 let remainder = String(original[after...])
 // X is the next 1-3 alpha tokens. Stop at any non-alpha char,
 // sentence boundary, or token count.
 return extractAlphaTokens(from: remainder, maxTokens: 3)
 }
 return nil
 }

 private static func matchEmployer(in lower: String, original: String) -> String? {
 let prefixes: [String] = ["i work at ", "i work for "]
 for prefix in prefixes {
 guard lower.hasPrefix(prefix) else { continue }
 let after = original.index(original.startIndex, offsetBy: prefix.count)
 let remainder = String(original[after...])
 return extractUntilSentenceBoundary(remainder)
 }
 return nil
 }

 private static func matchBirthday(in lower: String, original: String) -> String? {
 let prefixes: [String] = ["my birthday is ", "i was born "]
 for prefix in prefixes {
 guard lower.hasPrefix(prefix) else { continue }
 let after = original.index(original.startIndex, offsetBy: prefix.count)
 let remainder = String(original[after...])
 return extractUntilSentenceBoundary(remainder)
 }
 return nil
 }

 /// Stopwords that terminate name-token capture BEFORE being appended.
 /// without this, `"My name is Isaac and
 /// I'm building a voice agent"` was extracted as `"Isaac and I'm"`
 /// (3 alpha tokens) instead of `"Isaac"`. The conjunction "and"
 /// signals the end of the name in essentially every natural
 /// English sentence; same for "but" / "or" / "while" / "who" /
 /// articles / pronouns.
 private static let nameTokenStopwords: Set<String> = [
 "and", "but", "or", "so", "while", "because", "who",
 "i", "i'm", "im", "we", "they", "the", "an", "a"
 ]

 /// Take the next `maxTokens` whitespace-delimited tokens that contain
 /// only letters / apostrophes / hyphens. Stops at the first
 /// non-conforming token (numbers, punctuation, sentence boundary)
 /// or at the first stopword (R6-Mem hotfix). Returns nil if zero
 /// tokens matched.
 private static func extractAlphaTokens(from text: String, maxTokens: Int) -> String? {
 let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
 guard !trimmed.isEmpty else { return nil }
 var tokens: [String] = []
 for raw in trimmed.split(separator: " ", omittingEmptySubsequences: true) {
 let cleaned = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
 guard !cleaned.isEmpty else { break }
 // stop at conjunctions /
 // sentence-glue words BEFORE appending. This catches the
 // common `"My name is Isaac and I'm building..."` shape
 // that previously produced `"Isaac and I'm"` because all
 // three tokens are alpha.
 if nameTokenStopwords.contains(cleaned.lowercased()) { break }
 let isAlpha = cleaned.unicodeScalars.allSatisfy { scalar in
 CharacterSet.letters.contains(scalar)
 || scalar == "'"
 || scalar == "-"
 }
 guard isAlpha else { break }
 tokens.append(cleaned)
 if tokens.count >= maxTokens { break }
 // Stop on sentence-ending punctuation in the original token
 // (e.g. "Isaac.").
 if String(raw).contains(where: { ".,;:!?".contains($0) }) { break }
 }
 guard !tokens.isEmpty else { return nil }
 return tokens.joined(separator: " ")
 }

 private static func extractUntilSentenceBoundary(_ text: String) -> String? {
 let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
 guard !trimmed.isEmpty else { return nil }
 // Cut at first . / , / ; / ! / ? — keep the segment before.
 if let cutIndex = trimmed.firstIndex(where: { ".,;!?".contains($0) }) {
 let before = String(trimmed[..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
 return before.isEmpty ? nil : before
 }
 return trimmed
 }

 // MARK: - Body templates (frontmatter required by MemoryStore validator)

 private static func nameBody(name: String) -> String {
 """
 ---
 name: User name
 description: current user's preferred name
 type: user
 ---

 Name: \(name)
 """
 }

 private static func employerBody(employer: String) -> String {
 """
 ---
 name: User employer
 description: current user's employer
 type: user
 ---

 Employer: \(employer)
 """
 }

 private static func birthdayBody(birthday: String) -> String {
 """
 ---
 name: User birthday
 description: current user's birthday
 type: user
 ---

 Birthday: \(birthday)
 """
 }
}
