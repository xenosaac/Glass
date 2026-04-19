import Foundation

/// Create a Gmail draft reply to an existing message.
/// Not destructive — the draft sits in the user's drafts folder until they
/// send it manually or via `gmail_send`.
public struct GmailDraftReplyTool: RelayTool, Sendable {
 public var name: String { "gmail_draft_reply" }
 public var description: String {
 "Create a draft reply to an existing Gmail message. Preserves threading (In-Reply-To, References, Subject: Re:). Does NOT send — user reviews in Gmail or sends later."
 }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "message_id": {
 "type": "string",
 "description": "ID of the message being replied to (from gmail_search)"
 },
 "body": {
 "type": "string",
 "description": "Plain-text body of the reply"
 }
 },
 "required": ["message_id", "body"]
 }
 """#)
 }
 public var isConcurrencySafe: Bool { false }
 public var isReadOnly: Bool { false }
 public var isDestructive: Bool { false }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]

 guard let messageId = params["message_id"] as? String, !messageId.isEmpty else {
 return ToolResult(toolUseId: "", output: "Error: 'message_id' is required", isError: true)
 }
 guard let body = params["body"] as? String, !body.isEmpty else {
 return ToolResult(toolUseId: "", output: "Error: 'body' is required", isError: true)
 }

 let gmail = context.services.gmail
 guard await gmail().isSignedIn() else {
 return ToolResult(
 toolUseId: "",
 output: "Error: Not signed in to Gmail. Connect your account in Settings → Gmail.",
 isError: true
 )
 }

 do {
 let draftId = try await gmail().createDraftReply(sourceMessageID: messageId, body: body)
 return ToolResult(
 toolUseId: "",
 output: "Created draft reply (draft ID: \(draftId)). Review in Gmail's Drafts folder before sending."
 )
 } catch {
 return ToolResult(toolUseId: "", output: "Error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .reversible(
 domain: .gmail,
 operation: .create,
 summary: description
 )
 }
}
