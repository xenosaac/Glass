import Foundation
import CoreSpotlight

/// Actor implementing FileProviderService with security-scoped bookmark management.
///
/// Usage:
/// ```swift
/// let provider = FileProvider
/// try await provider.initialize
/// // Now ready to read/write files in authorized folders
/// ```
public actor FileProvider: FileProviderService {
 private let bookmarkStore: BookmarkStore
 private var activeScopes: [String: URL] = [:] // path -> resolved URL with active scope

 public init(bookmarkStore: BookmarkStore = BookmarkStore()) {
 self.bookmarkStore = bookmarkStore
 }

 /// Load saved bookmarks and activate their security scopes.
 public func initialize() async throws {
 try await bookmarkStore.loadAll
 for path in await bookmarkStore.allPaths {
 if let url = await bookmarkStore.resolve(path: path) {
 if url.startAccessingSecurityScopedResource {
 activeScopes[path] = url
 }
 }
 }
 }

 /// Clean up security scopes on deallocation.
 /// Note: deinit for actors may not run reliably; call shutdown explicitly.
 deinit {
 // Best-effort cleanup; prefer explicit shutdown call
 for url in activeScopes.values {
 url.stopAccessingSecurityScopedResource
 }
 }

 /// Explicitly release all security-scoped resources.
 /// Call this when the provider is no longer needed (e.g., app backgrounding).
 public func shutdown() {
 for url in activeScopes.values {
 url.stopAccessingSecurityScopedResource
 }
 activeScopes.removeAll
 }

 // MARK: - FileProviderService

 public func isAuthorized(path: String) async -> Bool {
 let targetURL = URL(fileURLWithPath: path).standardizedFileURL
 let targetPath = targetURL.path
 for authorizedURL in activeScopes.values {
 let authorizedPath = authorizedURL.standardizedFileURL.path
 // Exact match
 if targetPath == authorizedPath {
 return true
 }
 // Target is inside authorized folder (must have "/" separator to avoid /foo/bar-other matching /foo/bar)
 let prefix = authorizedPath.hasSuffix("/") ? authorizedPath : authorizedPath + "/"
 if targetPath.hasPrefix(prefix) {
 return true
 }
 }
 return false
 }

 public func authorizedFolders() async -> [URL] {
 Array(activeScopes.values)
 }

 public func readFile(at path: String) async throws -> Data {
 guard await isAuthorized(path: path) else {
 throw FileProviderError.notAuthorized(path)
 }
 let url = URL(fileURLWithPath: path)
 guard FileManager.default.fileExists(atPath: path) else {
 throw FileProviderError.fileNotFound(path)
 }
 return try Data(contentsOf: url)
 }

 public func writeFile(at path: String, data: Data, createIntermediates: Bool) async throws {
 guard await isAuthorized(path: path) else {
 throw FileProviderError.notAuthorized(path)
 }
 let url = URL(fileURLWithPath: path)
 if createIntermediates {
 let parent = url.deletingLastPathComponent
 try FileManager.default.createDirectory(at: parent(), withIntermediateDirectories: true)
 }
 do {
 try data.write(to: url, options: .atomic)
 } catch {
 throw FileProviderError.writeFailed(path)
 }
 }

 public func listDirectory(at path: String, recursive: Bool, includeHidden: Bool) async throws -> [FileEntry] {
 guard await isAuthorized(path: path) else {
 throw FileProviderError.notAuthorized(path)
 }
 let url = URL(fileURLWithPath: path)
 var isDir: ObjCBool = false
 guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
 throw FileProviderError.notDirectory(path)
 }

 let fm = FileManager.default
 var entries: [FileEntry] = []

 let contents: [URL]
 if recursive {
 guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: includeHidden ? [] : [.skipsHiddenFiles]) else {
 return []
 }
 contents = enumerator.compactMap { $0 as? URL }
 } else {
 contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: includeHidden ? [] : [.skipsHiddenFiles])
 }

 for fileURL in contents {
 let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
 entries.append(FileEntry(
 name: fileURL.lastPathComponent,
 path: fileURL.path,
 isDirectory: values.isDirectory ?? false,
 size: Int64(values.fileSize ?? 0),
 modifiedAt: values.contentModificationDate ?? Date.distantPast
 ))
 }
 return entries
 }

 public func searchFiles(query: String, inFolder: String?, limit: Int) async throws -> [FileSearchResult] {
 // Capture authorized paths for filtering (actor-isolated)
 let authorizedPaths = activeScopes.values.map { $0.standardizedFileURL.path }

 // Helper to check if a path is within authorized folders
 func isPathAuthorized(_ path: String) -> Bool {
 let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
 for authPath in authorizedPaths {
 if standardized == authPath {
 return true
 }
 let prefix = authPath.hasSuffix("/") ? authPath : authPath + "/"
 if standardized.hasPrefix(prefix) {
 return true
 }
 }
 return false
 }

 // Use Core Spotlight to search indexed file contents
 let escapedQuery = query.replacingOccurrences(of: "\"", with: "\\\"")
 let queryString = "kMDItemTextContent == \"*\(escapedQuery)*\"cd"

 return try await withCheckedThrowingContinuation { continuation in
 var results: [FileSearchResult] = []
 let searchQuery = CSSearchQuery(queryString: queryString, attributes: ["kMDItemPath", "kMDItemDisplayName"])

 searchQuery.foundItemsHandler = { items in
 for item in items {
 guard let path = item.attributeSet.value(forKey: "kMDItemPath") as? String else { continue }
 // SECURITY: Filter to authorized folders only
 guard isPathAuthorized(path) else { continue }
 // Filter by folder if specified
 if let folder = inFolder {
 let folderPrefix = folder.hasSuffix("/") ? folder : folder + "/"
 if path != folder && !path.hasPrefix(folderPrefix) { continue }
 }
 let name = item.attributeSet.value(forKey: "kMDItemDisplayName") as? String ?? URL(fileURLWithPath: path).lastPathComponent
 results.append(FileSearchResult(path: path, displayName: name))
 if results.count >= limit { break }
 }
 }

 searchQuery.completionHandler = { error in
 if let error = error {
 continuation.resume(throwing: error)
 } else {
 continuation.resume(returning: Array(results.prefix(limit)))
 }
 }

 searchQuery.start
 }
 }

 public func addAuthorization(url: URL) async throws {
 try await bookmarkStore.save(url: url)
 if url.startAccessingSecurityScopedResource() {
 activeScopes[url.path] = url
 }
 }
}
