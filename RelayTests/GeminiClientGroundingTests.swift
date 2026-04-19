import XCTest
@testable import Relay

/// tests for `GeminiClient.formatGroundingFooter`,
/// the citation parser used when Google Search grounding is enabled on
/// a cloud handoff. Tests the parser only — actual HTTP request emission
/// is exercised at integration level via the AgentRunner pre-route tests.
final class GeminiClientGroundingTests: XCTestCase {

 // MARK: - happy path

 func test_formatGroundingFooter_extractsTopWebChunks() {
 let candidate: [String: Any] = [
 "groundingMetadata": [
 "groundingChunks": [
 ["web": ["uri": "https://example.com/yc-w26", "title": "YC W26 batch announcement"]],
 ["web": ["uri": "https://news.example.com/yc", "title": "YC news roundup"]]
 ]
 ]
 ]
 let footer = GeminiClient.formatGroundingFooter(from: candidate)
 XCTAssertNotNil(footer)
 XCTAssertTrue(footer?.contains("**Sources:**") ?? false)
 XCTAssertTrue(footer?.contains("[YC W26 batch announcement](https://example.com/yc-w26)") ?? false)
 XCTAssertTrue(footer?.contains("[YC news roundup](https://news.example.com/yc)") ?? false)
 XCTAssertTrue(footer?.hasPrefix("\n\n---\n") ?? false)
 }

 // MARK: - degraded shapes

 func test_formatGroundingFooter_returnsNilWhenMetadataMissing() {
 let candidate: [String: Any] = [
 "content": ["parts": [["text": "answer text"]]]
 ]
 XCTAssertNil(GeminiClient.formatGroundingFooter(from: candidate))
 }

 func test_formatGroundingFooter_returnsNilWhenChunksEmpty() {
 let candidate: [String: Any] = [
 "groundingMetadata": [
 "groundingChunks": [[String: Any]]
 ]
 ]
 XCTAssertNil(GeminiClient.formatGroundingFooter(from: candidate))
 }

 func test_formatGroundingFooter_skipsMalformedChunksWithMissingUri() {
 // First chunk is invalid (no uri); second is valid. Footer should
 // contain only the valid one, numbered starting at 2 (we keep the
 // original enumerated index from `prefix(5)`).
 let candidate: [String: Any] = [
 "groundingMetadata": [
 "groundingChunks": [
 ["web": ["title": "Bare title with no URL"]],
 ["web": ["uri": "https://valid.example.com", "title": "Valid"]]
 ]
 ]
 ]
 let footer = GeminiClient.formatGroundingFooter(from: candidate)
 XCTAssertNotNil(footer)
 XCTAssertTrue(footer?.contains("https://valid.example.com") ?? false)
 XCTAssertFalse(footer?.contains("Bare title with no URL") ?? true)
 }

 func test_formatGroundingFooter_capsAtFiveSources() {
 var chunks: [[String: Any]] = []
 for i in 1...8 {
 chunks.append(["web": ["uri": "https://source\(i).example.com", "title": "Source \(i)"]])
 }
 let candidate: [String: Any] = [
 "groundingMetadata": ["groundingChunks": chunks]
 ]
 let footer = GeminiClient.formatGroundingFooter(from: candidate)
 XCTAssertNotNil(footer)
 XCTAssertTrue(footer?.contains("Source 5") ?? false, "expected first 5 sources to be present")
 XCTAssertFalse(footer?.contains("Source 6") ?? true, "expected source 6 onward to be capped off")
 XCTAssertFalse(footer?.contains("Source 7") ?? true)
 XCTAssertFalse(footer?.contains("Source 8") ?? true)
 }

 // MARK: - quota-exhausted friendly path

 func test_parseRetryAfterMs_extractsMillisecondsFromBody() {
 // Exact body shape observed on-device:
 let body = #"""
 {
 "error": {
 "code": 429,
 "message": "You exceeded your current quota...\nPlease retry in 841.498321ms.",
 "status": "RESOURCE_EXHAUSTED"
 }
 }
 """#
 let ms = GeminiClient.parseRetryAfterMs(from: body)
 XCTAssertEqual(ms, 841)
 }

 func test_parseRetryAfterMs_returnsNilWhenAbsent() {
 let body = #"{"error": {"code": 500}}"#
 XCTAssertNil(GeminiClient.parseRetryAfterMs(from: body))
 }

 func test_quotaExhaustedError_descriptionIsGlassShaped() {
 let err = GeminiClient.GeminiError.quotaExhausted(retryAfterMs: 12000)
 let desc = err.errorDescription ?? ""
 // Must NOT include raw JSON / HTTP code dump.
 XCTAssertFalse(desc.contains("429"))
 XCTAssertFalse(desc.contains("RESOURCE_EXHAUSTED"))
 XCTAssertFalse(desc.contains("{"))
 // Must include user-friendly hint about quota + recovery.
 XCTAssertTrue(desc.contains("quota"))
 XCTAssertTrue(desc.contains("12s"), "expected retry-after suffix; got: \(desc)")
 // Must NOT start with "Cloud retry error:" — the AgentRunner
 // skip-prefix check relies on the description starting with
 // "Cloud quota exhausted".
 XCTAssertTrue(desc.hasPrefix("Cloud quota exhausted"))
 }

 func test_quotaExhaustedError_descriptionWithoutRetryHintStillFriendly() {
 let err = GeminiClient.GeminiError.quotaExhausted(retryAfterMs: nil)
 let desc = err.errorDescription ?? ""
 XCTAssertTrue(desc.hasPrefix("Cloud quota exhausted"))
 XCTAssertFalse(desc.contains("Try again in"))
 }

 func test_formatGroundingFooter_fallsBackToUriWhenTitleMissing() {
 let candidate: [String: Any] = [
 "groundingMetadata": [
 "groundingChunks": [
 ["web": ["uri": "https://no-title.example.com"]]
 ]
 ]
 ]
 let footer = GeminiClient.formatGroundingFooter(from: candidate)
 XCTAssertNotNil(footer)
 // When title missing, the URI is used as the link text too.
 XCTAssertTrue(
 footer?.contains("[https://no-title.example.com](https://no-title.example.com)") ?? false,
 "expected URI to be used as link text when title missing; got: \(footer ?? "nil")"
 )
 }
}
