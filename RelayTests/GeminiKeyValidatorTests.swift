import XCTest
@testable import Relay

final class GeminiKeyValidatorTests: XCTestCase {

 func test_validate_acceptsGreetingLikeResponse() async throws {
 let validator = GeminiKeyValidator(probe: { _ in "Hello there" })

 try await validator.validate("demo-key")
 }

 func test_validate_rejectsEmptyResponse() async {
 let validator = GeminiKeyValidator(probe: { _ in " " })

 do {
 try await validator.validate("demo-key")
 XCTFail("Expected empty response validation failure")
 } catch let error as GeminiKeyValidator.ValidationError {
 XCTAssertEqual(error, .emptyResponse)
 } catch {
 XCTFail("Unexpected error: \(error)")
 }
 }

 func test_validate_rejectsNonGreetingResponse() async {
 let validator = GeminiKeyValidator(probe: { _ in "42" })

 do {
 try await validator.validate("demo-key")
 XCTFail("Expected invalid greeting failure")
 } catch let error as GeminiKeyValidator.ValidationError {
 XCTAssertEqual(error, .invalidGreeting("42"))
 } catch {
 XCTFail("Unexpected error: \(error)")
 }
 }

 func test_validate_propagatesUnauthorizedFailure() async {
 let validator = GeminiKeyValidator(probe: { _ in
 throw GeminiClient.GeminiError.httpError(401, "unauthorized")
 })

 do {
 try await validator.validate("demo-key")
 XCTFail("Expected HTTP failure")
 } catch let error as GeminiClient.GeminiError {
 guard case .httpError(let code, let body) = error else {
 return XCTFail("Unexpected Gemini error: \(error)")
 }
 XCTAssertEqual(code, 401)
 XCTAssertEqual(body, "unauthorized")
 } catch {
 XCTFail("Unexpected error: \(error)")
 }
 }

 func test_validate_propagatesNetworkFailure() async {
 let validator = GeminiKeyValidator(probe: { _ in
 throw GeminiClient.GeminiError.networkError("timeout")
 })

 do {
 try await validator.validate("demo-key")
 XCTFail("Expected network failure")
 } catch let error as GeminiClient.GeminiError {
 guard case .networkError(let message) = error else {
 return XCTFail("Unexpected Gemini error: \(error)")
 }
 XCTAssertEqual(message, "timeout")
 } catch {
 XCTFail("Unexpected error: \(error)")
 }
 }
}
