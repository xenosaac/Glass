import Foundation

/// Conversation message in Relay's history.
///
/// Designed to map cleanly to Anthropic-style content blocks while remaining
/// compatible with Cactus's `function_calls` JSON output. The
/// `CactusModelHost` adapter ( Module A) translates Cactus's native
/// format into these blocks before handing them to `AgentCore`.
///
/// Lives in `Shared/` because it is the only message type used by both the
/// iPhone target and the future Watch companion (which serializes/deserializes
/// these over `WCSession`).
public enum RelayMessage: Sendable, Codable, Equatable {
 case user(UserContent)
 case assistant(AssistantContent)
 case toolResult([ToolResultBlock])
}

// MARK: - User

public struct UserContent: Sendable, Codable, Equatable {
 public let blocks: [UserBlock]
 /// When true, this message is sent to the model but hidden from the chat
 /// transcript (e.g. `<system-reminder>` injections, tool_result wrappers).
 /// Defaults false; existing Codable transcripts decode as non-meta.
 public let isMeta: Bool

 public init(blocks: [UserBlock], isMeta: Bool = false) {
 self.blocks = blocks
 self.isMeta = isMeta
 }

 private enum CodingKeys: String, CodingKey { case blocks, isMeta }

 public init(from decoder: Decoder) throws {
 let c = try decoder.container(keyedBy: CodingKeys.self)
 self.blocks = try c.decode([UserBlock].self, forKey: .blocks)
 self.isMeta = try c.decodeIfPresent(Bool.self, forKey: .isMeta) ?? false
 }
}

public struct ImportedFileRef: Sendable, Codable, Equatable {
 public let attachmentID: UUID
 public let displayName: String
 public let contentTypeIdentifier: String

 public init(attachmentID: UUID, displayName: String, contentTypeIdentifier: String) {
 self.attachmentID = attachmentID
 self.displayName = displayName
 self.contentTypeIdentifier = contentTypeIdentifier
 }
}

public enum UserBlock: Sendable, Codable, Equatable {
 case text(String)
 /// Local audio file URL — fed to Gemma-4 native audio encoder.
 case audioRef(URL)
 case image(URL)
 case fileRef(ImportedFileRef)
}

// MARK: - Assistant

public struct AssistantContent: Sendable, Codable, Equatable {
 public let blocks: [AssistantBlock]
 public init(blocks: [AssistantBlock]) { self.blocks = blocks }
}

public enum AssistantBlock: Sendable, Codable, Equatable {
 case text(String)
 case toolUse(ToolUseBlock)
}

public struct ToolUseBlock: Sendable, Codable, Equatable {
 public let id: String
 public let name: String
 /// JSON-encoded arguments string from the model.
 public let inputJson: String

 public init(id: String, name: String, inputJson: String) {
 self.id = id
 self.name = name
 self.inputJson = inputJson
 }
}

// MARK: - Tool result

public struct ToolResultBlock: Sendable, Codable, Equatable {
 public let toolUseId: String
 public let output: String
 public let isError: Bool
 /// Metadata for UI presentation (e.g., email/SMS compose data).
 public let metadata: [String: String]?

 public init(toolUseId: String, output: String, isError: Bool, metadata: [String: String]? = nil) {
 self.toolUseId = toolUseId
 self.output = output
 self.isError = isError
 self.metadata = metadata
 }
}
