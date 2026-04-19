import Foundation
import cactus

/// Module A — Wraps the Cactus C FFI model lifecycle and streaming inference.
///
/// Responsibilities:
/// • Own the `CactusModelT` handle for a single Gemma-4-E2B-it instance
/// (E4B was dropped — see worklog progress log for the reason).
/// • Convert Relay's high-level types (`RelayMessage`, `any RelayTool`) into
/// the JSON strings Cactus expects.
/// • Stream tokens out as they arrive via `AsyncThrowingStream<StreamEvent>`.
/// • Parse Cactus's final response JSON into a typed `CompletionResult`
/// with `ToolUseBlock[]` extracted from `function_calls`.
/// • Surface `cactusGetLastError` as a Swift `Error`.
///
/// Downstream consumers:
/// • `AgentCore` (Module B) will call `stream(messages:tools:options:)` as
/// its inner loop and forward events to its own `TurnEvent` stream.
/// • `VoiceInputView` / Composition tools will call `transcribe(pcm:)`.
public actor CactusModelHost {

 // MARK: - Public types

 public enum State: Sendable, Equatable {
 case unloaded
 case loading
 case ready
 case failed(String)
 }

 public enum HostError: Error, Sendable {
 case notLoaded
 case loadFailed(String)
 case inferenceFailed(String)
 case decodeFailed(String)
 }


 /// Options forwarded to the Cactus options JSON blob.
 public struct CompletionOptions: Sendable, Codable, Equatable {
 public var maxTokens: Int
 public var temperature: Double?
 public var topP: Double?
 public var topK: Int?
 public var forceTools: Bool
 public var confidenceThreshold: Double

 public init(
 maxTokens: Int = 2048,
 temperature: Double? = 1.0,
 topP: Double? = 0.95,
 topK: Int? = 64,
 forceTools: Bool = false,
 confidenceThreshold: Double = 0.0
 ) {
 self.maxTokens = maxTokens
 self.temperature = temperature
 self.topP = topP
 self.topK = topK
 self.forceTools = forceTools
 self.confidenceThreshold = confidenceThreshold
 }
 }

 /// Events emitted during a single streamed completion.
 public enum StreamEvent: Sendable {
 case token(String)
 case done(CompletionResult)
 }

 /// Final, typed result of a streamed completion, after all tokens have
 /// arrived and Cactus has returned its final JSON blob.
 public struct CompletionResult: Sendable, Codable, Equatable {
 public let text: String
 public let toolUses: [ToolUseBlock]
 public let confidence: Double
 public let cloudHandoff: Bool
 public let prefillTPS: Double
 public let decodeTPS: Double
 public let timeToFirstTokenMs: Double
 public let totalTimeMs: Double
 public let ramUsageMB: Double
 }

 // MARK: - State

 public let modelPath: String
 public private(set) var state: State = .unloaded
 private var handle: CactusModelT?

 // MARK: - Lifecycle

 public init(modelPath: String) {
 self.modelPath = modelPath
 }

 deinit {
 if let handle {
 cactusDestroy(handle)
 }
 }

 /// Load the model weights from disk. Safe to call once per instance.
 /// Subsequent calls are no-ops when the state is already `.ready`.
 public func load() async throws {
 if case .ready = state { return }
 state = .loading
 do {
 let h = try cactusInit(modelPath, nil, false)
 handle = h
 state = .ready
 } catch {
 state = .failed(String(describing: error))
 throw HostError.loadFailed(String(describing: error))
 }
 }

 /// Destroy the model handle and release GPU / CPU memory.
 public func unload() {
 if let h = handle {
 cactusDestroy(h)
 handle = nil
 }
 state = .unloaded
 }

 /// Clear KV cache between unrelated conversations.
 public func reset() {
 if let h = handle {
 cactusReset(h)
 }
 }

 // MARK: - Inference

 /// Stream a completion. Each token arrives as `.token(String)`; the final
 /// parsed result with `function_calls` extracted into `ToolUseBlock[]` is
 /// emitted once as `.done(CompletionResult)` before the stream finishes.
 public nonisolated func stream(
 messages: [RelayMessage],
 tools: [any RelayTool],
 options: CompletionOptions = .init(),
 systemPrompt: String? = nil
 ) -> AsyncThrowingStream<StreamEvent, Error> {
 AsyncThrowingStream { continuation in
 let task = Task {
 do {
 try await self.runStream(
 messages: messages,
 tools: tools,
 options: options,
 systemPrompt: systemPrompt,
 continuation: continuation
 )
 continuation.finish()
 } catch {
 continuation.finish(throwing: error)
 }
 }
 // Stop propagation chain:
 // outer consumer drops → onTermination fires → Swift task.cancel
 // unwinds the awaited-for-loop in runStream, AND we call
 // cactus_stop on the native handle so the blocking C call
 // inside cactusComplete unblocks immediately. Without the
 // native stop, the task "cancels" but cactusComplete keeps
 // generating 4-6 seconds of CPU after the UI has already
 // given up — visible to the user as the bubble clearing but
 // Gemma still burning battery.
 continuation.onTermination = { _ in
 task.cancel
 Task { await self.requestStopGeneration }
 }
 }
 }

 /// Ask the native Cactus runtime to stop the currently-running
 /// `cactusComplete` call. Safe to call when no generation is in
 /// progress (no-op if handle is nil, and `cactus_stop` is defined
 /// to be a no-op if the model is idle).
 ///
 /// Wired by the early-abort path in `AgentRunner.streamCompletion`:
 /// when the first ~80 tokens match a help-desk opener, the consumer
 /// drops the outer stream; that eventually reaches this actor via
 /// the `onTermination` hook on `stream(...)`.
 public func requestStopGeneration() {
 guard let h = handle else { return }
 cactusStop(h)
 }

 private func runStream(
 messages: [RelayMessage],
 tools: [any RelayTool],
 options: CompletionOptions,
 systemPrompt: String?,
 continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
 ) async throws {
 guard let handle else { throw HostError.notLoaded }

 // Don't add empty prefill - it creates consecutive assistant messages
 // which break OpenAI-style message format invariants and confuse the model.
 let assistantPrefill: String? = nil
 let messagesJson = try Self.encodeMessages(messages, systemPrompt: systemPrompt, assistantPrefill: assistantPrefill)
 let toolsJson = try Self.encodeTools(tools)
 let optionsJson = try Self.encodeOptions(options)

 #if DEBUG
 // Log truncated messages JSON for debugging conversation memory issues
 let jsonPreview = messagesJson.prefix(2000)
 print("[DEBUG_MEMORY] messagesJson preview: \(jsonPreview)...")
 // count outgoing image/audio attachments so we can
 // confirm on-device that the `images`/`audios` top-level keys
 // actually reach Cactus.
 if let data = messagesJson.data(using: .utf8),
 let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
 let imgCount = arr.reduce(0) { acc, msg in
 acc + ((msg["images"] as? [String])?.count ?? 0)
 }
 let audCount = arr.reduce(0) { acc, msg in
 acc + ((msg["audios"] as? [String])?.count ?? 0)
 }
 print("[DEBUG_GEMMA_RAW] outgoing media: images=\(imgCount) audios=\(audCount)")
 }
 #endif

 let rawResponse: String
 do {
 rawResponse = try cactusComplete(
 handle,
 messagesJson,
 optionsJson,
 toolsJson,
 { token, _ in
 continuation.yield(.token(token))
 },
 nil
 )
 } catch {
 throw HostError.inferenceFailed(String(describing: error))
 }

 #if DEBUG
 // raw Cactus JSON (≤8KB) logged before parse so we can
 // see thinking, function_calls, confidence, cloud_handoff verbatim
 // instead of the validator-rewritten form.
 let rawPreview = rawResponse.prefix(8192)
 print("[DEBUG_GEMMA_RAW] cactusComplete raw JSON (\(rawResponse.count) bytes): \(rawPreview)")
 #endif

 let result = try Self.parseCompletionJSON(rawResponse)
 continuation.yield(.done(result))
 }

 // MARK: - Transcription

 /// Transcribe PCM audio (16 kHz mono Int16) into text using the loaded ASR
 /// model. For Relay this host is expected to be a whisper-small instance,
 /// distinct from the Gemma-4-E2B host.
 ///
 /// `optionsJson` (R7-C ): forwarded verbatim to Cactus's FFI.
 /// Critical for Whisper — passing `{"language":"en"}` skips Whisper's
 /// auto-detect path which on short / noisy clips routinely outputs a
 /// max-decode of the "no speech" token (rendered as repeated `.` chars).
 /// Default nil preserves the historic behavior.
 public func transcribe(
 pcm: Data,
 prompt: String? = nil,
 optionsJson: String? = nil
 ) async throws -> String {
 guard let handle else { throw HostError.notLoaded }
 let rawResponse: String
 do {
 rawResponse = try cactusTranscribe(handle, nil, prompt, optionsJson, nil, pcm)
 } catch {
 throw HostError.inferenceFailed(String(describing: error))
 }
 return try Self.parseTranscribeJSON(rawResponse)
 }

 // MARK: - Streaming Transcription

 /// Begin a streaming transcription session.
 /// Caller must eventually call `streamTranscribeStop` to finalize and release resources.
 public func streamTranscribeStart(optionsJson: String? = nil) async throws -> CactusStreamTranscribeT {
 guard let handle else { throw HostError.notLoaded }
 return try cactusStreamTranscribeStart(handle, optionsJson)
 }

 /// Feed a chunk of 16kHz mono PCM data to the streaming transcriber.
 /// Returns partial transcript text (may be empty if not enough audio yet).
 public func streamTranscribeProcess(
 stream: CactusStreamTranscribeT,
 pcm: Data
 ) async throws -> String {
 let rawJSON = try cactusStreamTranscribeProcess(stream, pcm)
 guard !rawJSON.isEmpty else { return "" }
 return (try? Self.parseTranscribeJSON(rawJSON)) ?? ""
 }

 /// Finalize the streaming transcription. Returns the complete transcript.
 /// The stream handle is invalidated after this call.
 public func streamTranscribeStop(
 stream: CactusStreamTranscribeT
 ) async throws -> String {
 let rawJSON = try cactusStreamTranscribeStop(stream)
 guard !rawJSON.isEmpty else { return "" }
 return try Self.parseTranscribeJSON(rawJSON)
 }

 // MARK: - Embedding

 /// Produce a sentence/paragraph embedding for the given text.
 /// Used by the Memory Palace RAG index.
 public func embed(text: String, normalize: Bool = true) async throws -> [Float] {
 guard let handle else { throw HostError.notLoaded }
 do {
 return try cactusEmbed(handle, text, normalize)
 } catch {
 throw HostError.inferenceFailed(String(describing: error))
 }
 }

 // MARK: - Format conversion

 /// Convert `[RelayMessage]` into the JSON array string Cactus expects.
 /// Cactus format is OpenAI-style: `[{"role":"user","content":"..."}, ...]`.
 /// Multimodal content uses content blocks: `[{"type":"text","text":"..."}, {"type":"image_url","image_url":{"url":"data:..."}}]`.
 ///
 /// Parameter assistantPrefill: Optional text to start the assistant's response.
 /// This forces the model to continue from this point rather than starting fresh
 /// (e.g., skipping default greetings like "How can I assist you?").
 static func encodeMessages(_ messages: [RelayMessage], systemPrompt: String? = nil, assistantPrefill: String? = nil) throws -> String {
 var out: [[String: Any]] = []

 if let sys = systemPrompt {
 out.append(["role": "system", "content": sys])
 }

 for message in messages {
 switch message {
 case .user(let user):
 // Check if there are any non-text blocks
 let hasMultimodal = user.blocks.contains { block in
 switch block {
 case .text: return false
 case .audioRef, .image: return true
 case .fileRef: return false
 }
 }

 if hasMultimodal {
 // Cactus multimodal convention (see
 // `cactus/docs/cactus_engine.md:123-128`):
 // { "role":"user", "content":"<text>",
 // "images":["/abs/path"], "audios":["/abs/path"] }
 // Images and audio are passed as top-level file-path
 // arrays, not as OpenAI-style data-URL content blocks.
 // The previous `image_url`/`input_audio` shape was a
 // silent no-op — Cactus never saw the media, which is
 // the direct cause of the "uploaded images ignored"
 // bug.
 var textParts: [String] = []
 var imagePaths: [String] = []
 var audioPaths: [String] = []
 for block in user.blocks {
 switch block {
 case .text(let t):
 textParts.append(t)
 case .image(let url):
 let path = url.path(percentEncoded: false)
 guard FileManager.default.fileExists(atPath: path) else {
 // Surface the load failure as a user-visible
 // text fragment so the model at least knows
 // an image was attempted, instead of silently
 // falling back to text-only behavior.
 textParts.append("[image at \(path) could not be loaded: file not found]")
 #if DEBUG
 print("[DEBUG_GEMMA_RAW] image missing at encode time: \(path)")
 #endif
 continue
 }
 imagePaths.append(path)
 case .audioRef(let url):
 let path = url.path(percentEncoded: false)
 guard FileManager.default.fileExists(atPath: path) else {
 textParts.append("[audio at \(path) could not be loaded: file not found]")
 #if DEBUG
 print("[DEBUG_GEMMA_RAW] audio missing at encode time: \(path)")
 #endif
 continue
 }
 audioPaths.append(path)
 case .fileRef:
 continue
 }
 }
 var entry: [String: Any] = [
 "role": "user",
 "content": textParts.joined(separator: "\n")
 ]
 if !imagePaths.isEmpty { entry["images"] = imagePaths }
 if !audioPaths.isEmpty { entry["audios"] = audioPaths }
 out.append(entry)
 } else {
 // Text-only: use simple string content
 let text = user.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t }
 return nil
 }.joined(separator: "\n")
 if !text.isEmpty {
 out.append(["role": "user", "content": text])
 }
 }

 case .assistant(let assistant):
 var text = ""
 var calls: [[String: Any]] = []
 for block in assistant.blocks {
 switch block {
 case .text(let t):
 text += t
 case .toolUse(let use):
 calls.append([
 "id": use.id,
 "name": use.name,
 "arguments": use.inputJson
 ])
 }
 }
 var entry: [String: Any] = ["role": "assistant", "content": text]
 if !calls.isEmpty {
 entry["tool_calls"] = calls
 }
 out.append(entry)

 case .toolResult(let results):
 for r in results {
 out.append([
 "role": "tool",
 "tool_use_id": r.toolUseId,
 "content": r.output
 ])
 }
 }
 }

 // Only add assistant prefill if:
 // 1. Prefill is non-nil AND non-empty
 // 2. Last message is NOT already an assistant message (avoid consecutive assistants)
 if let prefill = assistantPrefill,
 !prefill.isEmpty,
 out.last?["role"] as? String != "assistant" {
 out.append(["role": "assistant", "content": prefill])
 }

 let data = try JSONSerialization.data(withJSONObject: out, options: [])
 return String(decoding: data, as: UTF8.self)
 }

 /// Repair tool_use / tool_result pairing so the transcript satisfies the
 /// invariant that every `tool_use` has exactly one matching `tool_result`
 /// in the IMMEDIATELY following user turn.
 ///
 /// Ports `ensureToolResultPairing` (`utils/messages.ts:5133-5460`). Unlike
 /// the prior `validateToolPairing`, this does not strip orphaned tool_uses
 /// that would leave the assistant referencing a tool it never called.
 /// Instead it:
 ///
 /// 1. Dedupes tool_use IDs across messages (keep first, drop later echoes).
 /// Ports the `allSeenToolUseIds` cross-message set at
 /// `utils/messages.ts:5147`.
 /// 2. For each assistant turn with tool_uses, if the next message is a
 /// `.toolResult`, prepends synthetic `ToolResultBlock` for missing IDs.
 /// If the next message is NOT a tool_result (or doesn't exist), inserts
 /// a synthetic `.toolResult([...])` immediately after the assistant.
 /// 3. Strips tool_result blocks whose tool_use_id never appears (orphans
 /// from a truncated/resumed session) — they would be rejected by the
 /// template layer.
 ///
 /// Returns the repaired array plus a flag indicating whether any repairs
 /// were made (used by the `[DEBUG_MEMORY]` log line).
 static func ensureToolResultPairing(
 _ messages: [RelayMessage]
 ) -> (messages: [RelayMessage], hadRepairs: Bool) {
 var repaired: [RelayMessage] = []
 var seenToolUseIds = Set<String>
 var madeRepair = false

 var i = 0
 while i < messages.count {
 let msg = messages[i]

 switch msg {
 case .assistant(let content):
 // Step 1: dedupe tool_use IDs within this turn AND across turns
 var keptBlocks: [AssistantBlock] = []
 var turnToolUseIds: [String] = []
 for block in content.blocks {
 if case .toolUse(let use) = block {
 if seenToolUseIds.contains(use.id) {
 // Duplicate echo — drop.
 madeRepair = true
 continue
 }
 seenToolUseIds.insert(use.id)
 turnToolUseIds.append(use.id)
 }
 keptBlocks.append(block)
 }
 repaired.append(.assistant(AssistantContent(blocks: keptBlocks)))

 // Step 2: ensure every tool_use in this turn has a result
 guard !turnToolUseIds.isEmpty else { i += 1; continue }

 let nextIndex = i + 1
 if nextIndex < messages.count,
 case .toolResult(let existing) = messages[nextIndex] {
 let existingIds = Set(existing.map { $0.toolUseId })
 let missing = turnToolUseIds.filter { !existingIds.contains($0) }
 if missing.isEmpty {
 // Next message already satisfies the pairing; keep it.
 repaired.append(messages[nextIndex])
 } else {
 // Prepend synthetic placeholders for missing IDs.
 let synthetics = missing.map { MessageFactory.syntheticToolResult(for: $0) }
 repaired.append(.toolResult(synthetics + existing))
 madeRepair = true
 }
 i = nextIndex + 1
 } else {
 // No tool_result follows. Inject one composed entirely of
 // synthetic placeholders, then continue from the original
 // next index (which may be another assistant or user turn).
 let synthetics = turnToolUseIds.map { MessageFactory.syntheticToolResult(for: $0) }
 repaired.append(.toolResult(synthetics))
 madeRepair = true
 i = nextIndex
 }

 case .toolResult(let results):
 // Orphan check: this branch is only hit when a tool_result
 // appears WITHOUT a preceding assistant with matching tool_uses
 // (e.g. at conversation start after truncation). Drop any
 // blocks whose tool_use_id was never seen.
 let filtered = results.filter { seenToolUseIds.contains($0.toolUseId) }
 if filtered.count != results.count { madeRepair = true }
 if !filtered.isEmpty {
 repaired.append(.toolResult(filtered))
 }
 i += 1

 case .user:
 repaired.append(msg)
 i += 1
 }
 }

 return (repaired, madeRepair)
 }

 /// Back-compat shim for call sites still on the old name. Prefer
 /// `ensureToolResultPairing` for new code.
 @available(*, deprecated, renamed: "ensureToolResultPairing")
 static func validateToolPairing(
 _ messages: [RelayMessage]
 ) -> (messages: [RelayMessage], hadOrphans: Bool) {
 let result = ensureToolResultPairing(messages)
 return (result.messages, result.hadRepairs)
 }

 /// Fold `<system-reminder>` text siblings into the last tool_result block
 /// of the same user turn. Ports `smooshSystemReminderSiblings`
 /// (`utils/messages.ts:1835-1873`).
 ///
 /// In Relay's message model, `toolResult` is its own `RelayMessage` case,
 /// not a `UserBlock` — so a user turn that mixes reminder text with
 /// tool_result blocks cannot structurally occur. This function is an
 /// identity pass that documents the invariant and keeps the pipeline
 /// site ready if the enum ever grows a mixed representation.
 static func smooshSystemReminderSiblings(
 _ messages: [RelayMessage]
 ) -> [RelayMessage] {
 return messages
 }

 /// Convert a list of `RelayTool`s into Cactus's tools JSON string.
 /// Returns `nil` when there are no tools — Cactus expects an omitted
 /// argument in that case, not an empty array.
 static func encodeTools(_ tools: [any RelayTool]) throws -> String? {
 guard !tools.isEmpty else { return nil }

 var out: [[String: Any]] = []
 for tool in tools {
 let schemaData = tool.inputSchema.json.data(using: .utf8) ?? Data("{}".utf8)
 let schemaObject = (try? JSONSerialization.jsonObject(with: schemaData)) ?? [String: Any]
 out.append([
 "name": tool.name,
 "description": tool.description,
 "parameters": schemaObject
 ])
 }
 let data = try JSONSerialization.data(withJSONObject: out, options: [])
 return String(decoding: data, as: UTF8.self)
 }

 /// Convert a `CompletionOptions` into Cactus's options JSON string.
 static func encodeOptions(_ options: CompletionOptions) throws -> String {
 var dict: [String: Any] = [
 "max_tokens": options.maxTokens,
 "confidence_threshold": options.confidenceThreshold,
 "force_tools": options.forceTools,
 // Disable thinking mode - it causes model to "overthink" into generic greetings
 // For simple Q&A, direct responses work better than chain-of-thought
 "enable_thinking_if_supported": false,
 // turn off Cactus's internal auto cloud handoff so
 // low-confidence Gemma outputs are NOT silently replaced by a
 // cloud response before AgentRunner even sees them. AgentRunner
 // makes its own handoff decision based on validator + toolMode.
 "auto_handoff": false,
 // (generation-level fence) — if Gemma leaks
 // <|channel>thought ... span into the response despite
 // enable_thinking_if_supported=false, stop decoding at the opener
 // so those tokens don't eat the tool_call budget. Paired with a
 // Swift-side scrubber in parseCompletionJSON as defense-in-depth.
 "stop_sequences": ["<|channel>", "<channel|>", "<end_of_turn>"],
 "include_stop_sequences": false
 ]
 if let t = options.temperature { dict["temperature"] = t }
 if let p = options.topP { dict["top_p"] = p }
 if let k = options.topK { dict["top_k"] = k }

 let data = try JSONSerialization.data(withJSONObject: dict, options: [])
 return String(decoding: data, as: UTF8.self)
 }

 /// Parse Cactus's final completion JSON blob into a typed `CompletionResult`.
 /// Extracts `function_calls` into `ToolUseBlock[]` with synthesized UUIDs
 /// (Cactus does not assign tool use IDs itself — Anthropic-style chaining
 /// tracks them on our side).
 static func parseCompletionJSON(_ json: String) throws -> CompletionResult {
 guard let data = json.data(using: .utf8),
 let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
 throw HostError.decodeFailed("cactus_complete returned invalid JSON")
 }

 if let success = dict["success"] as? Bool, !success {
 let err = dict["error"] as? String ?? "unknown"
 throw HostError.inferenceFailed(err)
 }

 // Cactus returns chain-of-thought in a separate `thinking`
 // field, but Gemma occasionally leaks <|channel>…<channel|> spans into
 // the `response` field too. Strip those spans so downstream code only
 // sees user-facing text. The separate `thinking` field is ignored.
 var text = dict["response"] as? String ?? ""
 text = Self.stripChannelSpans(text)
 let confidence = (dict["confidence"] as? NSNumber)?.doubleValue ?? 0
 let cloudHandoff = dict["cloud_handoff"] as? Bool ?? false
 let prefillTPS = (dict["prefill_tps"] as? NSNumber)?.doubleValue ?? 0
 let decodeTPS = (dict["decode_tps"] as? NSNumber)?.doubleValue ?? 0
 let ttft = (dict["time_to_first_token_ms"] as? NSNumber)?.doubleValue ?? 0
 let total = (dict["total_time_ms"] as? NSNumber)?.doubleValue ?? 0
 let ramMB = (dict["ram_usage_mb"] as? NSNumber)?.doubleValue ?? 0

 var toolUses: [ToolUseBlock] = []
 if let rawCalls = dict["function_calls"] as? [[String: Any]] {
 for call in rawCalls {
 guard let name = call["name"] as? String else { continue }
 let argsJson: String
 let argsValue = call["arguments"]
 if let argsStr = argsValue as? String {
 argsJson = argsStr
 } else if let argsValue {
 let argsData = (try? JSONSerialization.data(withJSONObject: argsValue)) ?? Data("{}".utf8)
 argsJson = String(decoding: argsData, as: UTF8.self)
 } else {
 argsJson = "{}"
 }
 toolUses.append(ToolUseBlock(
 id: UUID.uuidString,
 name: name,
 inputJson: argsJson
 ))
 }
 }

 return CompletionResult(
 text: text,
 toolUses: toolUses,
 confidence: confidence,
 cloudHandoff: cloudHandoff,
 prefillTPS: prefillTPS,
 decodeTPS: decodeTPS,
 timeToFirstTokenMs: ttft,
 totalTimeMs: total,
 ramUsageMB: ramMB
 )
 }

 /// Remove `<|channel>…<channel|>` spans (Gemma-4 thinking-mode leakage
 /// into the `response` field). Split out so it can be unit-tested without
 /// spinning up a real Cactus call.
 static func stripChannelSpans(_ input: String) -> String {
 guard input.contains("<|channel>") else { return input }
 var out = ""
 var i = input.startIndex
 while i < input.endIndex {
 if let start = input.range(of: "<|channel>", range: i..<input.endIndex) {
 out.append(contentsOf: input[i..<start.lowerBound])
 if let end = input.range(of: "<channel|>", range: start.upperBound..<input.endIndex) {
 i = end.upperBound
 } else {
 // No closing tag — drop the rest.
 break
 }
 } else {
 out.append(contentsOf: input[i..<input.endIndex])
 break
 }
 }
 return out.trimmingCharacters(in: .whitespacesAndNewlines)
 }

 /// Parse Cactus's `cactusTranscribe` JSON blob and return the text field.
 static func parseTranscribeJSON(_ json: String) throws -> String {
 guard let data = json.data(using: .utf8),
 let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
 throw HostError.decodeFailed("cactus_transcribe returned invalid JSON")
 }
 if let success = dict["success"] as? Bool, !success {
 throw HostError.inferenceFailed(dict["error"] as? String ?? "transcribe failed")
 }
 return dict["response"] as? String ?? ""
 }
}

extension CactusModelHost.HostError: LocalizedError {
 public var errorDescription: String? {
 switch self {
 case .notLoaded:
 return "Model is not loaded"
 case .loadFailed(let message):
 return "Model load failed: \(message)"
 case .inferenceFailed(let message):
 return "Inference failed: \(message)"
 case .decodeFailed(let message):
 return "Decode failed: \(message)"
 }
 }
}
