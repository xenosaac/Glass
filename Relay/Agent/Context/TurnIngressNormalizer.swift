import Foundation
import UniformTypeIdentifiers

/// Result of ingress normalization. Keeps transcript and model-facing message
/// shapes separate so file attachments can be replayed durably without
/// pretending they are native multimodal model blocks.
public struct NormalizedTurn: Sendable {
 public let turnID: UUID
 public let transcriptMessage: RelayMessage
 public let modelMessage: RelayMessage
 public let pendingFileIngestions: [PendingFileIngestion]

 public init(
 turnID: UUID = UUID(),
 transcriptMessage: RelayMessage,
 modelMessage: RelayMessage,
 pendingFileIngestions: [PendingFileIngestion] = []
 ) {
 self.turnID = turnID
 self.transcriptMessage = transcriptMessage
 self.modelMessage = modelMessage
 self.pendingFileIngestions = pendingFileIngestions
 }
}

/// Materializes stable image assets, preserves transcript-visible file refs,
/// and synthesizes the model-only file preamble required for same-turn file
/// grounding.
public struct TurnIngressNormalizer: Sendable {
 public let sessionId: String
 private let mediaRootOverride: URL?

 public init(
 sessionId: String,
 mediaRootOverride: URL? = nil
 ) {
 self.sessionId = sessionId
 self.mediaRootOverride = mediaRootOverride
 }

 public func normalize(_ envelope: TurnEnvelope) async throws -> NormalizedTurn {
 if let prebuilt = envelope.prebuiltMessage {
 let projected = Self.projectMessageForModel(prebuilt)
 return NormalizedTurn(
 turnID: UUID(),
 transcriptMessage: prebuilt,
 modelMessage: projected
 )
 }

 let stableImages = try materializeImages(from: envelope.imageRefs)
 let transcriptBlocks = makeTranscriptBlocks(
 visibleText: envelope.visibleText,
 audioRef: envelope.audioRef,
 imageRefs: stableImages,
 fileRefs: envelope.fileRefs
 )
 let modelBlocks = Self.makeModelBlocks(
 visibleText: envelope.visibleText,
 audioRefs: envelope.audioRef.map { [$0] } ?? [],
 imageRefs: stableImages,
 fileDisplayNames: envelope.fileRefs.map(\.displayName)
 )

 return NormalizedTurn(
 turnID: UUID(),
 transcriptMessage: .user(UserContent(blocks: transcriptBlocks)),
 modelMessage: .user(UserContent(blocks: modelBlocks)),
 pendingFileIngestions: envelope.fileRefs
 )
 }

 internal static func projectMessagesForModel(_ messages: [RelayMessage]) -> [RelayMessage] {
 messages.map(projectMessageForModel)
 }

 internal static func projectMessagesForModel(
 _ messages: [RelayMessage],
 overridingLatestUserMessage latestUserModelMessage: RelayMessage?
 ) -> [RelayMessage] {
 guard let latestUserModelMessage,
 let lastUserIndex = lastNonMetaUserIndex(in: messages) else {
 return projectMessagesForModel(messages)
 }

 return messages.enumerated().map { index, message in
 if index == lastUserIndex {
 return mergeProjectedCurrentTurn(
 transcriptMessage: message,
 canonicalModelMessage: latestUserModelMessage
 )
 }
 return projectMessageForModel(message)
 }
 }

 internal static func projectMessageForModel(_ message: RelayMessage) -> RelayMessage {
 guard case .user(let content) = message, !content.isMeta else {
 return message
 }

 let fileDisplayNames = content.blocks.compactMap { block -> String? in
 guard case .fileRef(let ref) = block else { return nil }
 return ref.displayName
 }
 guard !fileDisplayNames.isEmpty else { return message }

 var visibleTexts: [String] = []
 var reminderTexts: [String] = []
 var audioRefs: [URL] = []
 var imageRefs: [URL] = []

 for block in content.blocks {
 switch block {
 case .text(let text):
 if isSystemReminderText(text) {
 reminderTexts.append(text)
 } else {
 visibleTexts.append(text)
 }
 case .audioRef(let url):
 audioRefs.append(url)
 case .image(let url):
 imageRefs.append(url)
 case .fileRef:
 continue
 }
 }

 let projectedBlocks = makeModelBlocks(
 visibleText: visibleTexts.joined(separator: "\n\n"),
 audioRefs: audioRefs,
 imageRefs: imageRefs,
 fileDisplayNames: fileDisplayNames,
 trailingSystemReminderTexts: reminderTexts
 )
 return .user(UserContent(blocks: projectedBlocks, isMeta: content.isMeta))
 }

