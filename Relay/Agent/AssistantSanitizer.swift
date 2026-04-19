import Foundation

/// Strips internal reasoning / channel wrappers from assistant output.
///
/// The on-device Gemma-4-E2B path occasionally emits Harmony-style channel
/// markup (`<|channel>thought`, `<channel|>`, `<|channel|>final`, etc.) plus
/// free-form "Thinking Process:" blocks. None of that is user-facing — it is
/// an artifact of the model's chat template / inference protocol and must
/// never reach the chat UI or the persisted transcript.
///
/// Sanitization is applied at the ChatViewModel boundary:
/// streaming text accumulation (raw → sanitized for display)
/// `.done` message finalization (before persist)
/// historical replay (`convertToDisplay`) as a defensive read-side filter
///
/// If sanitization strips everything, the caller should surface an error
/// instead of rendering the empty result.
enum AssistantSanitizer {

 /// Sanitize a single text fragment. Safe to call on partial streams;
 /// idempotent on already-clean text.
 static func sanitize(_ raw: String) -> String {
 var text = raw

 // 1. Remove full reasoning blocks that open a hidden channel and
 // close it / transition to a final channel. Covers several
 // Harmony / chat-template variants seen in the wild.
 let blockPatterns = [
 // <|channel>thought ... <channel|>
 #"<\|channel>\s*thought[\s\S]*?<channel\|>"#,
 // <|channel>analysis ... <channel|>
 #"<\|channel>\s*analysis[\s\S]*?<channel\|>"#,
 // <|channel|>thought ... <|channel|>final (consumes the "final" tag)
 #"<\|channel\|>\s*(thought|analysis)[\s\S]*?<\|channel\|>\s*final"#,
 // <|start|>thought ... <|end|>
 #"<\|start\|>\s*thought[\s\S]*?<\|end\|>"#,
 // <|thinking|>...<|/thinking|>
 #"<\|thinking\|>[\s\S]*?<\|/thinking\|>"#,
 // <think>...</think> (DeepSeek-R1 style, just in case)
 #"<think>[\s\S]*?</think>"#,
 // <system-reminder>...</system-reminder> (model echoed our meta
 // injection back into its visible output — Gemma-class failure
 // mode for weak instruction following)
 #"<system-reminder>[\s\S]*?</system-reminder>"#,
 ]
 for pattern in blockPatterns {
 if let regex = try? NSRegularExpression(
 pattern: pattern,
 options: [.dotMatchesLineSeparators, .caseInsensitive]
 ) {
 let range = NSRange(text.startIndex..., in: text)
 text = regex.stringByReplacingMatches(
 in: text, options: [], range: range, withTemplate: ""
 )
 }
 }

 // 2. Strip any stray channel / meta tokens that remained (e.g. when
 // the stream cut mid-block, or the model emitted an opener
 // without a matching closer).
 let strayTokens = [
 "<|channel|>final",
 "<|channel|>thought",
 "<|channel|>analysis",
 "<|channel>thought",
 "<|channel>analysis",
 "<|channel|>",
 "<|channel>",
 "<channel|>",
 "<|thought|>",
 "<|analysis|>",
 "<|final|>",
 "<|start|>",
 "<|end|>",
 "<|im_start|>",
 "<|im_end|>",
 "<|/thinking|>",
 "<|thinking|>",
 ]
 for token in strayTokens {
 text = text.replacingOccurrences(
 of: token, with: "", options: .caseInsensitive
 )
 }

 // 3. Strip free-form "Thinking Process:" blocks up to a blank line
 // or end of input.
 if let regex = try? NSRegularExpression(
 pattern: #"(?im)^\s*Thinking Process:\s*[\s\S]*?(?:\n\s*\n|\z)"#,
 options: []
 ) {
 let range = NSRange(text.startIndex..., in: text)
 text = regex.stringByReplacingMatches(
 in: text, options: [], range: range, withTemplate: ""
 )
 }

 text = stripVisibleBoilerplate(from: text)
 return text.trimmingCharacters(in: .whitespacesAndNewlines)
 }

 /// Returns `true` if `sanitize` would strip content from `raw` — used for
 /// DEBUG logging at the `.done` boundary so Isaac can tell at a glance
 /// when the sanitizer had to intervene.
 static func hasInternalMarkup(_ raw: String) -> Bool {
 sanitize(raw) != raw.trimmingCharacters(in: .whitespacesAndNewlines)
 }

 // MARK: - Streaming-safe sanitization

