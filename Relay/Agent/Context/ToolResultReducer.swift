import Foundation

/// Bounds what the model sees per turn: oversized `ToolResultBlock`
/// outputs are replaced with a preview + truncation footer so a single
/// WebSearch / MCP response cannot crowd out multiple real turns.
///
/// deterministic + stateless. A pure function of
/// `(output, budgetBytes)` — no `ContentReplacementState`, no frozen
/// decisions, no persistence. Determinism across loop iterations /
/// turns / resume is achieved by the function being pure: same bytes
/// in → same bytes out, every time. If the same `ToolResultBlock` is
/// fed through `reduce(...)` twice, both calls return the same reduced
/// block.
///
/// `state.messages` (the authoritative history) and the JSONL
/// transcript retain the ORIGINAL unreduced blocks forever — the
/// reducer produces a reduced VIEW for `ModelRequest.messages` only.
/// Originals are never mutated.
///
/// Invariants (locked by `ToolResultReducerTests`):
/// Output passes through unchanged when `output.utf8.count <= budgetBytes`.
/// Oversized output replaced with `<preview>\n\n<footer>` where the
/// preview is the first `(budgetBytes - footerBytes)` UTF-8 bytes of
/// the original output.
/// `toolUseId`, `isError`, `metadata` preserved on every reduced
/// block — pairing with the assistant's `tool_use` block stays valid
/// so `ensureToolResultPairing` downstream is unaffected.
/// Messages that are not `.toolResult(...)` pass through untouched.
/// Count and position of `.toolResult(...)` messages preserved.
public struct ToolResultReducer: Sendable {

 /// Maximum UTF-8 bytes per `ToolResultBlock.output` in the reduced
 /// view. Originals are unbounded. Default 8 KB chosen to balance
 /// Gemma-4-E2B's small on-device working context (a single 100 KB
 /// WebSearch response would crowd out 2–3 real turns) against
 /// preserving a useful preview for file reads / grep hits / MCP
 /// responses.
 public let budgetBytes: Int

 public init(budgetBytes: Int = 8_192) {
 self.budgetBytes = budgetBytes
 }

 /// Pure reduction. Same `(messages, budgetBytes)` → same output
 /// every call.
 public func reduce(_ messages: [RelayMessage]) -> [RelayMessage] {
 messages.map { message in
 guard case .toolResult(let blocks) = message else {
 return message
 }
 let reducedBlocks = blocks.map { reduce($0) }
 return .toolResult(reducedBlocks)
 }
 }

 // MARK: - Single-block reduction

 /// Reduce one `ToolResultBlock`. Preserves every field except
 /// `output` (replaced with a stub when oversized).
 private func reduce(_ block: ToolResultBlock) -> ToolResultBlock {
 let originalBytes = block.output.utf8.count
 guard originalBytes > budgetBytes else {
 return block
 }

 let footer = Self.footer(originalBytes: originalBytes, keptBytes: nil)
 let footerBytes = footer.utf8.count + 2 // account for the "\n\n" separator
 let previewBudget = max(budgetBytes - footerBytes, 0)
 let preview = Self.prefix(of: block.output, utf8ByteLimit: previewBudget)
 let actualKept = preview.utf8.count
 let finalFooter = Self.footer(originalBytes: originalBytes, keptBytes: actualKept)

 let stub = preview.isEmpty ? finalFooter : "\(preview)\n\n\(finalFooter)"
 // Hard clamp the final stub as well so tiny custom budgets still
 // honor the configured byte cap. The footer may be clipped in
 // that edge case, but the reducer promise ("bounded view") holds.
 let clampedStub = Self.prefix(of: stub, utf8ByteLimit: budgetBytes)

 return ToolResultBlock(
 toolUseId: block.toolUseId,
 output: clampedStub,
 isError: block.isError,
 metadata: block.metadata
 )
 }

 // MARK: - Helpers

 /// Truncation footer. When `keptBytes` is nil, returns the template
 /// used to measure footer length before computing the preview; when
 /// non-nil, returns the final footer embedded in the stub.
 private static func footer(originalBytes: Int, keptBytes: Int?) -> String {
 let kept = keptBytes ?? originalBytes
 return "[Tool output truncated — original \(originalBytes) bytes, showing first \(kept) kept]"
 }

 /// Take the longest prefix of `s` whose UTF-8 byte count is at most
 /// `utf8ByteLimit`. Never splits a Unicode scalar mid-sequence —
 /// walks Character boundaries so the preview is always valid UTF-8.
 private static func prefix(of s: String, utf8ByteLimit: Int) -> String {
 guard utf8ByteLimit > 0 else { return "" }
 if s.utf8.count <= utf8ByteLimit { return s }

 var accumulated = 0
 var end = s.startIndex
 for ch in s {
 let cost = String(ch).utf8.count
 if accumulated + cost > utf8ByteLimit { break }
 accumulated += cost
 end = s.index(after: end)
 }
 return String(s[..<end])
 }
}
