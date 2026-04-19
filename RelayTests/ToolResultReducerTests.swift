import XCTest
@testable import Relay

/// tests for `ToolResultReducer`. All pure-function; no
/// actors, no mocks, no I/O. Locks:
/// short output passes through unchanged;
/// oversized output replaced with preview + truncation footer;
/// `toolUseId` / `isError` / `metadata` preserved on reduction;
/// determinism (`reduce(reduce(x)) == reduce(x)` up to byte-equal);
/// non-`.toolResult` messages untouched;
/// mixed history reduces only oversized blocks.
final class ToolResultReducerTests: XCTestCase {

 // MARK: - Helpers

 private func toolResult(
 id: String = "call_1",
 output: String,
 isError: Bool = false,
 metadata: [String: String]? = nil
 ) -> RelayMessage {
 .toolResult([
 ToolResultBlock(
 toolUseId: id,
 output: output,
 isError: isError,
 metadata: metadata
 )
 ])
 }

 private func onlyBlock(_ message: RelayMessage) -> ToolResultBlock? {
 guard case .toolResult(let blocks) = message else { return nil }
 return blocks.first
 }

 // MARK: - (a) short output passes through unchanged

 func test_reduce_shortOutput_passesThroughUnchanged() {
 let reducer = ToolResultReducer(budgetBytes: 8_192)
 let small = toolResult(output: "hello")
 let reduced = reducer.reduce([small])
 XCTAssertEqual(reduced.count, 1)
 XCTAssertEqual(onlyBlock(reduced[0])?.output, "hello")
 }

 // MARK: - (b) oversized output replaced with stub (preview + footer)

 func test_reduce_oversizedOutput_replacedWithPreviewAndFooter() {
 let reducer = ToolResultReducer(budgetBytes: 512)
 // Build a 2000-byte payload of known content.
 let big = String(repeating: "x", count: 2_000)
 let message = toolResult(output: big)

 guard let reducedBlock = onlyBlock(reducer.reduce([message])[0]) else {
 return XCTFail("expected a toolResult block")
 }

 // Bounded to the budget.
 XCTAssertLessThanOrEqual(reducedBlock.output.utf8.count, 512)
 // Starts with "x…x" preview.
 XCTAssertTrue(reducedBlock.output.hasPrefix("x"))
 // Carries the truncation footer with the original byte count.
 XCTAssertTrue(reducedBlock.output.contains("original 2000 bytes"))
 XCTAssertTrue(reducedBlock.output.contains("Tool output truncated"))
 }

 // MARK: - (c) toolUseId / isError / metadata preserved

 func test_reduce_preservesToolUseIdIsErrorAndMetadata() {
 let reducer = ToolResultReducer(budgetBytes: 64)
 let big = String(repeating: "y", count: 1_000)
 let message = toolResult(
 id: "call_abc",
 output: big,
 isError: true,
 metadata: ["source": "web_search", "took_ms": "150"]
 )

 guard let reducedBlock = onlyBlock(reducer.reduce([message])[0]) else {
 return XCTFail("expected a toolResult block")
 }

 XCTAssertEqual(reducedBlock.toolUseId, "call_abc", "pairing id must survive reduction")
 XCTAssertTrue(reducedBlock.isError, "isError flag must survive reduction")
 XCTAssertEqual(reducedBlock.metadata?["source"], "web_search")
 XCTAssertEqual(reducedBlock.metadata?["took_ms"], "150")
 }

 // MARK: - (d) determinism

 func test_reduce_isDeterministicAcrossRepeatedCalls() {
 let reducer = ToolResultReducer(budgetBytes: 256)
 let big = String(repeating: "z", count: 5_000)
 let message = toolResult(output: big)

 let first = reducer.reduce([message])
 let second = reducer.reduce([message])
 let double = reducer.reduce(reducer.reduce([message]))

 XCTAssertEqual(onlyBlock(first[0])?.output, onlyBlock(second[0])?.output, "same inputs → same output")
 XCTAssertEqual(onlyBlock(first[0])?.output, onlyBlock(double[0])?.output, "idempotent (reduce(reduce(x)) == reduce(x) for already-bounded output)")
 }

 // MARK: - (e) non-toolResult messages untouched

 func test_reduce_nonToolResultMessages_passThrough() {
 let reducer = ToolResultReducer(budgetBytes: 64)
 let user: RelayMessage = .user(UserContent(blocks: [.text("hi")]))
 let assistantText: RelayMessage = .assistant(AssistantContent(blocks: [.text("hello back")]))
 let assistantToolUse: RelayMessage = .assistant(AssistantContent(blocks: [
 .toolUse(ToolUseBlock(id: "t1", name: "echo", inputJson: "{}"))
 ]))

 let reduced = reducer.reduce([user, assistantText, assistantToolUse])
 XCTAssertEqual(reduced.count, 3)

 // Case + content check per element (RelayMessage is not Equatable).
 guard case .user(let u) = reduced[0] else { return XCTFail("expected user at 0") }
 guard case .text(let userText) = u.blocks.first else { return XCTFail("expected text block") }
 XCTAssertEqual(userText, "hi")

 guard case .assistant(let a1) = reduced[1] else { return XCTFail("expected assistant at 1") }
 guard case .text(let a1Text) = a1.blocks.first else { return XCTFail("expected text block") }
 XCTAssertEqual(a1Text, "hello back")

 guard case .assistant(let a2) = reduced[2] else { return XCTFail("expected assistant at 2") }
 guard case .toolUse(let use) = a2.blocks.first else { return XCTFail("expected toolUse block") }
 XCTAssertEqual(use.id, "t1")
 XCTAssertEqual(use.name, "echo")
 }

 // MARK: - (f) mixed history — only oversized reduced

 func test_reduce_mixedHistory_reducesOnlyOversized() {
 let reducer = ToolResultReducer(budgetBytes: 64)
 let short = toolResult(id: "t1", output: "ok")
 let big = toolResult(id: "t2", output: String(repeating: "b", count: 1_000))

 let reduced = reducer.reduce([short, big])
 XCTAssertEqual(reduced.count, 2)

 XCTAssertEqual(onlyBlock(reduced[0])?.output, "ok", "short output untouched")

 guard let bigReduced = onlyBlock(reduced[1]) else {
 return XCTFail("expected reduced big block")
 }
 XCTAssertLessThanOrEqual(bigReduced.output.utf8.count, 64)
 XCTAssertEqual(bigReduced.toolUseId, "t2")
 XCTAssertTrue(bigReduced.output.contains("original 1000 bytes"))
 }

 // MARK: - tiny custom budgets still clamp hard

 func test_reduce_tinyBudget_clampsFinalOutputToBudget() {
 let reducer = ToolResultReducer(budgetBytes: 12)
 let big = toolResult(output: String(repeating: "q", count: 256))

 guard let reducedBlock = onlyBlock(reducer.reduce([big])[0]) else {
 return XCTFail("expected a toolResult block")
 }

 XCTAssertLessThanOrEqual(reducedBlock.output.utf8.count, 12)
 }
}