 /// Streaming-safe sanitizer. Unlike `sanitize`, which strips only
 /// **closed** reasoning blocks via regex, this walks the accumulating
 /// raw buffer as a small state machine and suppresses the body of an
 /// **OPEN** hidden block — so partial reasoning text is never visible,
 /// not even for a single frame before the closing marker arrives.
 ///
 /// Rules:
 /// 1. State starts `.visible`. On encountering a known opener
 /// (`<|channel|>thought`, `<think>`, `Thinking Process:`, etc.) state
 /// flips to `.hidden`; the opener itself is consumed, not emitted.
 /// 2. In `.hidden`, text is dropped. State flips back to `.visible`
 /// only on a structural closer (`<channel|>`, `<|channel|>final`,
 /// `</think>`, `<|end|>`, `<|/thinking|>`). No heuristic closers
 /// (no `\n\n`) — better to leave the final answer for `.done` than
 /// to mis-detect an end and leak the rest of the reasoning body.
 /// 3. Trailing bytes that could still grow into a marker are held
 /// back, so half-typed markers like `<|chan` never flicker into
 /// the UI.
 /// 4. Stray meta tokens that survive in visible segments (e.g. an
 /// orphan `<|channel|>` with no partner) are stripped at the end.
 ///
 /// **Worst case**: model opens a hidden block and never emits a
 /// structural closer. This returns only what came BEFORE the opener.
 /// The `.done` path then applies the regex-based `sanitize` to the
 /// complete RelayMessage (which also handles free-form `Thinking
 /// Process:` blocks that end at blank lines) and overwrites the
 /// streaming bubble — matching the user spec's explicit allowance that
 /// "The UI may show no streaming text for a while, then show the final
 /// answer once safe."
 ///
 /// Stateless and monotonic: calling with a longer prefix always
 /// produces a superset of the shorter call's output (once the hold-back
 /// tail resolves).
 static func sanitizeStreaming(_ raw: String) -> String {
 var output = ""
 var cursor = raw.startIndex
 var isHidden = false

 while cursor < raw.endIndex {
 if isHidden {
 if let hit = earliestMatch(
 in: raw, from: cursor, candidates: streamingClosers
 ) {
 cursor = hit.upperBound
 isHidden = false
 } else {
 // No closer yet — stay hidden, drop rest of buffer.
 break
 }
 } else {
 if let hit = earliestMatch(
 in: raw, from: cursor, candidates: streamingOpeners
 ) {
 output += raw[cursor..<hit.lowerBound]
 cursor = hit.upperBound
 isHidden = true
 } else {
 // No opener in remaining buffer. Hold any trailing
 // bytes that could still grow into a marker so we
 // don't flash a partial.
 let tail = raw[cursor..<raw.endIndex]
 let hold = trailingPrefixLength(
 of: tail,
 candidates: streamingOpeners
 + streamingClosers
 + streamingStrayTokens
 )
 let emitEnd = raw.index(raw.endIndex, offsetBy: -hold)
 if emitEnd > cursor {
 output += raw[cursor..<emitEnd]
 }
 break
 }
 }
 }

 // Sweep stray meta tokens that survived inside visible segments.
 // These fire when the model emits an ambiguous token (`<|channel|>`)
 // that wasn't extended into an opener or a closer — e.g. a chat
 // template burp — and slipped through the scanner.
 for token in streamingStrayTokens {
 output = output.replacingOccurrences(
 of: token, with: "", options: .caseInsensitive
 )
 }

 output = stripVisibleBoilerplate(from: output)
 return output.trimmingCharacters(in: .whitespacesAndNewlines)
 }

 // Markers that flip visible → hidden. Kept ordered only for readability;
 // the scanner picks the earliest occurrence regardless of list order.
 private static let streamingOpeners: [String] = [
 "<|channel|>thought",
 "<|channel|>analysis",
 "<|channel>thought",
 "<|channel>analysis",
 "<|start|>thought",
 "<|start|>analysis",
 "<|thinking|>",
 "<think>",
 "Thinking Process:",
 // Model echoed our meta-injection tag back into visible output.
 "<system-reminder>",
 ]

 // Structural markers that flip hidden → visible. Intentionally strict —
 // no heuristic closers like `\n\n` — so we never mistake a blank line
 // inside a reasoning block for the end of it.
 //
 // added asymmetric-closer aliases. Isaac's device log Turn
 // 9 showed the model emitting `<system-reminder>You have asked...</system_prompt>`
 // an opener-to-closer mismatch (`</system_prompt>` instead of
 // `</system-reminder>`). Without a matching closer the scanner stays
 // "hidden" for the rest of the response and the finalization regex
 // only strips the opener at `.done` time, leaving a bubble flicker.
 // These extra closers let the stream-time scanner recover immediately.
 private static let streamingClosers: [String] = [
 "<|channel|>final",
 "<channel|>",
 "<|/thinking|>",
 "</think>",
 "<|end|>",
 "</system-reminder>",
 "</system_prompt>",
 "</system>"
 ]

 // Meta tokens that should never appear in user-facing text. Swept out of
 // the visible output after the state-machine pass. Also feed the tail
 // hold-back check so a half-typed stray is not flashed before it's
 // recognized as stray.
 private static let streamingStrayTokens: [String] = [
 "<|channel|>",
 "<|channel>",
 "<channel|>",
 "<|thought|>",
 "<|analysis|>",
 "<|final|>",
 "<|start|>",
 "<|end|>",
 "<|im_start|>",
 "<|im_end|>",
 "<|/thinking|>",
 "<|thinking|>",
 ]

