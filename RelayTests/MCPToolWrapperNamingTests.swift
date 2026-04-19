import XCTest
@testable import Relay

/// MCP tool-name format migration tests.
/// CC uses double-underscore (`mcp__server__tool`) at
/// `services/mcp/mcpStringUtils.ts:50-51`. Glass previously used
/// single-underscore; this test locks the rename and the legacy
/// resolver that maps old references to the new format.
final class MCPToolWrapperNamingTests: XCTestCase {

 func test_resolveLegacyName_translatesSingleUnderscoreToDouble() {
 let resolved = MCPToolWrapper.resolveLegacyName(
 "mcp_github_create_issue",
 knownServers: ["github"]
 )
 XCTAssertEqual(resolved, "mcp__github__create_issue")
 }

 func test_resolveLegacyName_handlesServerWithUnderscoreInToolName() {
 // Tool name has underscores (e.g., `list_my_issues`); the server
 // name is the authoritative delimiter.
 let resolved = MCPToolWrapper.resolveLegacyName(
 "mcp_github_list_my_issues",
 knownServers: ["github"]
 )
 XCTAssertEqual(resolved, "mcp__github__list_my_issues")
 }

 func test_resolveLegacyName_returnsNilForAlreadyCanonical() {
 XCTAssertNil(MCPToolWrapper.resolveLegacyName(
 "mcp__github__create_issue",
 knownServers: ["github"]
 ))
 }

 func test_resolveLegacyName_returnsNilForNonMCP() {
 XCTAssertNil(MCPToolWrapper.resolveLegacyName(
 "calendar_list_events",
 knownServers: ["github"]
 ))
 }

 func test_resolveLegacyName_returnsNilForUnknownServer() {
 XCTAssertNil(MCPToolWrapper.resolveLegacyName(
 "mcp_unknown_tool_name",
 knownServers: ["github"]
 ))
 }

 // MARK: - R8-S schema sanitization (Canvas → Gemini)

 /// Canvas hosted MCP returned `additionalProperties` nested inside
 /// per-property schemas, which Gemini's function-calling API rejects
 /// with `INVALID_ARGUMENT`. The sanitizer must strip the keyword at
 /// every depth.
 func test_sanitizeForCloudFunctionCalling_removesNestedAdditionalProperties() {
 let input: [String: Any] = [
 "type": "object",
 "properties": [
 "filters": [
 "type": "object",
 "additionalProperties": false,
 "properties": [
 "course_id": [
 "type": "object",
 "additionalProperties": true
 ]
 ]
 ]
 ]
 ]

 let cleaned = MCPToolWrapper.sanitizeForCloudFunctionCalling(input) as? [String: Any]
 XCTAssertNotNil(cleaned)

 let filters = (cleaned?["properties"] as? [String: Any])?["filters"] as? [String: Any]
 XCTAssertNotNil(filters)
 XCTAssertNil(filters?["additionalProperties"], "top-level additionalProperties must be stripped")

 let courseID = (filters?["properties"] as? [String: Any])?["course_id"] as? [String: Any]
 XCTAssertNotNil(courseID)
 XCTAssertNil(courseID?["additionalProperties"], "nested additionalProperties must be stripped")
 }

 /// `required` is the only keyword `ToolInputValidator` enforces at
 /// dispatch time; if the sanitizer ever drops it, every MCP tool
 /// call would silently lose its required-field check.
 func test_sanitizeForCloudFunctionCalling_preservesRequiredAndOrdinaryProperties() {
 let input: [String: Any] = [
 "type": "object",
 "properties": [
 "course_id": ["type": "string", "description": "Canvas course id"],
 "include": ["type": "array", "items": ["type": "string"]]
 ],
 "required": ["course_id"]
 ]

 let cleaned = MCPToolWrapper.sanitizeForCloudFunctionCalling(input) as? [String: Any]
 XCTAssertNotNil(cleaned)
 XCTAssertEqual(cleaned?["type"] as? String, "object")
 XCTAssertEqual(cleaned?["required"] as? [String], ["course_id"])

 let properties = cleaned?["properties"] as? [String: Any]
 let courseID = properties?["course_id"] as? [String: Any]
 XCTAssertEqual(courseID?["type"] as? String, "string")
 XCTAssertEqual(courseID?["description"] as? String, "Canvas course id")

 let include = properties?["include"] as? [String: Any]
 XCTAssertEqual(include?["type"] as? String, "array")
 let items = include?["items"] as? [String: Any]
 XCTAssertEqual(items?["type"] as? String, "string")
 }

 /// The `inputSchema` getter falls back to the raw verbatim JSON when
 /// `JSONSerialization` cannot parse — so a future schema we have
 /// never seen never breaks the existing happy path. This test
 /// exercises the helper directly: passing through a non-dict
 /// primitive must round-trip unchanged.
 func test_sanitizeForCloudFunctionCalling_passesThroughNonDictValuesUnchanged() {
 XCTAssertEqual(MCPToolWrapper.sanitizeForCloudFunctionCalling("plain string") as? String, "plain string")
 XCTAssertEqual(MCPToolWrapper.sanitizeForCloudFunctionCalling(42) as? Int, 42)
 XCTAssertEqual(MCPToolWrapper.sanitizeForCloudFunctionCalling(true) as? Bool, true)

 let array = MCPToolWrapper.sanitizeForCloudFunctionCalling(["a", "b"]) as? [String]
 XCTAssertEqual(array, ["a", "b"])
 }

 // MARK: - R8-T tool-result hardening

 func test_shouldTreatToolCallResultAsError_respectsExplicitServerError() {
 let result = MCPToolCallResult(
 content: [.init(type: "text", text: "Everything exploded")],
 isError: true
 )

 XCTAssertTrue(MCPToolWrapper.shouldTreatToolCallResultAsError(result))
 }

 func test_shouldTreatToolCallResultAsError_infersLeadingErrorTextWhenServerSaysSuccess() {
 let result = MCPToolCallResult(
 content: [.init(type: "text", text: " Error fetching upcoming assignments: Request failed: Remote server 500")],
 isError: false
 )

 XCTAssertTrue(MCPToolWrapper.shouldTreatToolCallResultAsError(result))
 XCTAssertEqual(MCPToolWrapper.inferredErrorPrefix(in: result.content), "error ")
 }

 func test_shouldTreatToolCallResultAsError_doesNotMisclassifyNormalSuccessText() {
 let result = MCPToolCallResult(
 content: [.init(type: "text", text: "Upcoming assignments for this week: Math HW 4, CS Lab 2")],
 isError: false
 )

 XCTAssertFalse(MCPToolWrapper.shouldTreatToolCallResultAsError(result))
 XCTAssertNil(MCPToolWrapper.inferredErrorPrefix(in: result.content))
 }
}
