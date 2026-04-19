import Foundation

/// Bundles the native embedded Gmail tools. Returns an empty tool list when
/// the user has not signed in — the agent never sees tools it cannot use.
public struct GmailToolProvider: ToolProvider, Sendable {
 public var providerName: String { "gmail" }
 public var source: ToolSource { .gmail }

 public init() {}

 public func tools(for context: ToolCallContext) async -> [any RelayTool] {
 let gmail = context.services.gmail
 guard await gmail().isSignedIn() else { return [] }
 return [
 GmailSearchTool(),
 GmailReadMessageTool(),
 GmailReadThreadTool(),
 GmailDraftReplyTool(),
 GmailSendTool(),
 ]
 }
}