 private static let visibleBoilerplateLinePatterns: [String] = [
 // post-device-rerun fix: added "(?: today)?" to catch the
 // "today" variant that Gemini emits naturally and that was leaking
 // into ambient history, plus a symmetric "how can i assist..." line
 // pattern to mirror the existing "how can i help..." one.
 #"(?im)^\s*(?:i am ready\.\s*)?what can i do for you(?: today)?\??\s*$"#,
 #"(?im)^\s*how can i help(?: you)?(?: today)?\??\s*$"#,
 #"(?im)^\s*how can i assist(?: you)?(?: today)?\??\s*$"#,
 #"(?im)^\s*(?:#+\s*)?(?:reasoning|analysis|thought process)\s*:?\s*$"#,
 #"(?ims)^\s*how can i help you next\?\s*(?:\n\s*\d+\..*)+$"#,
 ]

 private static let visibleBoilerplateInlinePrefixes: [String] = [
 #"(?i)^\s*(?:#+\s*)?(?:reasoning|analysis|thought process)\s*:\s*"#,
 ]

 private static let visibleBoilerplateTailPatterns: [String] = [
 // same fix as above on the tail side. Without "(?: today)?"
 // Gemini's trailing "What can I do for you today?" survived stripping
 // and polluted Gemma's next-turn ambient history.
 #"(?i)(?:\s|^)(?:i am ready\.\s*)?what can i do for you(?: today)?\?\s*$"#,
 #"(?i)(?:\s|^)how can i help(?: you)?(?: today)?\?\s*$"#,
 #"(?i)(?:\s|^)how can i assist(?: you)?(?: today)?\?\s*$"#,
 ]

 /// Earliest occurrence of any candidate at or after `cursor`. Case
 /// insensitive to match the existing regex sanitizer's behavior.
 private static func earliestMatch(
 in raw: String,
 from cursor: String.Index,
 candidates: [String]
 ) -> Range<String.Index>? {
 var earliest: Range<String.Index>?
 for candidate in candidates {
 if let range = raw.range(
 of: candidate,
 options: [.caseInsensitive],
 range: cursor..<raw.endIndex
 ) {
 if earliest == nil || range.lowerBound < earliest!.lowerBound {
 earliest = range
 }
 }
 }
 return earliest
 }

 /// Length of the longest *strict* prefix of any candidate that equals
 /// the suffix of `tail`. "Strict" = shorter than the full candidate —
 /// exact matches are handled by `earliestMatch`; this call only covers
 /// the "could still grow into a marker" case.
 private static func trailingPrefixLength(
 of tail: Substring,
 candidates: [String]
 ) -> Int {
 let str = String(tail).lowercased()
 var best = 0
 for candidate in candidates {
 let lowered = candidate.lowercased()
 let upper = min(str.count, lowered.count - 1)
 if upper < 1 { continue }
 // Walk prefix lengths largest-first so we can short-circuit the
 // moment we find a match for this candidate.
 for prefixLen in stride(from: upper, through: 1, by: -1) {
 let prefix = String(lowered.prefix(prefixLen))
 if str.hasSuffix(prefix) {
 best = max(best, prefixLen)
 break
 }
 }
 }
 return best
 }

 private static func stripVisibleBoilerplate(from text: String) -> String {
 let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
 guard !trimmed.isEmpty else { return trimmed }

 var candidate = trimmed
 for pattern in visibleBoilerplateInlinePrefixes {
 guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
 let range = NSRange(candidate.startIndex..., in: candidate)
 candidate = regex.stringByReplacingMatches(
 in: candidate,
 options: [],
 range: range,
 withTemplate: ""
 )
 }

 for pattern in visibleBoilerplateLinePatterns {
 guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
 let range = NSRange(candidate.startIndex..., in: candidate)
 candidate = regex.stringByReplacingMatches(
 in: candidate,
 options: [],
 range: range,
 withTemplate: ""
 )
 }

 for pattern in visibleBoilerplateTailPatterns {
 guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
 let range = NSRange(candidate.startIndex..., in: candidate)
 candidate = regex.stringByReplacingMatches(
 in: candidate,
 options: [],
 range: range,
 withTemplate: ""
 )
 }

 if let regex = try? NSRegularExpression(
 pattern: #"(?ims)\n+\s*how can i help you next\?\s*(?:are you looking to:)?\s*(?:\n\s*\d+\..*)+$"#
 ) {
 let range = NSRange(candidate.startIndex..., in: candidate)
 candidate = regex.stringByReplacingMatches(
 in: candidate,
 options: [],
 range: range,
 withTemplate: ""
 )
 }

 if let regex = try? NSRegularExpression(pattern: #"\n\s*\n\s*\n+"#) {
 let range = NSRange(candidate.startIndex..., in: candidate)
 candidate = regex.stringByReplacingMatches(
 in: candidate,
 options: [],
 range: range,
 withTemplate: "\n\n"
 )
 }

 candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
 return candidate
 }
}
