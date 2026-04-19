import Foundation

/// Canonical runtime-owned representation of a user-originated turn.
///
/// All ingress paths — composer text, voice, image, file, shortcuts, and
/// programmatic submits — must normalize through this shape before a user
/// message is persisted or sent to the model.
public struct TurnEnvelope: Sendable {
 public let kind: TurnKind
 public let visibleText: String
 public let audioRef: URL?
 public let imageRefs: [URL]
 public let fileRefs: [PendingFileIngestion]
 public let source: TurnSource
 public let submittedAt: Date
 public let prebuiltMessage: RelayMessage?

 public init(
 kind: TurnKind,
 visibleText: String = "",
 audioRef: URL? = nil,
 imageRefs: [URL] = [],
 fileRefs: [PendingFileIngestion] = [],
 source: TurnSource,
 submittedAt: Date = Date(),
 prebuiltMessage: RelayMessage? = nil
 ) {
 self.kind = kind
 self.visibleText = visibleText
 self.audioRef = audioRef
 self.imageRefs = imageRefs
 self.fileRefs = fileRefs
 self.source = source
 self.submittedAt = submittedAt
 self.prebuiltMessage = prebuiltMessage
 }
}

public enum TurnKind: Sendable {
 case text
 case voice
 case image
 case file
 case mixed
 case prebuilt
}

public enum TurnSource: Sendable {
 case composerText
 case composerVoice
 case composerImage
 case composerFile
 case shortcutText
 case shortcutVoice
 case programmatic
}

public struct PendingFileIngestion: Sendable, Codable, Equatable, Identifiable {
 public let attachmentID: UUID
 public let sourceURL: URL
 public let displayName: String
 public let contentTypeIdentifier: String

 public var id: UUID { attachmentID }

 public init(
 attachmentID: UUID = UUID(),
 sourceURL: URL,
 displayName: String,
 contentTypeIdentifier: String
 ) {
 self.attachmentID = attachmentID
 self.sourceURL = sourceURL
 self.displayName = displayName
 self.contentTypeIdentifier = contentTypeIdentifier
 }
}
