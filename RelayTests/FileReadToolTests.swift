import XCTest
@testable import Relay

/// 2 — `FileReadTool` rejects binary files via a
/// 512-byte FileHandle peek BEFORE the full read. The handle is now
/// explicitly closed (defer try? handle.close). The behavior contract
/// covered here is "binary content is refused with a clear error" — the
/// FD-close path is exercised on every code path through the binary
/// detection branch.
final class FileReadToolTests: XCTestCase {

 private struct AlwaysAllowBroker: ApprovalBroker, Sendable {
 func evaluate(
 tool: any RelayTool,
 input: ToolInput,
 context: ToolCallContext
 ) async -> ApprovalDecision {
 .allow
 }
 }

 private struct AllowAllFileProvider: FileProviderService {
 func isAuthorized(path: String) async -> Bool { true }
 }

 private static func makeContext() -> ToolCallContext {
 ToolCallContext(
 messages: [],
 session: AgentSession(id: "fileread-test", startedAt: Date),
 approvalBroker: AlwaysAllowBroker,
 progress: { _ in },
 services: DefaultServiceLocator(fileProvider: AllowAllFileProvider)
 )
 }

 func test_fileRead_rejectsBinaryFile_andClosesHandle() async throws {
 let tmpDir = FileManager.default.temporaryDirectory
 let filename = "fileread-binary-\(UUID().uuidString).bin"
 let url = tmpDir.appendingPathComponent(filename)
 // NUL byte in the first 512 bytes triggers binary detection.
 try Data([0xFF, 0x00, 0xFF, 0xFE, 0xFD]).write(to: url)
 defer { try? FileManager.default.removeItem(at: url) }

 let tool = FileReadTool
 let payload = try JSONSerialization.data(withJSONObject: ["file_path": url.path])
 let result = try await tool.call(input: ToolInput(json: payload), context: Self.makeContext)

 XCTAssertTrue(result.isError, "binary file should be refused")
 XCTAssertTrue(
 result.output.hasPrefix("Cannot read binary file:"),
 "expected binary-rejection error, got: \(result.output)"
 )
 }
}
