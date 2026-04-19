import Foundation

/// Tool that prepares an SMS message for the user to send.
///
/// Returns a payload that signals the UI layer to present MFMessageComposeViewController.
/// iOS does not allow sending SMS silently — user must confirm.
public struct SMSSendTool: RelayTool, Sendable {
 public var name: String { "sms_send" }
 public var description: String { "Prepare an SMS message. Opens the Messages compose screen for the user to review and send. Cannot send silently on iOS." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "to": {
 "type": "array",
 "items": { "type": "string" },
 "description": "Recipient phone numbers"
 },
 "body": {
 "type": "string",
 "description": "Message text"
 }
 },
 "required": ["to", "body"]
 }
 """#)
 }
 public var isConcurrencySafe: Bool { true }
 public var isReadOnly: Bool { false }
 public var isDestructive: Bool { false }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]

 guard let to = params["to"] as? [String], !to.isEmpty else {
 return ToolResult(toolUseId: "", output: "Error: 'to' recipients required", isError: true)
 }
 guard let body = params["body"] as? String else {
 return ToolResult(toolUseId: "", output: "Error: 'body' required", isError: true)
 }

 // Build payload for UI layer to present MFMessageComposeViewController
 let payload: [String: Any] = [
 "type": "sms",
 "recipients": to,
 "body": body
 ]

 let payloadData = try JSONSerialization.data(withJSONObject: payload)
 let payloadStr = String(data: payloadData, encoding: .utf8) ?? "{}"

 return ToolResult(
 toolUseId: "",
 output: "SMS prepared for \(to.joined(separator: ", ")). Message: \"\(body.prefix(50))...\". Opening Messages for user to review and send.",
 metadata: [
 "requiresUIPresentation": "true",
 "uiType": "messageCompose",
 "payload": payloadStr
 ]
 )
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .userMediated(domain: .messagesCompose, operation: .compose, summary: description)
 }
}
