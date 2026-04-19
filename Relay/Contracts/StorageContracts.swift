import Foundation

internal struct StorageSchemaVersion: Sendable, Codable, Equatable, Comparable {
 internal let major: Int
 internal let minor: Int

 internal init(major: Int, minor: Int) {
 self.major = major
 self.minor = minor
 }

 internal static func < (lhs: StorageSchemaVersion, rhs: StorageSchemaVersion) -> Bool {
 if lhs.major != rhs.major {
 return lhs.major < rhs.major
 }
 return lhs.minor < rhs.minor
 }
}

internal enum PersistedStoreID: String, CaseIterable, Sendable, Codable, Equatable {
 case sessionTranscript
 case sessionIndex
 case memoryIndex
 case memoryTopic
 case attachment
 case folderIndex
 case bookmark
 case runtimeSidecar
 case replayFixtureExport
 case mcpConfig
 case pendingLaunchAction
}

internal enum StoreAuthority: String, CaseIterable, Sendable, Codable, Equatable {
 case authoritative
 case derived
}

internal struct StoreBacking: Sendable, Codable, Equatable {
 internal enum Kind: String, Sendable, Codable, Equatable {
 case applicationSupport
 case appGroupUserDefaults
 }

 internal let kind: Kind
 internal let relativePath: String?
 internal let suiteName: String?
 internal let key: String?

 internal static func applicationSupport(relativePath: String) -> StoreBacking {
 StoreBacking(kind: .applicationSupport, relativePath: relativePath, suiteName: nil, key: nil)
 }

 internal static func appGroupUserDefaults(suiteName: String, key: String) -> StoreBacking {
 StoreBacking(kind: .appGroupUserDefaults, relativePath: nil, suiteName: suiteName, key: key)
 }
}

internal enum StoreFileFormat: String, CaseIterable, Sendable, Codable, Equatable {
 case json
 case jsonl
 case markdown
 case encodedValue
}

internal enum StoreAtomicityRule: String, CaseIterable, Sendable, Codable, Equatable {
 case atomicRewrite
 case appendOnly
 case keyReplace
}

internal struct StoreHeaderLocation: Sendable, Codable, Equatable {
 internal enum Kind: String, Sendable, Codable, Equatable {
 case inlineEnvelope
 case companionFile
 }

 internal let kind: Kind
 internal let relativePath: String?

 internal static let inlineEnvelope = StoreHeaderLocation(kind: .inlineEnvelope, relativePath: nil)

 internal static func companionFile(relativePath: String) -> StoreHeaderLocation {
 StoreHeaderLocation(kind: .companionFile, relativePath: relativePath)
 }
}

internal enum PersistedStoreOwner: String, CaseIterable, Sendable, Codable, Equatable {
 case sessionStore
 case sessionIndex
 case memoryStore
 case attachmentStore
 case bookmarkStore
 case runtimeSidecarStore
 case replayFixtureStore
 case folderIndexRegistry
 case mcpConfigStore
 case launchActionStore
}

internal struct StoreMigrationRule: Sendable, Codable, Equatable {
 internal enum LegacyStrategy: String, CaseIterable, Sendable, Codable, Equatable {
 case none
 case synthesizeCompanionHeader
 case barePayloadToEnvelope
 case barePayloadOrCompanionHeader
 case importLegacyUserDefaults
 case rawEncodedValueToEnvelope
 }

 internal enum IncompatibleDataStrategy: String, CaseIterable, Sendable, Codable, Equatable {
 case rewriteHeaderOnly
 case archiveAuthoritative
 case rebuildDerived
 case fallbackToNone
 }

 internal let legacyStrategy: LegacyStrategy
 internal let incompatibleDataStrategy: IncompatibleDataStrategy
 internal let legacyKey: String?
 internal let notes: String?

 internal init(
 legacyStrategy: LegacyStrategy,
 incompatibleDataStrategy: IncompatibleDataStrategy,
 legacyKey: String? = nil,
 notes: String? = nil
 ) {
 self.legacyStrategy = legacyStrategy
 self.incompatibleDataStrategy = incompatibleDataStrategy
 self.legacyKey = legacyKey
 self.notes = notes
 }
}

internal struct StoreSchemaHeader: Sendable, Codable, Equatable {
 internal let storeID: PersistedStoreID
 internal let version: StorageSchemaVersion
 internal let authority: StoreAuthority

 internal func isCompatible(with contract: PersistedStoreContract) -> Bool {
 storeID == contract.id
 && authority == contract.authority
 && version.major == contract.version.major
 }
}

