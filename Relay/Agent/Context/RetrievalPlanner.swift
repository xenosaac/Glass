import Foundation

public enum ContextArtifactKind: String, Sendable, Codable, Equatable {
 case attachment
 case memory
 case workspace
}

public struct ContextArtifact: Sendable, Codable, Equatable {
 public let id: String
 public let kind: ContextArtifactKind
 public let sourceDisplayName: String
 public let text: String
 public let tokenEstimate: Int
 public let position: Int?
 public let totalParts: Int?

 public init(
 id: String,
 kind: ContextArtifactKind,
 sourceDisplayName: String,
 text: String,
 tokenEstimate: Int,
 position: Int? = nil,
 totalParts: Int? = nil
 ) {
 self.id = id
 self.kind = kind
 self.sourceDisplayName = sourceDisplayName
 self.text = text
 self.tokenEstimate = tokenEstimate
 self.position = position
 self.totalParts = totalParts
 }
}

public struct ScoredContextArtifact: Sendable, Codable, Equatable {
 public let artifact: ContextArtifact
 public let score: Double

 public init(artifact: ContextArtifact, score: Double) {
 self.artifact = artifact
 self.score = score
 }
}

struct SelectedAttachmentChunk: Sendable {
 let attachmentDisplayName: String
 let chunk: AttachmentChunk
 let score: Double
}

/// Outcome of one retrieval pass. Empty when nothing matched or retrieval
/// was intentionally skipped for the turn.
public struct RetrievalDecision: Sendable, Equatable {
 public let query: String?
 public let artifacts: [ScoredContextArtifact]

 public init(query: String?, artifacts: [ScoredContextArtifact]) {
 self.query = query
 self.artifacts = artifacts
 }
}

/// Runtime-owned lexical retrieval planner for current-turn context.
///
/// Module 05 unifies three sources:
/// ingested attachment chunks
/// MemoryStore topic files
/// workspace file excerpts via authorized Spotlight search + file read
///
/// Retrieval is intentionally narrow:
/// runs only for `.question` turns
/// remains lexical/local-first
/// returns bounded artifacts instead of source-specific chunk types
public struct RetrievalPlanner: Sendable {

 public let maxAttachmentArtifacts: Int
 public let attachmentTokenBudget: Int
 public let maxMemoryArtifacts: Int
 public let memoryTokenBudget: Int
 public let maxWorkspaceArtifacts: Int
 public let workspaceTokenBudget: Int
 public let workspaceCandidateLimit: Int
 public let maxTotalArtifacts: Int
 public let maxInjectedTokens: Int

 private let excerptCharacterLimit: Int = 600
 private let maxWorkspaceFileBytes: Int = 250_000
 private let memoryRetrievalBudgetBytes: Int = 20_000

 public init(
 maxAttachmentArtifacts: Int = 2,
 attachmentTokenBudget: Int = 1_200,
 maxMemoryArtifacts: Int = 2,
 memoryTokenBudget: Int = 800,
 maxWorkspaceArtifacts: Int = 2,
 workspaceTokenBudget: Int = 800,
 workspaceCandidateLimit: Int = 5,
 maxTotalArtifacts: Int = 4,
 maxInjectedTokens: Int = 2_000
 ) {
 self.maxAttachmentArtifacts = maxAttachmentArtifacts
 self.attachmentTokenBudget = attachmentTokenBudget
 self.maxMemoryArtifacts = maxMemoryArtifacts
 self.memoryTokenBudget = memoryTokenBudget
 self.maxWorkspaceArtifacts = maxWorkspaceArtifacts
 self.workspaceTokenBudget = workspaceTokenBudget
 self.workspaceCandidateLimit = workspaceCandidateLimit
 self.maxTotalArtifacts = maxTotalArtifacts
 self.maxInjectedTokens = maxInjectedTokens
 }

 internal func plan(
 analysis: TurnAnalysis?,
 memoryStore: MemoryStore?,
 attachmentStore: AttachmentStore?,
 workspaceURL: URL?,
 fileProvider: (any FileProviderService)?
 ) async -> RetrievalDecision {
 guard let analysis, analysis.classification == .question else {
 return RetrievalDecision(query: nil, artifacts: [])
 }

 let query = analysis.latestUserText.trimmingCharacters(in: .whitespacesAndNewlines)
 let queryTerms = AttachmentIndexer.tokenize(query)
 guard !query.isEmpty, !queryTerms.isEmpty else {
 return RetrievalDecision(query: nil, artifacts: [])
 }

 async let attachmentArtifacts = collectAttachmentArtifacts(
 queryTerms: queryTerms,
 store: attachmentStore
 )
 async let memoryArtifacts = collectMemoryArtifacts(
 queryTerms: queryTerms,
 store: memoryStore
 )
 async let workspaceArtifacts = collectWorkspaceArtifacts(
 query: query,
 queryTerms: queryTerms,
 workspaceURL: workspaceURL,
 fileProvider: fileProvider
 )

 let merged = mergeArtifacts(
 query: query,
 attachmentArtifacts: await attachmentArtifacts,
 memoryArtifacts: await memoryArtifacts,
 workspaceArtifacts: await workspaceArtifacts
 )
 return merged
 }

