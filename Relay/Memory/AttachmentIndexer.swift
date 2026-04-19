import Foundation
import CryptoKit

/// pure ingestion helper. No actor, no I/O beyond the single
/// `FileManager` read at `ingest(fileURL:displayName:)` entry. The
/// tokenizer / stopword / chunking helpers are shared with retrieval
/// (see `AttachmentIndexer.tokenize(_:)` — called from
/// `RetrievalPlanner.plan(query:store:)` via an internal extension so
/// indexing and query-time normalization stay byte-for-byte identical).
public struct AttachmentIndexer: Sendable {

 /// UTF-8 byte target per chunk. Actual chunks may be slightly
 /// larger when a Character would be split by a strict byte cut;
 /// the chunker walks Character boundaries so preview text is
 /// always valid UTF-8.
 public let chunkByteTarget: Int

 /// Bytes of overlap between consecutive chunks so a query term
 /// that straddles a chunk boundary still scores in at least one
 /// chunk.
 public let chunkOverlapBytes: Int

 /// Hard cap on chunks per attachment. Guards against accidental
 /// ingest of a pathological input. 1000 × ~1 KB chunks = ~1 MB of
 /// indexed text, a conservative mobile-safe ceiling for .
 public let maxChunks: Int

 public init(
 chunkByteTarget: Int = 1_024,
 chunkOverlapBytes: Int = 128,
 maxChunks: Int = 1_000
 ) {
 self.chunkByteTarget = chunkByteTarget
 self.chunkOverlapBytes = chunkOverlapBytes
 self.maxChunks = maxChunks
 }

 /// Public ingest entry point. Reads the file, enforces
 /// safety caps, chunks, hashes, and returns a populated
 /// `Attachment`. Does NOT write to disk — that's
 /// `AttachmentStore.ingest(_:)`'s responsibility.
 public func ingest(
 fileURL: URL,
 displayName: String,
 attachmentID: UUID = UUID()
 ) throws -> Attachment {
 let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
 let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
 guard fileSize <= Self.maxFileBytes else {
 throw AttachmentError.fileTooLarge
 }

 let data: Data
 do {
 data = try Data(contentsOf: fileURL)
 } catch {
 throw AttachmentError.readFailed
 }

 let contentHash = Self.sha256Hex(data)

 guard let text = String(data: data, encoding: .utf8) else {
 throw AttachmentError.unsupportedFormat
 }

 let chunks = chunk(text: text)

 return Attachment(
 id: attachmentID,
 sourceURL: fileURL,
 displayName: displayName,
 contentHash: contentHash,
 digest: AttachmentDigest(kind: .text, chunks: chunks)
 )
 }

 // MARK: - Chunking

 /// Chunk `text` into UTF-8-byte-bounded pieces with
 /// `chunkOverlapBytes` overlap. Walks `Character` boundaries so
 /// chunks are always valid Unicode strings. Returns at most
 /// `maxChunks` entries.
 internal func chunk(text: String) -> [AttachmentChunk] {
 guard !text.isEmpty else { return [] }

 // Collect characters with their per-character UTF-8 byte
 // costs so we can span the target byte budget without
 // splitting a scalar.
 let chars = Array(text)
 let costs = chars.map { String($0).utf8.count }
 let totalBytes = costs.reduce(0, +)

 // Early-out: small-enough text fits in a single chunk.
 if totalBytes <= chunkByteTarget {
 let tokenEstimate = max(totalBytes / 4, 1)
 return [
 AttachmentChunk(
 id: "0",
 text: text,
 position: 0,
 totalChunks: 1,
 tokenEstimate: tokenEstimate
 )
 ]
 }

 var chunks: [(text: String, bytes: Int)] = []
 var startIdx = 0
 while startIdx < chars.count {
 if chunks.count >= maxChunks { break }

 // Accumulate characters from startIdx until we hit the
 // byte target or run out of input.
 var bytesAccum = 0
 var endIdx = startIdx
 while endIdx < chars.count && bytesAccum + costs[endIdx] <= chunkByteTarget {
 bytesAccum += costs[endIdx]
 endIdx += 1
 }
 // Always make forward progress — at minimum consume one
 // character even if it exceeds the byte target alone.
 if endIdx == startIdx && startIdx < chars.count {
 bytesAccum += costs[startIdx]
 endIdx = startIdx + 1
 }

 let chunkText = String(chars[startIdx..<endIdx])
 chunks.append((chunkText, bytesAccum))

 // Advance by (chunk size − overlap), minimum 1 so we
 // always progress.
 let overlapChars = Self.charactersSpanningBytes(
 chars: chars,
 from: endIdx,
 budget: chunkOverlapBytes,
 backward: true
 )
 let step = max(1, (endIdx - startIdx) - overlapChars)
 startIdx += step
 }

 let total = chunks.count
 return chunks.enumerated().map { (i, pair) in
 AttachmentChunk(
 id: String(i),
 text: pair.text,
 position: i,
 totalChunks: total,
 tokenEstimate: max(pair.bytes / 4, 1)
 )
 }
 }

 /// Count how many characters back from `from` fit inside the byte
 /// `budget`. Used by the chunker to derive the overlap step.
 private static func charactersSpanningBytes(
 chars: [Character],
 from: Int,
 budget: Int,
 backward: Bool
 ) -> Int {
 guard budget > 0 else { return 0 }
 var count = 0
 var bytes = 0
 var i = from - 1
 while i >= 0 && backward {
 let cost = String(chars[i]).utf8.count
 if bytes + cost > budget { break }
 bytes += cost
 count += 1
 i -= 1
 }
 return count
 }

 // MARK: - SHA256

 private static func sha256Hex(_ data: Data) -> String {
 let digest = SHA256.hash(data: data)
 return digest.map { String(format: "%02x", $0) }.joined()
 }

 // MARK: - Limits

 public static let maxFileBytes: Int = 10 * 1024 * 1024
}

// MARK: - Tokenizer (shared with RetrievalPlanner)

extension AttachmentIndexer {
 /// 20-word English stopword list. Conservative and adequate for v1;
 /// multilingual tokenization is a future concern.
 internal static let stopwords: Set<String> = [
 "the", "a", "an", "and", "or", "of", "to", "in", "on", "is",
 "are", "was", "be", "for", "with", "by", "at", "as", "that", "this"
 ]

 /// Whitespace-split, ASCII-lowercase, stopword-filtered tokens.
 /// Used by both ingestion (to build `AttachmentStore`'s inverted
 /// index over chunks) and retrieval (to normalize query terms).
 /// Both paths must call this same function so index keys and
 /// query terms stay byte-identical.
 internal static func tokenize(_ text: String) -> [String] {
 var tokens: [String] = []
 var current = ""
 for scalar in text.unicodeScalars {
 let isWord: Bool
 if scalar.isASCII {
 let c = Character(scalar)
 isWord = c.isLetter || c.isNumber
 } else {
 // Keep non-ASCII scalars as part of the current token
 // so CJK and accented text chunks into something,
 // even if our stopword list doesn't apply.
 isWord = true
 }
 if isWord {
 if scalar.isASCII {
 current.append(Character(scalar).lowercased())
 } else {
 current.unicodeScalars.append(scalar)
 }
 } else if !current.isEmpty {
 tokens.append(current)
 current = ""
 }
 }
 if !current.isEmpty {
 tokens.append(current)
 }
 return tokens.filter { !$0.isEmpty && !stopwords.contains($0) }
 }
}

// MARK: - Errors

public enum AttachmentError: Error, Sendable, Equatable {
 case fileTooLarge
 case unsupportedFormat
 case readFailed
}