internal struct PersistedStoreContract: Sendable, Codable, Equatable {
 internal let id: PersistedStoreID
 internal let version: StorageSchemaVersion
 internal let authority: StoreAuthority
 internal let backing: StoreBacking
 internal let format: StoreFileFormat
 internal let headerLocation: StoreHeaderLocation
 internal let atomicity: StoreAtomicityRule
 internal let rebuildSource: String?
 internal let migrationRule: StoreMigrationRule
 internal let owner: PersistedStoreOwner

 internal var schemaHeader: StoreSchemaHeader {
 StoreSchemaHeader(storeID: id, version: version, authority: authority)
 }
}

internal struct VersionedStoreEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
 internal let header: StoreSchemaHeader
 internal let payload: Payload

 internal init(header: StoreSchemaHeader, payload: Payload) {
 self.header = header
 self.payload = payload
 }
}

extension VersionedStoreEnvelope: Equatable where Payload: Equatable {}

internal enum StorageRegistry {
 internal static let currentVersion = StorageSchemaVersion(major: 1, minor: 0)

 internal static let all: [PersistedStoreContract] = [
 PersistedStoreContract(
 id: .sessionTranscript,
 version: currentVersion,
 authority: .authoritative,
 backing: .applicationSupport(relativePath: "sessions/<sessionId>.jsonl"),
 format: .jsonl,
 headerLocation: .companionFile(relativePath: "sessions/schema.json"),
 atomicity: .appendOnly,
 rebuildSource: nil,
 migrationRule: .init(
 legacyStrategy: .synthesizeCompanionHeader,
 incompatibleDataStrategy: .rewriteHeaderOnly,
 notes: "Append-only transcript lines remain authoritative; schema lives in companion file."
 ),
 owner: .sessionStore
 ),
 PersistedStoreContract(
 id: .sessionIndex,
 version: currentVersion,
 authority: .authoritative,
 backing: .applicationSupport(relativePath: "sessions/index.json"),
 format: .json,
 headerLocation: .inlineEnvelope,
 atomicity: .atomicRewrite,
 rebuildSource: "Repairs transcript-derived fields from sessions/<sessionId>.jsonl while preserving title/workspace metadata.",
 migrationRule: .init(
 legacyStrategy: .barePayloadToEnvelope,
 incompatibleDataStrategy: .archiveAuthoritative
 ),
 owner: .sessionIndex
 ),
 PersistedStoreContract(
 id: .memoryIndex,
 version: currentVersion,
 authority: .authoritative,
 backing: .applicationSupport(relativePath: "memory/MEMORY.md"),
 format: .markdown,
 headerLocation: .companionFile(relativePath: "memory/schema.json"),
 atomicity: .atomicRewrite,
 rebuildSource: nil,
 migrationRule: .init(
 legacyStrategy: .synthesizeCompanionHeader,
 incompatibleDataStrategy: .rewriteHeaderOnly
 ),
 owner: .memoryStore
 ),
 PersistedStoreContract(
 id: .memoryTopic,
 version: currentVersion,
 authority: .authoritative,
 backing: .applicationSupport(relativePath: "memory/<type>_<name>.md"),
 format: .markdown,
 headerLocation: .companionFile(relativePath: "memory/schema.json"),
 atomicity: .atomicRewrite,
 rebuildSource: nil,
 migrationRule: .init(
 legacyStrategy: .synthesizeCompanionHeader,
 incompatibleDataStrategy: .rewriteHeaderOnly
 ),
 owner: .memoryStore
 ),
 PersistedStoreContract(
 id: .attachment,
 version: currentVersion,
 authority: .authoritative,
 backing: .applicationSupport(relativePath: "attachments/<sessionId>/<attachmentId>.json"),
 format: .json,
 headerLocation: .companionFile(relativePath: "attachments/schema.json"),
 atomicity: .atomicRewrite,
 rebuildSource: nil,
 migrationRule: .init(
 legacyStrategy: .synthesizeCompanionHeader,
 incompatibleDataStrategy: .rewriteHeaderOnly
 ),
 owner: .attachmentStore
 ),
 PersistedStoreContract(
 id: .folderIndex,
 version: currentVersion,
 authority: .derived,
 backing: .applicationSupport(relativePath: "folderIndex.json"),
 format: .json,
 headerLocation: .inlineEnvelope,
 atomicity: .atomicRewrite,
 rebuildSource: "Rebuilt from folder authorization state and future indexing passes.",
 migrationRule: .init(
 legacyStrategy: .barePayloadToEnvelope,
 incompatibleDataStrategy: .rebuildDerived
 ),
 owner: .folderIndexRegistry
 ),
 PersistedStoreContract(
 id: .bookmark,
 version: currentVersion,
 authority: .authoritative,
 backing: .applicationSupport(relativePath: "bookmarks.json"),
 format: .json,
 headerLocation: .inlineEnvelope,
 atomicity: .atomicRewrite,
 rebuildSource: nil,
 migrationRule: .init(
 legacyStrategy: .barePayloadToEnvelope,
 incompatibleDataStrategy: .archiveAuthoritative
 ),
 owner: .bookmarkStore
 ),
 PersistedStoreContract(
 id: .runtimeSidecar,
 version: currentVersion,
 authority: .authoritative,
 backing: .applicationSupport(relativePath: "runtime-sidecars/<sessionId>/<turnId>.json"),
 format: .json,
 headerLocation: .inlineEnvelope,
 atomicity: .atomicRewrite,
 rebuildSource: nil,
 migrationRule: .init(
 legacyStrategy: .barePayloadToEnvelope,
 incompatibleDataStrategy: .archiveAuthoritative
 ),
 owner: .runtimeSidecarStore
 ),
 PersistedStoreContract(
 id: .replayFixtureExport,
 version: currentVersion,
 authority: .derived,
 backing: .applicationSupport(relativePath: "replay-fixtures/<name>.json"),
 format: .json,
 headerLocation: .inlineEnvelope,
 atomicity: .atomicRewrite,
 rebuildSource: "Rebuilt from runtime sidecars through ReplayFixtureExporter.",
 migrationRule: .init(
 legacyStrategy: .barePayloadToEnvelope,
 incompatibleDataStrategy: .rebuildDerived
 ),
 owner: .replayFixtureStore
 ),
 PersistedStoreContract(
 id: .mcpConfig,
 version: currentVersion,
 authority: .authoritative,
 backing: .applicationSupport(relativePath: "mcp/servers.json"),
 format: .json,
 headerLocation: .inlineEnvelope,
 atomicity: .atomicRewrite,
 rebuildSource: nil,
 migrationRule: .init(
 legacyStrategy: .importLegacyUserDefaults,
 incompatibleDataStrategy: .archiveAuthoritative,
 legacyKey: "relay_mcp_servers"
 ),
 owner: .mcpConfigStore
 ),
 PersistedStoreContract(
 id: .pendingLaunchAction,
 version: currentVersion,
 authority: .authoritative,
 backing: .appGroupUserDefaults(suiteName: "group.com.isaac.relay", key: "glass_pending_launch_action"),
 format: .encodedValue,
 headerLocation: .inlineEnvelope,
 atomicity: .keyReplace,
 rebuildSource: nil,
 migrationRule: .init(
 legacyStrategy: .rawEncodedValueToEnvelope,
 incompatibleDataStrategy: .fallbackToNone,
 legacyKey: "glass_pending_launch_action"
 ),
 owner: .launchActionStore
 ),
 ]