 private static func mergeProjectedCurrentTurn(
 transcriptMessage: RelayMessage,
 canonicalModelMessage: RelayMessage
 ) -> RelayMessage {
 guard case .user(let transcriptContent) = transcriptMessage,
 case .user(let canonicalContent) = canonicalModelMessage else {
 return projectMessageForModel(transcriptMessage)
 }

 let reminderTexts = transcriptContent.blocks.compactMap { block -> String? in
 guard case .text(let text) = block, isSystemReminderText(text) else {
 return nil
 }
 return text
 }

 guard !reminderTexts.isEmpty else { return canonicalModelMessage }

 let existingTexts = Set(canonicalContent.blocks.compactMap { block -> String? in
 if case .text(let text) = block { return text }
 return nil
 })
 let mergedReminders = reminderTexts.filter { !existingTexts.contains($0) }
 guard !mergedReminders.isEmpty else { return canonicalModelMessage }

 return .user(
 UserContent(
 blocks: canonicalContent.blocks + mergedReminders.map(UserBlock.text),
 isMeta: canonicalContent.isMeta
 )
 )
 }

 private func makeTranscriptBlocks(
 visibleText: String,
 audioRef: URL?,
 imageRefs: [URL],
 fileRefs: [PendingFileIngestion]
 ) -> [UserBlock] {
 var blocks: [UserBlock] = []
 if !visibleText.isEmpty {
 blocks.append(.text(visibleText))
 }
 if let audioRef {
 blocks.append(.audioRef(audioRef))
 }
 blocks.append(contentsOf: imageRefs.map(UserBlock.image))
 blocks.append(contentsOf: fileRefs.map {
 .fileRef(ImportedFileRef(
 attachmentID: $0.attachmentID,
 displayName: $0.displayName,
 contentTypeIdentifier: $0.contentTypeIdentifier
 ))
 })
 return blocks
 }

 private static func makeModelBlocks(
 visibleText: String,
 audioRefs: [URL],
 imageRefs: [URL],
 fileDisplayNames: [String],
 trailingSystemReminderTexts: [String] = []
 ) -> [UserBlock] {
 var blocks: [UserBlock] = []
 let preamble = modelFilePreamble(
 visibleText: visibleText,
 fileDisplayNames: fileDisplayNames
 )
 if let preamble {
 blocks.append(.text(preamble))
 } else if !visibleText.isEmpty {
 blocks.append(.text(visibleText))
 }
 blocks.append(contentsOf: audioRefs.map(UserBlock.audioRef))
 blocks.append(contentsOf: imageRefs.map(UserBlock.image))
 blocks.append(contentsOf: trailingSystemReminderTexts.map(UserBlock.text))
 return blocks
 }

 private static func modelFilePreamble(
 visibleText: String,
 fileDisplayNames: [String]
 ) -> String? {
 guard !fileDisplayNames.isEmpty else { return nil }
 let joinedNames = fileDisplayNames.joined(separator: ", ")
 if visibleText.isEmpty {
 return """
 User attached file(s): \(joinedNames). They did not include a written question. Briefly acknowledge the attachment(s) and ask what they want analyzed.
 """
 }
 return """
 Attached files: \(joinedNames).

 \(visibleText)
 """
 }

 private static func isSystemReminderText(_ text: String) -> Bool {
 let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
 return trimmed.hasPrefix("<system-reminder>") && trimmed.hasSuffix("</system-reminder>")
 }

 private static func lastNonMetaUserIndex(in messages: [RelayMessage]) -> Int? {
 for i in stride(from: messages.count - 1, through: 0, by: -1) {
 if case .user(let content) = messages[i], !content.isMeta {
 return i
 }
 }
 return nil
 }

 private func materializeImages(from refs: [URL]) throws -> [URL] {
 guard !refs.isEmpty else { return [] }

 let fileManager = FileManager.default
 let mediaRoot = mediaRootOverride ?? AppPaths.sessionMedia(forSessionId: sessionId)
 if !fileManager.fileExists(atPath: mediaRoot.path) {
 try fileManager.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
 }

 return try refs.map { sourceURL in
 guard fileManager.fileExists(atPath: sourceURL.path) else {
 throw TurnIngressError.missingAsset(sourceURL.lastPathComponent)
 }

 if sourceURL.standardizedFileURL.path.hasPrefix(mediaRoot.standardizedFileURL.path) {
 return sourceURL
 }

 let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
 let destURL = mediaRoot.appendingPathComponent("\(UUID().uuidString).\(ext)")
 if fileManager.fileExists(atPath: destURL.path) {
 try fileManager.removeItem(at: destURL)
 }
 try fileManager.copyItem(at: sourceURL, to: destURL)
 return destURL
 }
 }

 public static func supportsFileType(_ contentTypeIdentifier: String) -> Bool {
 guard let type = UTType(contentTypeIdentifier) else { return false }
 if type.conforms(to: .text) { return true }
 let extraAllowed: [UTType] = [.json, .commaSeparatedText, .tabSeparatedText, .xml]
 return extraAllowed.contains(where: { type.conforms(to: $0) || type == $0 })
 }
}

public enum TurnIngressError: Error, LocalizedError, Sendable, Equatable {
 case unsupportedFileType(String)
 case missingAsset(String)

 public var errorDescription: String? {
 switch self {
 case .unsupportedFileType(let name):
 return "\(name) is not a supported text attachment yet."
 case .missingAsset(let name):
 return "Could not access \(name). Please try attaching it again."
 }
 }
}
