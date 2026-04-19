import Foundation

/// Read the full content of a Gmail message.
public struct GmailReadMessageTool: RelayTool, Sendable {
 public var name: String { "gmail_read_message" }
 public var description: String {
 "Read the headers and body of a Gmail message by ID. Returns parsed headers and best-effort text/plain body."
 }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "message_id": {
 "type": "string",
 "description": "Gmail message ID (from gmail_search)"
 }
 },
 "required": ["message_id"]
 }
 """#)
 }
 public var isConcurrencySafe: Bool { true }
 public var isReadOnly: Bool { true }
 public var isDestructive: Bool { false }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]

 guard let messageId = params["message_id"] as? String, !messageId.isEmpty else {
 return ToolResult(toolUseId: "", output: "Error: 'message_id' is required", isError: true)
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
 let m = try await gmail().messageFull(id: messageId)
 var lines = [
 "Message \(m.id) (thread \(m.threadId))",
 "From: \(m.from)",
 "To: \(m.to)",
 ]
 if let cc = m.cc, !cc.isEmpty { lines.append("Cc: \(cc)") }
 lines.append("Subject: \(m.subject)")
 lines.append("Date: \(m.date)")
 lines.append("")
 lines.append(m.bodyText.isEmpty ? m.snippet : m.bodyText)
 return ToolResult(toolUseId: "", output: lines.joined(separator: "\n"))
 } catch {
 return ToolResult(toolUseId: "", output: "Error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .gmail, operation: .read, summary: description)
 }
}