 internal static func contract(for id: PersistedStoreID) -> PersistedStoreContract {
 guard let contract = all.first(where: { $0.id == id }) else {
 preconditionFailure("Missing storage contract for \(id.rawValue)")
 }
 return contract
 }
}

internal enum StorageContractIO {
 private static let encoder: JSONEncoder = {
 let encoder = JSONEncoder()
 encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
 return encoder
 }()

 private static let decoder = JSONDecoder()

 internal static func ensureParentDirectory(for url: URL) throws {
 let parent = url.deletingLastPathComponent()
 if !FileManager.default.fileExists(atPath: parent.path) {
 try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
 }
 }

 @discardableResult
 internal static func ensureCompanionHeader(
 for contract: PersistedStoreContract,
 at url: URL
 ) throws -> StoreSchemaHeader {
 try ensureParentDirectory(for: url)
 if FileManager.default.fileExists(atPath: url.path),
 let data = try? Data(contentsOf: url),
 let header = try? decoder.decode(StoreSchemaHeader.self, from: data),
 header.isCompatible(with: contract) {
 return header
 }
 let header = contract.schemaHeader
 let data = try encoder.encode(header)
 try data.write(to: url, options: .atomic)
 return header
 }

 @discardableResult
 internal static func archiveItemIfExists(
 at url: URL,
 storeID: PersistedStoreID
 ) throws -> URL? {
 guard FileManager.default.fileExists(atPath: url.path) else { return nil }
 let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
 let archived = url.deletingLastPathComponent()
 .appendingPathComponent(url.lastPathComponent + ".incompatible-\(storeID.rawValue)-\(timestamp).bak")
 if FileManager.default.fileExists(atPath: archived.path) {
 try FileManager.default.removeItem(at: archived)
 }
 try FileManager.default.moveItem(at: url, to: archived)
 return archived
 }
}
