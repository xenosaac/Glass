import Foundation

/// Persists security-scoped bookmarks so file access survives app restart.
///
/// Bookmarks are stored as JSON: `{ "/path/to/folder": "base64-bookmark-data", ... }`
/// On load, each bookmark is resolved back to a URL and its security scope is activated.
public actor BookmarkStore {
 private let storeURL: URL
 private var bookmarks: [String: Data] = [:] // path -> bookmark data
 private let contract = StorageRegistry.contract(for: .bookmark)
 private let encoder: JSONEncoder
 private let decoder: JSONDecoder

 public init(storeURL: URL = AppPaths.bookmarks) {
 self.storeURL = storeURL
 let encoder = JSONEncoder()
 encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
 self.encoder = encoder
 self.decoder = JSONDecoder()
 }

 /// Load all saved bookmarks from disk.
 public func loadAll() throws {
 defer {
 print("[Bookmarks] loadAll store=\(storeURL.path) count=\(bookmarks.count) paths=\(Array(bookmarks.keys))")
 }
 guard FileManager.default.fileExists(atPath: storeURL.path) else {
 bookmarks = [:]
 return // No bookmarks yet
 }
 let data = try Data(contentsOf: storeURL)
 if let envelope = try? decoder.decode(VersionedStoreEnvelope<[String: String]>.self, from: data) {
 guard envelope.header.isCompatible(with: contract) else {
 _ = try? StorageContractIO.archiveItemIfExists(at: storeURL, storeID: contract.id)
 bookmarks = [:]
 return
 }
 bookmarks = envelope.payload.reduce(into: [:]) { partial, entry in
 if let data = Data(base64Encoded: entry.value) {
 partial[entry.key] = data
 }
 }
 return
 }

 if let dict = try? decoder.decode([String: String].self, from: data) {
 bookmarks = dict.reduce(into: [:]) { partial, entry in
 if let data = Data(base64Encoded: entry.value) {
 partial[entry.key] = data
 }
 }
 try persist
 return
 }

 _ = try? StorageContractIO.archiveItemIfExists(at: storeURL, storeID: contract.id)
 bookmarks = [:]
 }

 /// Save a new bookmark for the given URL.
 /// The URL must have already been selected by the user via UIDocumentPickerViewController.
 public func save(url: URL) throws {
 // On iOS, URLs from document picker are already security-scoped
 // We just need to create a bookmark to persist the access
 let didAccess = url.startAccessingSecurityScopedResource
 defer {
 if didAccess { url.stopAccessingSecurityScopedResource }
 }

 // iOS uses .minimalBookmark instead of .withSecurityScope
 let bookmark = try url.bookmarkData(
 options: .minimalBookmark,
 includingResourceValuesForKeys: nil,
 relativeTo: nil
 )
 bookmarks[url.path] = bookmark
 try persist
 print("[Bookmarks] save path=\(url.path) bookmark_bytes=\(bookmark.count) total_count=\(bookmarks.count)")
 }

 /// Resolve a bookmark to its URL. Returns nil if bookmark doesn't exist or is invalid.
 public func resolve(path: String) -> URL? {
 guard let data = bookmarks[path] else {
 print("[Bookmarks] resolve path=\(path) result=nil_data")
 return nil
 }
 var stale = false
 let resolvedURL: URL
 do {
 resolvedURL = try URL(
 resolvingBookmarkData: data,
 options: [],
 relativeTo: nil,
 bookmarkDataIsStale: &stale
 )
 } catch {
 print("[Bookmarks] resolve path=\(path) result=resolve_error error=\(error.localizedDescription)")
 return nil
 }
 if stale {
 // Bookmark is stale, try to refresh it
 if let refreshed = try? resolvedURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
 bookmarks[path] = refreshed
 try? persist
 }
 print("[Bookmarks] resolve path=\(path) result=stale_refreshed")
 } else {
 print("[Bookmarks] resolve path=\(path) result=success")
 }
 return resolvedURL
 }

 /// Remove a bookmark.
 public func remove(path: String) throws {
 bookmarks.removeValue(forKey: path)
 try persist
 }

 /// All paths we have bookmarks for.
 public func allPaths() -> [String] {
 Array(bookmarks.keys)
 }

 /// Resolve all bookmarks to URLs.
 public func allResolved() -> [URL] {
 allPaths.compactMap { resolve(path: $0) }
 }

 private func persist() throws {
 try StorageContractIO.ensureParentDirectory(for: storeURL)
 let dict = bookmarks.mapValues { $0.base64EncodedString }
 let envelope = VersionedStoreEnvelope(header: contract.schemaHeader, payload: dict)
 let data = try encoder.encode(envelope)
 try data.write(to: storeURL, options: .atomic)
 }
}

public enum BookmarkError: Error, LocalizedError {
 case cannotAccess(String)
 case resolutionFailed(String)

 public var errorDescription: String? {
 switch self {
 case .cannotAccess(let path): return "Cannot access security scope for: \(path)"
 case .resolutionFailed(let path): return "Failed to resolve bookmark for: \(path)"
 }
 }
}
