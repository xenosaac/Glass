import XCTest
@testable import Relay

/// pre-dispatch validator tests.
final class ToolInputValidatorTests: XCTestCase {

 func test_validator_passesValidInput() {
 let schema = ToolInputSchema(json: #"""
 {"type":"object","properties":{"to":{"type":"string"},"body":{"type":"string"}},"required":["to","body"]}
 """#)
 let input = ToolInput(json: Data(#"{"to":"x@y","body":"hi"}"#.utf8))
 if case .failure(let err) = ToolInputValidator.validate(input: input, against: schema) {
 XCTFail("expected success, got \(err)")
 }
 }

 func test_validator_passesEmptyInputForNoRequiredFields() {
 let schema = ToolInputSchema(json: #"""
 {"type":"object","properties":{}}
 """#)
 let input = ToolInput(json: Data) // empty input → treated as `{}`
 if case .failure(let err) = ToolInputValidator.validate(input: input, against: schema) {
 XCTFail("empty input with no required fields should pass; got \(err)")
 }
 }

 func test_validator_failsOnMissingRequiredField() {
 let schema = ToolInputSchema(json: #"""
 {"type":"object","properties":{"to":{"type":"string"}},"required":["to"]}
 """#)
 let input = ToolInput(json: Data("{}".utf8))
 guard case .failure(let err) = ToolInputValidator.validate(input: input, against: schema) else {
 return XCTFail("expected failure")
 }
 XCTAssertEqual(err, .missingRequiredField("to"))
 XCTAssertTrue(err.userFacingMessage.contains("'to'"))
 }

 func test_validator_failsOnMalformedJSON() {
 let schema = ToolInputSchema(json: #"""
 {"type":"object","properties":{}}
 """#)
 let input = ToolInput(json: Data("not json".utf8))
 guard case .failure(let err) = ToolInputValidator.validate(input: input, against: schema) else {
 return XCTFail("expected failure")
 }
 XCTAssertEqual(err, .malformedJSON)
 }

 func test_validator_unparseableSchema_skipsValidation() {
 // If the schema is garbage, we skip validation rather than reject
 // every call; tool-side deserialization will surface real issues.
 let schema = ToolInputSchema(json: "not a schema")
 let input = ToolInput(json: Data(#"{"x":1}"#.utf8))
 if case .failure(let err) = ToolInputValidator.validate(input: input, against: schema) {
 XCTFail("bad schema should not reject valid-JSON input; got \(err)")
 }
 }
}
