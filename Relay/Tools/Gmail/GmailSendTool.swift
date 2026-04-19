import Foundation

/// Send an email via Gmail. Destructive — requires user confirmation.
public struct GmailSendTool: RelayTool, Sendable {
 public var name: String { "gmail_send" }
 public var description: String {
 "Send an email via Gmail. Supports replies via `in_reply_to_message_id`, which wires proper threading headers. Prefer gmail_draft_reply for replies you want to review first."
 }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "to": {
 "type": "string",
 "description": "Recipient email address(es). Comma-separated for multiple."
 },
 "subject": {
 "type": "string",
 "description": "Subject line"
 },
 "body": {
 "type": "string",
 "description": "Plain-text body"
 },
 "in_reply_to_message_id": {
 "type": "string",
 "description": "Optional: message ID being replied to. When set, threading headers and Gmail threadId are preserved."
 }
 },
 "required": ["to", "subject", "body"]
 }
 """#)
 }
 public var isConcurrencySafe: Bool { false }
 public var isReadOnly: Bool { false }
 public var isDestructive: Bool { true }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]

 guard let to = params["to"] as? String, !to.isEmpty else {
 return ToolResult(toolUseId: "", output: "Error: 'to' is required", isError: true)
 }
 guard let subject = params["subject"] as? String else {
 return ToolResult(toolUseId: "", output: "Error: 'subject' is required", isError: true)
 }
 guard let body = params["body"] as? String, !body.isEmpty else {
 return ToolResult(toolUseId: "", output: "Error: 'body' is required", isError: true)
 }
 let inReplyTo = params["in_reply_to_message_id"] as? String

 let gmail = context.services.gmail
 guard await gmail().isSignedIn() else {
 return ToolResult(
 toolUseId: "",
 output: "Error: Not signed in to Gmail. Connect your account in Settings → Gmail.",
 isError: true
 )
 }

 do {
 let id = try await gmail().sendMessage(
 to: to,
 subject: subject,
 body: body,
 inReplyToMessageID: inReplyTo
 )
 return ToolResult(toolUseId: "", output: "Sent message (ID: \(id)) to \(to).")
 } catch {
 return ToolResult(toolUseId: "", output: "Error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]
 let to = (params["to"] as? String) ?? "(unknown)"
 let subject = (params["subject"] as? String) ?? ""
 // 2 : when subject is missing/empty, use a
 // user-facing action sentence instead of the developer-doc class
 // description, which leaked into the approval sheet text.
 let summary = subject.isEmpty ? "Send an email." : "Send an email with subject \"\(subject)\"."
 return .destructive(
 domain: .gmail,
 operation: .send,
 summary: summary,
 targetDescription: to
 )
 }
}
