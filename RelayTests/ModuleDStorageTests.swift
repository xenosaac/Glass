import XCTest
@testable import Relay

final class ModuleDStorageTests: XCTestCase {
 private func makeTempDir(_ prefix: String) throws -> URL {
 let dir = FileManager.default.temporaryDirectory
 .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 return dir
 }

 private func makeDefaults(_ prefix: String) -> UserDefaults {
 let suite = "\(prefix).\(UUID().uuidString)"
 let defaults = UserDefaults(suiteName: suite)!
 defaults.removePersistentDomain(forName: suite)
 return defaults
 }

 func test_memoryStore_synthesizesSchemaWithoutChangingMarkdownBehavior() async throws {
 let root = try makeTempDir("MemoryStore")
 let store = MemoryStore(root: root)

 try await store.writeFile("user_profile.md", content: "---\nname: Isaac\ndescription: User profile\ntype: user\n---\nhello\n")

 XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("schema.json").path))
 let body = try await store.readFile("user_profile.md")
 XCTAssertTrue(body.contains("hello"))
 }

 func test_bookmarkStore_migratesLegacyDictionaryToEnvelope() async throws {
 let url = try makeTempDir("BookmarkStore").appendingPathComponent("bookmarks.json")
 let legacy: [String: String] = ["/tmp/demo": Data("bookmark".utf8).base64EncodedString]
 let legacyData = try JSONEncoder.encode(legacy)
 try legacyData.write(to: url, options: .atomic)

 let store = BookmarkStore(storeURL: url)
 try await store.loadAll

 let paths = await store.allPaths
 XCTAssertEqual(paths, ["/tmp/demo"])

 let persisted = try Data(contentsOf: url)
 let envelope = try JSONDecoder.decode(VersionedStoreEnvelope<[String: String]>.self, from: persisted)
 XCTAssertEqual(envelope.header.storeID, .bookmark)
 XCTAssertEqual(envelope.payload.keys.sorted(), ["/tmp/demo"])
 }

 func test_folderIndexRegistry_resetsSafelyOnIncompatibleData() async throws {
 let url = try makeTempDir("FolderIndex").appendingPathComponent("folderIndex.json")
 let badHeader = StoreSchemaHeader(
 storeID: .folderIndex,
 version: StorageSchemaVersion(major: 99, minor: 0),
 authority: .derived
 )
 let badEnvelope = VersionedStoreEnvelope(header: badHeader, payload: ["bad"])
 try JSONEncoder.encode(badEnvelope).write(to: url, options: .atomic)

 let registry = FolderIndexRegistry(fileURL: url)
 await registry.load

 let missing = await registry.state(for: "/tmp/missing")
 XCTAssertNil(missing)
 XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
 }

 func test_mcpConfigStore_importsLegacyDefaultsOnceAndThenUsesFileStore() async throws {
 let dir = try makeTempDir("MCPConfig")
 let fileURL = dir.appendingPathComponent("servers.json")
 let defaults = makeDefaults("relay.mcp.tests")
 let legacyConfig = MCPServerConfig(name: "Legacy", baseURL: URL(string: "https://example.com")!)
 let legacyData = try JSONEncoder.encode([legacyConfig])
 defaults.set(legacyData, forKey: "relay_mcp_servers")

 let store = MCPConfigStore(fileURL: fileURL, legacyDefaults: defaults)
 let imported = await store.allServers
 XCTAssertEqual(imported.map(\.name), ["Legacy"])
 XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

 let newConfig = MCPServerConfig(name: "FileBacked", baseURL: URL(string: "https://glass.dev")!)
 await store.add(newConfig)

 let current = await store.allServers
 XCTAssertEqual(Set(current.map(\.name)), Set(["Legacy", "FileBacked"]))

 let legacyRoundTrip = try XCTUnwrap(defaults.data(forKey: "relay_mcp_servers"))
 let legacyDecoded = try JSONDecoder.decode([MCPServerConfig].self, from: legacyRoundTrip)
 XCTAssertEqual(legacyDecoded.map(\.name), ["Legacy"], "legacy defaults should not be rewritten after migration")
 }

 func test_mcpServerConfig_normalizesCanvasHeaderForBareDomain() {
 let config = MCPServerConfig(
 name: "Canvas",
 baseURL: URL(string: "https://mcp.illinihunt.org/mcp")!,
 headers: [
 "X-Canvas-Token": " secret\n",
 "X-Canvas-URL": "canvas.eee.uci.edu "
 ]
 )

 XCTAssertEqual(config.headers["X-Canvas-Token"], "secret")
 XCTAssertEqual(config.headers["X-Canvas-URL"], "https://canvas.eee.uci.edu/api/v1")
 }

 func test_mcpServerConfig_normalizesCanvasHeaderWhenDecodingPersistedConfig() throws {
 let payload = """
 {
 "id": "canvas-config",
 "name": "Canvas",
 "baseURL": "https://mcp.illinihunt.org/mcp",
 "headers": {
 "X-Canvas-Token": " secret\\n",
 "X-Canvas-URL": "https://canvas.eee.uci.edu "
 },
 "isEnabled": true,
 "timeout": 30
 }
 """.data(using: .utf8)!

 let decoded = try JSONDecoder.decode(MCPServerConfig.self, from: payload)
 XCTAssertEqual(decoded.headers["X-Canvas-Token"], "secret")
 XCTAssertEqual(decoded.headers["X-Canvas-URL"], "https://canvas.eee.uci.edu/api/v1")
 }

 func test_launchActionStore_readsEnvelopeAndLegacyPayloadAndClearsValue() throws {
 let suite = "relay.launch.tests.\(UUID().uuidString)"
 let defaults = UserDefaults(suiteName: suite)!
 defaults.removePersistentDomain(forName: suite)
 let previous = LaunchActionStore.defaultsProvider
 LaunchActionStore.defaultsProvider = { defaults }
 defer {
 LaunchActionStore.defaultsProvider = previous
 defaults.removePersistentDomain(forName: suite)
 }

 LaunchActionStore.set(.askText("hello"))
 XCTAssertEqual(LaunchActionStore.consume, .askText("hello"))
 XCTAssertNil(defaults.data(forKey: "glass_pending_launch_action"))

 let legacy = try JSONEncoder.encode(PendingLaunchAction.startVoice)
 defaults.set(legacy, forKey: "glass_pending_launch_action")
 XCTAssertEqual(LaunchActionStore.consume, .startVoice)
 XCTAssertNil(defaults.data(forKey: "glass_pending_launch_action"))
 }
}
