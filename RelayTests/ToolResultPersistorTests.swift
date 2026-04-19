import XCTest
@testable import Relay

/// boundary-layer tests.
final class ToolResultPersistorTests: XCTestCase {

 func test_persistor_underCapPassesThrough() {
 let out = ToolResultPersistor.persistIfOversized(
 toolName: "test_tool",
 toolUseId: "under-\(UUID().uuidString)",
 sessionId: "sess-\(UUID().uuidString)",
 output: "short output",
 maxResultSizeChars: 50_000
 )
 XCTAssertEqual(out, "short output")
 XCTAssertFalse(out.contains("<persisted-output>"))
 }

 func test_persistor_overCapWritesPreviewAndFile() throws {
 let sessionId = "sess-\(UUID().uuidString)"
 let toolUseId = "call-\(UUID().uuidString)"
 let big = String(repeating: "A", count: 5_000)
 let out = ToolResultPersistor.persistIfOversized(
 toolName: "test_tool",
 toolUseId: toolUseId,
 sessionId: sessionId,
 output: big,
 maxResultSizeChars: 1_000
 )

 XCTAssertTrue(out.hasPrefix("<persisted-output>"))
 XCTAssertTrue(out.contains("Output too large"))
 XCTAssertTrue(out.contains(toolUseId))
 XCTAssertTrue(out.hasSuffix("</persisted-output>"))
 XCTAssertLessThan(
 out.count, big.count,
 "wrapper must be shorter than the full output"
 )

 // File must exist at the wrapped path.
 let expectedURL = MemoryStore.defaultRoot
 .appendingPathComponent("tool-results", isDirectory: true)
 .appendingPathComponent(sessionId, isDirectory: true)
 .appendingPathComponent("\(toolUseId).txt")
 XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))

 let diskContent = try String(contentsOf: expectedURL, encoding: .utf8)
 XCTAssertEqual(diskContent, big)

 // Cleanup
 try? FileManager.default.removeItem(at: expectedURL)
 }

 func test_persistor_existingFileNotRewritten_eexistPattern() throws {
 let sessionId = "sess-\(UUID().uuidString)"
 let toolUseId = "call-\(UUID().uuidString)"
 let first = String(repeating: "A", count: 3_000)
 _ = ToolResultPersistor.persistIfOversized(
 toolName: "t", toolUseId: toolUseId, sessionId: sessionId,
 output: first, maxResultSizeChars: 500
 )

 // Call again with DIFFERENT content — CC's EEXIST-skip means
 // the second call should NOT overwrite the first file.
 let second = String(repeating: "B", count: 3_000)
 _ = ToolResultPersistor.persistIfOversized(
 toolName: "t", toolUseId: toolUseId, sessionId: sessionId,
 output: second, maxResultSizeChars: 500
 )

 let url = MemoryStore.defaultRoot
 .appendingPathComponent("tool-results", isDirectory: true)
 .appendingPathComponent(sessionId, isDirectory: true)
 .appendingPathComponent("\(toolUseId).txt")
 let disk = try String(contentsOf: url, encoding: .utf8)
 XCTAssertEqual(disk, first, "first persistence wins; EEXIST-skip preserves it")
 try? FileManager.default.removeItem(at: url)
 }

 func test_enforceAggregateBudget_underBudgetPassesThrough() {
 let outs: [(toolName: String, toolUseId: String, output: String)] = [
 ("t1", "u1", String(repeating: "A", count: 1_000)),
 ("t2", "u2", String(repeating: "B", count: 1_000))
 ]
 let bounded = ToolResultPersistor.enforceAggregateBudget(
 outputs: outs,
 sessionId: "sess-\(UUID().uuidString)"
 )
 XCTAssertEqual(bounded[0], outs[0].output)
 XCTAssertEqual(bounded[1], outs[1].output)
 }

 func test_enforceAggregateBudget_evictsLargestFirst() {
 let sessionId = "sess-\(UUID().uuidString)"
 // 3 tools, total > 200K: 150K + 80K + 30K = 260K
 let outs: [(toolName: String, toolUseId: String, output: String)] = [
 ("small", "us", String(repeating: "A", count: 30_000)),
 ("medium", "um", String(repeating: "B", count: 80_000)),
 ("large", "ul", String(repeating: "C", count: 150_000))
 ]
 let bounded = ToolResultPersistor.enforceAggregateBudget(
 outputs: outs,
 sessionId: sessionId
 )
 // Largest (index 2) must have been persisted first. Smallest
 // (index 0) stays intact.
 XCTAssertTrue(bounded[2].hasPrefix("<persisted-output>"))
 XCTAssertEqual(bounded[0], outs[0].output, "smallest untouched")

 // Cleanup
 let dir = MemoryStore.defaultRoot
 .appendingPathComponent("tool-results", isDirectory: true)
 .appendingPathComponent(sessionId, isDirectory: true)
 try? FileManager.default.removeItem(at: dir)
 }
}
