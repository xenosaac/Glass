import Foundation

/// Tool that prepares an email draft for the user to send.
///
/// Returns a payload that signals the UI layer to present MFMailComposeViewController.
/// iOS does not allow sending email silently — user must confirm.
public struct EmailDraftTool: RelayTool, Sendable {
 public var name: String { "email_draft" }
 public var description: String { "Prepare an email draft. Opens the Mail compose screen for the user to review and send. Cannot send silently on iOS." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "to": {
 "type": "array",
 "items": { "type": "string" },
 "description": "Recipient email addresses"
 },
 "cc": {
 "type": "array",
 "items": { "type": "string" },
 "description": "CC recipients (optional)"
 },
 "bcc": {
 "type": "array",
 "items": { "type": "string" },
 "description": "BCC recipients (optional)"
 },
 "subject": {
 "type": "string",
 "description": "Email subject"
 },
 "body": {
 "type": "string",
 "description": "Email body text"
 },
 "is_html": {
 "type": "boolean",
 "description": "Whether body is HTML (default: false)"
 }
 },
 "required": ["to", "subject", "body"]
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
 guard let subject = params["subject"] as? String else {
 return ToolResult(toolUseId: "", output: "Error: 'subject' required", isError: true)
 }
 guard let body = params["body"] as? String else {
 return ToolResult(toolUseId: "", output: "Error: 'body' required", isError: true)
 }

 // Build payload for UI layer to present MFMailComposeViewController
 let payload: [String: Any] = [
 "type": "email",
 "to": to,
 "cc": params["cc"] as? [String] ?? [],
 "bcc": params["bcc"] as? [String] ?? [],
 "subject": subject,
 "body": body,
 "is_html": params["is_html"] as? Bool ?? false
 ]

 let payloadData = try JSONSerialization.data(withJSONObject: payload)
 let payloadStr = String(data: payloadData, encoding: .utf8) ?? "{}"

 return ToolResult(
 toolUseId: "",
 output: "Email draft prepared for \(to.joined(separator: ", ")). Subject: \"\(subject)\". Opening Mail compose for user to review and send.",
 metadata: [
 "requiresUIPresentation": "true",
 "uiType": "mailCompose",
 "payload": payloadStr
 ]
 )
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .userMediated(domain: .mailCompose, operation: .compose, summary: description)
 }
}
