import Foundation

/// lightweight pre-dispatch validator for tool
/// input JSON. Mirrors CC's Zod-parse-before-call pattern
/// (`services/tools/toolOrchestration.ts:97`) without pulling in a full
/// JSON Schema runtime: we only check that the input parses as a JSON
/// object AND that the schema's `required` fields are present. This
/// catches the most common model failures (malformed JSON, missing
/// key) without needing a full Draft-7 validator.
///
/// The dispatcher consults this BEFORE calling `tool.call(...)`. On
/// failure, the synthetic error sent back to the model includes the
/// schema JSON, so the model can correct its input and retry instead
/// of looping on the same bad shape.
public enum ToolInputValidator {
 public enum Error: Swift.Error, Equatable, Sendable {
 case malformedJSON
 case missingRequiredField(String)

 public var userFacingMessage: String {
 switch self {
 case .malformedJSON:
 return "Tool input is not valid JSON."
 case .missingRequiredField(let field):
 return "Required field '\(field)' is missing from tool input."
 }
 }
 }

 public static func validate(
 input: ToolInput,
 against schema: ToolInputSchema
 ) -> Result<Void, Error> {
 // Empty input is treated as `{}` — tools like get_current_datetime
 // have schemas with no required fields, so this should pass.
 let bytes = input.json.isEmpty ? Data("{}".utf8) : input.json
 guard let inputObj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
 return .failure(.malformedJSON)
 }

 // If the schema itself is unparseable (shouldn't happen; hand-
 // authored strings in the tool files), skip validation rather
 // than reject every call.
 guard let schemaObj = try? JSONSerialization.jsonObject(
 with: Data(schema.json.utf8)
 ) as? [String: Any] else {
 return .success(())
 }

 if let required = schemaObj["required"] as? [String] {
 for field in required where inputObj[field] == nil {
 return .failure(.missingRequiredField(field))
 }
 }
 return .success(())
 }
}