 private func collectAttachmentArtifacts(
 queryTerms: [String],
 store: AttachmentStore?
 ) async -> [ScoredContextArtifact] {
 guard let store else { return [] }

 let chunks = await store.retrieve(
 queryTerms: queryTerms,
 topK: maxAttachmentArtifacts,
 tokenBudget: attachmentTokenBudget
 )

 return chunks.map { selected in
 ScoredContextArtifact(
 artifact: ContextArtifact(
 id: selected.chunk.id,
 kind: .attachment,
 sourceDisplayName: selected.attachmentDisplayName,
 text: selected.chunk.text,
 tokenEstimate: selected.chunk.tokenEstimate,
 position: selected.chunk.position,
 totalParts: selected.chunk.totalChunks
 ),
 score: selected.score
 )
 }
 }

 private func collectMemoryArtifacts(
 queryTerms: [String],
 store: MemoryStore?
 ) async -> [ScoredContextArtifact] {
 guard let store else { return [] }

 let documents = await store.loadRetrievalDocuments(budgetBytes: memoryRetrievalBudgetBytes)
 let scored = documents.compactMap { document -> ScoredContextArtifact? in
 let searchableText = [document.displayName, document.description, document.body]
 .filter { !$0.isEmpty }
 .joined(separator: "\n")
 let score = lexicalScore(queryTerms: queryTerms, text: searchableText)
 guard score > 0 else { return nil }

 let excerpt = excerptForMemoryDocument(document, queryTerms: queryTerms)
 let tokenEstimate = estimateTokens(excerpt)
 return ScoredContextArtifact(
 artifact: ContextArtifact(
 id: document.fileName,
 kind: .memory,
 sourceDisplayName: document.displayName,
 text: excerpt,
 tokenEstimate: tokenEstimate
 ),
 score: score
 )
 }

 return limitSourceArtifacts(
 scored.sorted() { scoredArtifactComparator($0, $1) },
 maxArtifacts: maxMemoryArtifacts,
 tokenBudget: memoryTokenBudget
 )
 }

 private func collectWorkspaceArtifacts(
 query: String,
 queryTerms: [String],
 workspaceURL: URL?,
 fileProvider: (any FileProviderService)?
 ) async -> [ScoredContextArtifact] {
 guard let workspaceURL, let fileProvider else { return [] }

 let results: [FileSearchResult]
 do {
 results = try await fileProvider.searchFiles(
 query: query,
 inFolder: workspaceURL.path,
 limit: workspaceCandidateLimit
 )
 } catch {
 return []
 }

 var candidates: [ScoredContextArtifact] = []
 var seenIDs = Set<String>()
 for result in results {
 guard let relativeID = workspaceRelativeID(for: result.path, workspaceURL: workspaceURL),
 !seenIDs.contains(relativeID) else {
 continue
 }
 seenIDs.insert(relativeID)

 guard let text = await readWorkspaceText(path: result.path, fileProvider: fileProvider) else {
 continue
 }
 let score = lexicalScore(queryTerms: queryTerms, text: text)
 guard score > 0 else { continue }
 guard let excerpt = excerpt(text: text, queryTerms: queryTerms) else {
 continue
 }
 candidates.append(
 ScoredContextArtifact(
 artifact: ContextArtifact(
 id: relativeID,
 kind: .workspace,
 sourceDisplayName: result.displayName,
 text: excerpt,
 tokenEstimate: estimateTokens(excerpt)
 ),
 score: score
 )
 )
 }

 return limitSourceArtifacts(
 candidates.sorted() { scoredArtifactComparator($0, $1) },
 maxArtifacts: maxWorkspaceArtifacts,
 tokenBudget: workspaceTokenBudget
 )
 }

 private func mergeArtifacts(
 query: String,
 attachmentArtifacts: [ScoredContextArtifact],
 memoryArtifacts: [ScoredContextArtifact],
 workspaceArtifacts: [ScoredContextArtifact]
 ) -> RetrievalDecision {
 let merged = (attachmentArtifacts + memoryArtifacts + workspaceArtifacts)
 .sorted() { scoredArtifactComparator($0, $1) }
 let limited = limitSourceArtifacts(
 merged,
 maxArtifacts: maxTotalArtifacts,
 tokenBudget: maxInjectedTokens
 )
 return RetrievalDecision(query: query, artifacts: limited)
 }

