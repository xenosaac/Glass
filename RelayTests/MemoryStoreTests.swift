import XCTest
@testable import Relay

/// tests for `MemoryStore` covering Layer 2 (cold-start stub
/// initialization on first read) and Layer 3 (writeback error log with
/// rotation). Existing `MemoryStore` behavior is exercised through
/// `MemoryWritebackCoordinatorTests`, `PromptCompilerTests`, and the
/// integration-level harness; this file targets the new public/internal
/// surface added
final class MemoryStoreTests: XCTestCase {

 // MARK: - Helpers

 /// Returns both the root URL and a store rooted there so tests can
 /// inspect on-disk state directly without scanning the parent temp
 /// directory (which would race with other tests using the same
 /// `RelayMemoryStoreTests-*` prefix under parallel test execution).
 private func makeTempStoreAndRoot() -> (store: MemoryStore, root: URL) {
 let tmp = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayMemoryStoreTests-\(UUID().uuidString)", isDirectory: true)
 try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
 return (MemoryStore(root: tmp), tmp)
 }

 // MARK: - Layer 2: cold-start stub on loadIndex(initializeIfMissing:)

 func test_loadIndex_returnsNilForMissingFile_whenInitializeIfMissingFalse() async {
 // Backward-compat regression guard. Existing callers (Settings UI,
 // tests) rely on `nil-on-missing` to detect cold-start state.
 let (store, _) = makeTempStoreAndRoot
 let result = await store.loadIndex
 XCTAssertNil(result, "expected nil when file missing and not opted-in to init")
 }

 func test_loadIndex_writesAndReturnsStub_whenInitializeIfMissingTrue() async {
 // .2 cold-start fix: production callers (ContextBuilder) pass
 // initializeIfMissing: true so the system prompt always carries
 // the full memory section, not the 30-token minimal stub.
 let (store, root) = makeTempStoreAndRoot
 let result = await store.loadIndex(initializeIfMissing: true)
 XCTAssertNotNil(result, "expected stub content on cold start")
 XCTAssertTrue(
 result?.contains("no facts saved yet") ?? false,
 "expected stub text; got \(result ?? "nil")"
 )
 // Verify the stub was actually written to disk, not just returned.
 let indexURL = root.appendingPathComponent("MEMORY.md")
 XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
 }

 func test_loadIndex_doesNotOverwriteExistingIndex() async throws {
 // Idempotency: stub must NOT clobber a real index. Caller can
 // pass initializeIfMissing: true on every read without risk.
 let (store, _) = makeTempStoreAndRoot
 try await store.appendToIndex("- [Existing](user_existing.md) — real entry")
 let firstRead = await store.loadIndex(initializeIfMissing: true)
 XCTAssertTrue(firstRead?.contains("Existing") ?? false)

 let secondRead = await store.loadIndex(initializeIfMissing: true)
 XCTAssertTrue(secondRead?.contains("Existing") ?? false)
 XCTAssertFalse(
 secondRead?.contains("no facts saved yet") ?? true,
 "stub must not overwrite a real index on subsequent reads"
 )
 }

 func test_loadIndex_subsequentCallsReturnSameStub() async {
 // After init writes the stub once, subsequent reads should NOT
 // re-write it (file already exists → init branch skipped). Verify
 // content stability.
 let (store, _) = makeTempStoreAndRoot
 let first = await store.loadIndex(initializeIfMissing: true)
 let second = await store.loadIndex(initializeIfMissing: true)
 XCTAssertEqual(first, second, "stub must be stable across reads")
 }

 // MARK: - Layer 3: appendErrorLog with rotation

 func test_appendErrorLog_writesLineToHiddenLogFile() async throws {
 let (store, root) = makeTempStoreAndRoot
 await store.appendErrorLog(
 fileName: "user_name.md",
 errorMessage: "MemoryError.invalidPath(\"user_NAME.md\")"
 )

 let logURL = root.appendingPathComponent(MemoryStore.writebackErrorLogName)
 XCTAssertTrue(
 FileManager.default.fileExists(atPath: logURL.path),
 "expected error log file at \(logURL.path)"
 )
 let body = try String(contentsOf: logURL, encoding: .utf8)
 XCTAssertTrue(body.contains("user_name.md"), "expected fileName in log; body=\(body)")
 XCTAssertTrue(body.contains("invalidPath"), "expected error message in log")
 XCTAssertTrue(body.hasPrefix("20"), "expected ISO-8601 timestamp prefix; body=\(body)")
 XCTAssertTrue(body.hasSuffix("\n"), "expected trailing newline")
 }

 func test_appendErrorLog_appendsMultipleLines() async throws {
 let (store, root) = makeTempStoreAndRoot
 await store.appendErrorLog(fileName: "user_a.md", errorMessage: "err A")
 await store.appendErrorLog(fileName: "user_b.md", errorMessage: "err B")

 let logURL = root.appendingPathComponent(MemoryStore.writebackErrorLogName)
 let body = try String(contentsOf: logURL, encoding: .utf8)
 let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
 XCTAssertEqual(lines.count, 2, "expected two lines after two appends")
 XCTAssertTrue(body.contains("user_a.md"))
 XCTAssertTrue(body.contains("user_b.md"))
 }

 func test_appendErrorLog_rotatesAtCap() async throws {
 let (store, root) = makeTempStoreAndRoot
 let cap = MemoryStore.writebackErrorLogMaxLines
 let trim = MemoryStore.writebackErrorLogTrimToLines
 // Append cap+5 entries so rotation triggers exactly once on the
 // (cap+1)-th append.
 for i in 0..<(cap + 5) {
 await store.appendErrorLog(
 fileName: "user_\(i).md",
 errorMessage: "test error \(i)"
 )
 }

 let logURL = root.appendingPathComponent(MemoryStore.writebackErrorLogName)
 let body = try String(contentsOf: logURL, encoding: .utf8)
 let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
 // After overflow, we keep exactly `trim` lines and continue
 // appending. Final line count = trim + (overflow appended after rotation).
 // Overflow after first rotation = (cap + 5) - cap = 5; so total
 // appended after the rotation point is 5; final count is
 // somewhere in [trim, cap]. We assert it's bounded by cap (no
 // unbounded growth) and contains the most recent entry.
 XCTAssertLessThanOrEqual(lines.count, cap, "log must not exceed cap")
 XCTAssertGreaterThanOrEqual(lines.count, trim, "log must keep at least the trim target")
 XCTAssertTrue(body.contains("user_\(cap + 4).md"), "most recent entry must be kept")
 XCTAssertFalse(body.contains("user_0.md"), "earliest entry should be rotated out")
 }

 func test_appendErrorLog_sanitizesNewlinesInInputs() async throws {
 // Defensive — multi-line error messages would corrupt the
 // line-based log format. The sanitizer replaces `\n` with space.
 let (store, root) = makeTempStoreAndRoot
 await store.appendErrorLog(
 fileName: "user_x.md",
 errorMessage: "first line\nsecond line"
 )
 let logURL = root.appendingPathComponent(MemoryStore.writebackErrorLogName)
 let body = try String(contentsOf: logURL, encoding: .utf8)
 let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
 XCTAssertEqual(lines.count, 1, "embedded newlines must not produce multiple log lines")
 XCTAssertTrue(body.contains("first line second line"))
 }
}
