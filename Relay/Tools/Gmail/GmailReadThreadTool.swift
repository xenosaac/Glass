import Foundation

/// Read all messages in a Gmail thread.
public struct GmailReadThreadTool: RelayTool, Sendable {
 public var name: String { "gmail_read_thread" }
 public var description: String {
 "Read all messages in a Gmail thread by thread ID. Returns each message's headers and body in chronological order."
 }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "thread_id": {
 "type": "string",
 "description": "Gmail thread ID (from gmail_search or gmail_read_message)"
 }
 },
 "required": ["thread_id"]
 }
 """#)
 }
 public var isConcurrencySafe: Bool { true }
 public var isReadOnly: Bool { true }
 public var isDestructive: Bool { false }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]

 guard let threadId = params["thread_id"] as? String, !threadId.isEmpty else {
 return ToolResult(toolUseId: "", output: "Error: 'thread_id' is required", isError: true)
 }

 let gmail = context.services.gmail
 guard await gmail.isSignedIn else {
 return ToolResult(
 toolUseId: "",
 output: "Error: Not signed in to Gmail. Connect your account in Settings → Gmail.",
 isError: true
 )
 }

 do {
 let thread = try await gmail.threadFull(id: threadId)
 var lines = ["Thread \(thread.id) — \(thread.messages.count) message(s)"]
 for (i, m) in thread.messages.enumerated() {
 lines.append("")
 lines.append("--- Message \(i + 1)/\(thread.messages.count) (\(m.id)) ---")
 lines.append("From: \(m.from)")
 lines.append("To: \(m.to)")
 lines.append("Subject: \(m.subject)")
 lines.append("Date: \(m.date)")
 lines.append("")
 lines.append(m.bodyText.isEmpty ? m.snippet : m.bodyText)
 }
 return ToolResult(toolUseId: "", output: lines.joined(separator: "\n"))
 } catch {
 return ToolResult(toolUseId: "", output: "Error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .gmail, operation: .read, summary: description)
 }
}