 private func limitSourceArtifacts(
 _ artifacts: [ScoredContextArtifact],
 maxArtifacts: Int,
 tokenBudget: Int
 ) -> [ScoredContextArtifact] {
 guard maxArtifacts > 0, tokenBudget > 0 else { return [] }

 var selected: [ScoredContextArtifact] = []
 var tokensUsed = 0
 for scored in artifacts {
 if selected.count >= maxArtifacts { break }
 let cost = scored.artifact.tokenEstimate
 if tokensUsed + cost > tokenBudget { continue }
 selected.append(scored)
 tokensUsed += cost
 }
 return selected
 }

 private func scoredArtifactComparator(
 _ lhs: ScoredContextArtifact,
 _ rhs: ScoredContextArtifact
 ) -> Bool {
 if lhs.score != rhs.score { return lhs.score > rhs.score }
 let lhsPriority = sourcePriority(lhs.artifact.kind)
 let rhsPriority = sourcePriority(rhs.artifact.kind)
 if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
 if lhs.artifact.sourceDisplayName != rhs.artifact.sourceDisplayName {
 return lhs.artifact.sourceDisplayName < rhs.artifact.sourceDisplayName
 }
 return lhs.artifact.id < rhs.artifact.id
 }

 private func sourcePriority(_ kind: ContextArtifactKind) -> Int {
 switch kind {
 case .attachment: return 0
 case .memory: return 1
 case .workspace: return 2
 }
 }

 private func lexicalScore(queryTerms: [String], text: String) -> Double {
 let queryTermSet = Set(queryTerms)
 let haystackTerms = AttachmentIndexer.tokenize(text)
 guard !haystackTerms.isEmpty else { return 0 }

 var termFrequencies: [String: Int] = [:]
 for term in haystackTerms where queryTermSet.contains(term) {
 termFrequencies[term, default: 0] += 1
 }
 guard !termFrequencies.isEmpty else { return 0 }

 return termFrequencies.values.reduce(0) { partial, tf in
 partial + log(1.0 + Double(tf))
 }
 }

 private func excerptForMemoryDocument(
 _ document: MemoryDocument,
 queryTerms: [String]
 ) -> String {
 let combined = [
 "Name: \(document.displayName)",
 document.description.isEmpty ? nil : "Description: \(document.description)",
 document.type.isEmpty ? nil : "Type: \(document.type)",
 document.body
 ]
 .compactMap { $0 }
 .joined(separator: "\n")

 return excerpt(text: combined, queryTerms: queryTerms) ?? String(combined.prefix(excerptCharacterLimit))
 }

 private func excerpt(text: String, queryTerms: [String]) -> String? {
 let lowercasedText = text.lowercased()
 var firstRange: Range<String.Index>?
 for term in queryTerms {
 if let range = lowercasedText.range(of: term.lowercased()) {
 if firstRange == nil || range.lowerBound < firstRange!.lowerBound {
 firstRange = range
 }
 }
 }

 guard let matchRange = firstRange else { return nil }

 let center = text.distance(from: text.startIndex, to: matchRange.lowerBound)
 let halfWindow = excerptCharacterLimit / 2
 let startOffset = max(0, center - halfWindow)
 let endOffset = min(text.count, startOffset + excerptCharacterLimit)
 let startIndex = text.index(text.startIndex, offsetBy: startOffset)
 let endIndex = text.index(text.startIndex, offsetBy: endOffset)
 var snippet = String(text[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
 if startOffset > 0 { snippet = "..." + snippet }
 if endOffset < text.count { snippet += "..." }
 return snippet.isEmpty ? nil : snippet
 }

 private func estimateTokens(_ text: String) -> Int {
 max(1, text.lengthOfBytes(using: .utf8) / 4)
 }

 private func workspaceRelativeID(for path: String, workspaceURL: URL) -> String? {
 let standardizedWorkspace = workspaceURL.standardizedFileURL.path
 let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
 if standardizedPath == standardizedWorkspace {
 return workspaceURL.lastPathComponent
 }
 let prefix = standardizedWorkspace.hasSuffix("/") ? standardizedWorkspace : standardizedWorkspace + "/"
 guard standardizedPath.hasPrefix(prefix) else { return nil }
 return String(standardizedPath.dropFirst(prefix.count))
 }

 private func readWorkspaceText(
 path: String,
 fileProvider: any FileProviderService
 ) async -> String? {
 guard let data = try? await fileProvider.readFile(at: path),
 !data.isEmpty,
 data.count <= maxWorkspaceFileBytes else {
 return nil
 }

 if let text = String(data: data, encoding: .utf8), !text.isEmpty {
 return text
 }
 if let text = String(data: data, encoding: .utf16), !text.isEmpty {
 return text
 }
 return nil
 }
}
