import XCTest
@testable import Relay

final class SessionPersistenceTests: XCTestCase {
 private func makeTempDir(_ name: String) throws -> URL {
 let dir = FileManager.default.temporaryDirectory
 .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 return dir
 }

 func test_sessionStore_synthesizesSchemaAndKeepsTranscriptRoundTrip() async throws {
 let dir = try makeTempDir("SessionStore")
 let store = SessionStore(sessionId: "abc", baseDir: dir)

 try await store.append(.user(UserContent(blocks: [.text("hello")])) )
 try await store.append(.assistant(AssistantContent(blocks: [.text("world")])) )

 let schemaURL = dir.appendingPathComponent("schema.json")
 XCTAssertTrue(FileManager.default.fileExists(atPath: schemaURL.path))

 let loaded = try await store.loadAll
 XCTAssertEqual(loaded.count, 2)
 }

 func test_sessionIndex_migratesLegacyBareArrayAndRepairsTranscriptDerivedFields() async throws {
 let dir = try makeTempDir("SessionIndex")
 let transcriptURL = dir.appendingPathComponent("session-1.jsonl")
 let workspaceURL = URL(fileURLWithPath: "/tmp/workspace")

 let transcript = [
 RelayMessage.user(UserContent(blocks: [.text("hello")])) ,
 RelayMessage.assistant(AssistantContent(blocks: [.text("hi")]))
 ]
 let encoder = JSONEncoder()
 let transcriptBody = try transcript
 .map { try String(decoding: encoder.encode($0), as: UTF8.self) }
 .joined(separator: "\n") + "\n"
 try transcriptBody.write(to: transcriptURL, atomically: true, encoding: .utf8)

 let repairedDate = Date(timeIntervalSince1970: 1_700_000_000)
 try FileManager.default.setAttributes([.modificationDate: repairedDate], ofItemAtPath: transcriptURL.path)

 let legacy = [SessionMetadata(
 id: "session-1",
 title: "My Title",
 workspaceURL: workspaceURL,
 createdAt: Date(timeIntervalSince1970: 1_600_000_000),
 lastMessageAt: Date(timeIntervalSince1970: 1_600_000_100),
 messageCount: 99
 )]
 let legacyData = try encoder.encode(legacy)
 try legacyData.write(to: dir.appendingPathComponent("index.json"), options: .atomic)

 let index = SessionIndex(baseDir: dir)
 try await index.load

 let loaded = await index.get("session-1")
 XCTAssertEqual(loaded?.title, "My Title")
 XCTAssertEqual(loaded?.workspaceURL, workspaceURL)
 XCTAssertEqual(loaded?.messageCount, 2)
 XCTAssertEqual(loaded?.lastMessageAt, repairedDate)

 let persisted = try Data(contentsOf: dir.appendingPathComponent("index.json"))
 let envelope = try JSONDecoder.withISO8601.decode(VersionedStoreEnvelope<[SessionMetadata]>.self, from: persisted)
 XCTAssertEqual(envelope.header.storeID, .sessionIndex)
 XCTAssertEqual(envelope.payload.first?.messageCount, 2)
 }
}

private extension JSONDecoder {
 static var withISO8601: JSONDecoder {
 let decoder = JSONDecoder()
 decoder.dateDecodingStrategy = .iso8601
 return decoder
 }
}
