import Foundation

/// attachment value types — no behavior beyond Codable.
///
/// An `Attachment` is what `AttachmentIndexer` produces from a user-
/// imported text file and what `AttachmentStore` persists on disk. The
/// retrieval path (`RetrievalPlanner` + `AttachmentStore.retrieve`)
/// reads the digest's chunks at query time.
///
/// ships `.text` only. Later phases may extend `AttachmentKind`
/// with `.pdf`, `.image`, etc.; the separation lives here so the rest
/// of the retrieval surface doesn't change when kinds grow.
public struct Attachment: Sendable, Codable {
 public let id: UUID
 public let sourceURL: URL
 public let displayName: String
 /// SHA256 hex string of the raw file bytes. Used by
 /// `AttachmentStore.ingest(_:)` to dedup identical content across
 /// repeated ingestions of the same file.
 public let contentHash: String
 public let ingestedAt: Date
 public let digest: AttachmentDigest

 public init(
 id: UUID = UUID(),
 sourceURL: URL,
 displayName: String,
 contentHash: String,
 ingestedAt: Date = Date(),
 digest: AttachmentDigest
 ) {
 self.id = id
 self.sourceURL = sourceURL
 self.displayName = displayName
 self.contentHash = contentHash
 self.ingestedAt = ingestedAt
 self.digest = digest
 }
}

/// attachment kind taxonomy. Extension point for later phases
/// (`.pdf`, `.image`, audio); today only text is in scope.
public enum AttachmentKind: String, Sendable, Codable {
 case text
}

/// Digest produced by `AttachmentIndexer.ingest(...)`. Carries the
/// ordered chunks that retrieval scores over.
public struct AttachmentDigest: Sendable, Codable {
 public let kind: AttachmentKind
 public let chunks: [AttachmentChunk]

 public init(kind: AttachmentKind, chunks: [AttachmentChunk]) {
 self.kind = kind
 self.chunks = chunks
 }
}

/// A single chunk of text from an ingested attachment. `position`
/// is zero-based; `totalChunks` is the count of all chunks in the
/// parent attachment so `position / totalChunks` can be rendered in
/// injection markers (see `MessageFactory.attachmentChunk`).
public struct AttachmentChunk: Sendable, Codable {
 public let id: String
 public let text: String
 public let position: Int
 public let totalChunks: Int
 /// UTF-8-byte-based token estimate (bytes ÷ 4). Matches the
 /// estimator used in `Compactor` so budget accounting is
 /// consistent across context-engineering layers.
 public let tokenEstimate: Int

 public init(id: String, text: String, position: Int, totalChunks: Int, tokenEstimate: Int) {
 self.id = id
 self.text = text
 self.position = position
 self.totalChunks = totalChunks
 self.tokenEstimate = tokenEstimate
 }
}
