import XCTest
@testable import Relay

final class ToolRegistryCatalogTests: XCTestCase {

 /// Minimal in-tree `ToolProvider` that relies on the default `.other`
 /// source, to verify the default-impl branch of `ToolProvider.source`.
 private struct DefaultSourceStubProvider: ToolProvider, Sendable {
 var providerName: String { "stub" }

 struct StubTool: RelayTool {
 var name: String { "stub_tool" }
 var description: String { "Stub" }
 var inputSchema: ToolInputSchema { ToolInputSchema(json: #"{"type":"object","properties":{}}"#) }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 ToolResult(toolUseId: "", output: "stub")
 }
 }

 func tools(for context: ToolCallContext) async -> [any RelayTool] {
 [StubTool]
 }
 }

 private func makeContext() -> ToolCallContext {
 ToolCallContext(
 messages: [],
 session: AgentSession(id: "catalog", startedAt: Date),
 approvalBroker: DefaultApprovalBroker,
 progress: { _ in },
 services: DefaultServiceLocator
 )
 }

 private func makeRegistry() async -> ToolRegistry {
 let registry = ToolRegistry
 await registry.register(BuiltinToolProvider)
 await registry.register(FileToolProvider)
 await registry.register(AppIntentsToolProvider)
 await registry.register(GmailToolProvider)
 await registry.register(MCPToolProvider)
 await registry.register(DefaultSourceStubProvider)
 return registry
 }

 func test_catalog_tagsSourcePerProvider() async {
 let registry = await makeRegistry
 let entries = await registry.catalog(for: makeContext)

 // Group entries by source to verify provider→source attribution.
 let builtinEntries = entries.filter { $0.source == .builtin }
 let filesEntries = entries.filter { $0.source == .files }
 let appIntentsEntries = entries.filter { $0.source == .appIntents }
 let gmailEntries = entries.filter { $0.source == .gmail }
 let otherEntries = entries.filter { $0.source == .other }
 let mcpEntries = entries.filter { entry in
 // .mcp(server:) has an associated value, so pattern-match the enum.
 if case .mcp = entry.source { return true }
 return false
 }

 XCTAssertFalse(builtinEntries.isEmpty, "BuiltinToolProvider should publish tools tagged .builtin")
 XCTAssertFalse(filesEntries.isEmpty, "FileToolProvider should publish tools tagged .files")
 XCTAssertFalse(appIntentsEntries.isEmpty, "AppIntentsToolProvider should publish tools tagged .appIntents")

 // Gmail + MCP have no tools to publish in a test environment without
 // sign-in / server config, which is fine — their providers still exist.
 XCTAssertTrue(gmailEntries.isEmpty, "GmailToolProvider returns no tools when not signed in")
 XCTAssertTrue(mcpEntries.isEmpty, "MCPToolProvider returns no tools without configured servers")

 // The stub provider uses the default `.other` source.
 XCTAssertEqual(otherEntries.count, 1)
 XCTAssertEqual(otherEntries.first?.name, "stub_tool")
 XCTAssertEqual(otherEntries.first?.source, .other)
 }

 func test_catalog_entriesAreStructurallyComplete() async {
 let registry = await makeRegistry
 let entries = await registry.catalog(for: makeContext)

 XCTAssertFalse(entries.isEmpty, "Catalog should publish at least the stub + builtin providers' tools")

 for entry in entries {
 XCTAssertFalse(entry.name.isEmpty, "Entry with source=\(entry.source) has empty name")
 XCTAssertFalse(entry.title.isEmpty, "Entry '\(entry.name)' has empty title")
 XCTAssertFalse(entry.inputSchema.isEmpty, "Entry '\(entry.name)' has empty inputSchema")
 XCTAssertFalse(entry.policy.summary.isEmpty, "Entry '\(entry.name)' has empty policy.summary")
 }
 }
}
