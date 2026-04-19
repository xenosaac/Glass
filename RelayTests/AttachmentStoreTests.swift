import XCTest
@testable import Relay

/// tests for `AttachmentStore`. Exercises persistence,
/// dedup, isolation, and removal against a temp-dir-rooted session
/// directory. The store resolves its path through
/// `AppPaths.attachments(forSessionId:)` which in turn roots under
/// `AppPaths.base`; the tests use distinct session IDs per test to
/// avoid cross-contamination.
final class AttachmentStoreTests: XCTestCase {

 // MARK: - Helpers

 private func makeAttachment(content: String, displayName: String = "fixture.txt") throws -> Attachment {
 let dir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayAttachmentStoreTests-fixture-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 let url = dir.appendingPathComponent(displayName)
 try content.data(using: .utf8)!.write(to: url)
 return try AttachmentIndexer.ingest(fileURL: url, displayName: displayName)
 }

 private func cleanSessionDir(_ sessionId: String) {
 let url = AppPaths.attachments(forSessionId: sessionId)
 try? FileManager.default.removeItem(at: url)
 }

 // MARK: - (a) persistence round-trip

 func test_persistenceRoundTrip_recreatedStoreSeesSameAttachments() async throws {
 let sid = "roundtrip-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }

 let a = try makeAttachment(content: "alpha content")
 let b = try makeAttachment(content: "beta content", displayName: "beta.txt")

 let store1 = AttachmentStore(sessionId: sid)
 try await store1.ingest(a)
 try await store1.ingest(b)
 XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.attachmentsSchema.path))

 let store2 = AttachmentStore(sessionId: sid)
 try await store2.load
 let restored = await store2.all

 XCTAssertEqual(restored.count, 2)
 XCTAssertTrue(restored.contains { $0.id == a.id })
 XCTAssertTrue(restored.contains { $0.id == b.id })
 }

 // MARK: - (b) dedup by contentHash

 func test_dedup_identicalContentIngestedTwice_storedOnce() async throws {
 let sid = "dedup-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }

 let first = try makeAttachment(content: "same body")
 let second = try makeAttachment(content: "same body", displayName: "other.txt")

 XCTAssertEqual(first.contentHash, second.contentHash, "fixture: same content should hash identically")

 let store = AttachmentStore(sessionId: sid)
 try await store.ingest(first)
 try await store.ingest(second)

 let all = await store.all
 XCTAssertEqual(all.count, 1, "dedup must drop second ingestion of identical content")
 }

 // MARK: - (c) session isolation

 func test_sessionIsolation_disjointStoresSeeSeparateData() async throws {
 let sidA = "sessionA-\(UUID().uuidString)"
 let sidB = "sessionB-\(UUID().uuidString)"
 defer {
 cleanSessionDir(sidA)
 cleanSessionDir(sidB)
 }

 let storeA = AttachmentStore(sessionId: sidA)
 let storeB = AttachmentStore(sessionId: sidB)

 let aAtt = try makeAttachment(content: "A-only content")
 let bAtt = try makeAttachment(content: "B-only content")

 try await storeA.ingest(aAtt)
 try await storeB.ingest(bAtt)

 let aAll = await storeA.all
 let bAll = await storeB.all

 XCTAssertEqual(aAll.count, 1)
 XCTAssertEqual(bAll.count, 1)
 XCTAssertFalse(aAll.contains { $0.id == bAtt.id }, "sessionA should not see sessionB's attachments")
 XCTAssertFalse(bAll.contains { $0.id == aAtt.id }, "sessionB should not see sessionA's attachments")
 }

 // MARK: - (d) remove deletes on-disk file and in-memory entry

 func test_remove_deletesOnDiskFileAndInMemoryEntry() async throws {
 let sid = "remove-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }

 let att = try makeAttachment(content: "content to remove")

 let store = AttachmentStore(sessionId: sid)
 try await store.ingest(att)

 let root = AppPaths.attachments(forSessionId: sid)
 let onDisk = root.appendingPathComponent("\(att.id.uuidString).json")
 XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path), "baseline: on-disk file exists")

 try await store.remove(att.id)

 let all = await store.all
 XCTAssertTrue(all.isEmpty, "in-memory entry removed")
 XCTAssertFalse(FileManager.default.fileExists(atPath: onDisk.path), "on-disk file removed")
 }
}
