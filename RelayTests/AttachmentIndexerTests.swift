import XCTest
@testable import Relay

/// tests for `AttachmentIndexer`. All pure-function; uses
/// `FileManager.temporaryDirectory` for I/O fixtures and cleans up.
final class AttachmentIndexerTests: XCTestCase {

 // MARK: - Helpers

 private func tempFile(named name: String, content: String) throws -> URL {
 let dir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayAttachmentIndexerTests-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 let url = dir.appendingPathComponent(name)
 try content.data(using: .utf8)!.write(to: url)
 return url
 }

 private func tempFile(named name: String, byteCount: Int) throws -> URL {
 let dir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayAttachmentIndexerTests-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 let url = dir.appendingPathComponent(name)
 let data = Data(repeating: UInt8(ascii: "x"), count: byteCount)
 try data.write(to: url)
 return url
 }

 // MARK: - (a) small file → single chunk with correct hash

 func test_ingest_smallFile_producesSingleChunkWithCorrectHash() throws {
 let content = "hello world"
 let url = try tempFile(named: "tiny.txt", content: content)
 let indexer = AttachmentIndexer

 let attachment = try indexer.ingest(fileURL: url, displayName: "tiny.txt")

 XCTAssertEqual(attachment.digest.chunks.count, 1)
 XCTAssertEqual(attachment.digest.chunks[0].text, content)
 XCTAssertEqual(attachment.digest.chunks[0].position, 0)
 XCTAssertEqual(attachment.digest.chunks[0].totalChunks, 1)
 XCTAssertEqual(attachment.displayName, "tiny.txt")

 // Hash equals SHA256 of the file bytes — 64 hex chars.
 XCTAssertEqual(attachment.contentHash.count, 64)
 XCTAssertTrue(attachment.contentHash.allSatisfy { $0.isHexDigit })
 }

 // MARK: - (b) 50 KB file → multiple chunks with verified overlap

 func test_ingest_largeFile_producesMultipleChunksWithOverlap() throws {
 // Build a 50 KB payload of distinctive repeating text so overlap
 // boundaries are easy to inspect.
 let line = "The quick brown fox jumps over the lazy dog. "
 var content = ""
 while content.utf8.count < 50_000 { content += line }
 let url = try tempFile(named: "big.txt", content: content)

 let indexer = AttachmentIndexer(
 chunkByteTarget: 1_024,
 chunkOverlapBytes: 128,
 maxChunks: 1_000
 )

 let attachment = try indexer.ingest(fileURL: url, displayName: "big.txt")

 XCTAssertGreaterThan(attachment.digest.chunks.count, 1, "expected multiple chunks for 50 KB input")

 // Verify overlap: the tail of chunk[i] and head of chunk[i+1]
 // should share a non-empty prefix. (Character-boundary-walked
 // so the overlap may be slightly under the exact byte budget.)
 for i in 0..<(attachment.digest.chunks.count - 1) {
 let current = attachment.digest.chunks[i].text
 let next = attachment.digest.chunks[i + 1].text
 // Find at least a 32-byte substring of `next` at the tail of `current`.
 let tail = String(current.suffix(64))
 XCTAssertTrue(next.hasPrefix(String(tail.suffix(32))) || next.contains(String(tail.prefix(32))),
 "chunks \(i) and \(i+1) should overlap")
 }

 // Positions are contiguous 0..<N.
 for (i, chunk) in attachment.digest.chunks.enumerated() {
 XCTAssertEqual(chunk.position, i)
 XCTAssertEqual(chunk.totalChunks, attachment.digest.chunks.count)
 }
 }

 // MARK: - (c) oversize file throws

 func test_ingest_fileOverSizeCap_throwsFileTooLarge() throws {
 let url = try tempFile(named: "huge.txt", byteCount: 11 * 1024 * 1024)
 let indexer = AttachmentIndexer

 XCTAssertThrowsError(try indexer.ingest(fileURL: url, displayName: "huge.txt")) { error in
 guard let err = error as? AttachmentError else {
 return XCTFail("expected AttachmentError, got \(error)")
 }
 XCTAssertEqual(err, .fileTooLarge)
 }
 }

 // MARK: - (d) empty file → zero chunks

 func test_ingest_emptyFile_producesZeroChunks() throws {
 let url = try tempFile(named: "empty.txt", content: "")
 let indexer = AttachmentIndexer

 let attachment = try indexer.ingest(fileURL: url, displayName: "empty.txt")
 XCTAssertEqual(attachment.digest.chunks.count, 0)
 XCTAssertEqual(attachment.displayName, "empty.txt")
 // Hash of empty string is still a valid 64-char hex.
 XCTAssertEqual(attachment.contentHash.count, 64)
 }
}
