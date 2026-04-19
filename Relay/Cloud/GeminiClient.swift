import Foundation

/// Cloud fallback client for Gemini 2.5 Flash-Lite.
///
/// Bumped from `gemini-2.0-flash-001` to `gemini-2.5-flash-lite` on
/// ahead of Google's deprecation of 2.0 Flash / 2.0 Flash-Lite on
/// Firebase. briefly considered bumping to
/// `gemini-2.5-flash` for the larger free-tier daily cap, but the project
/// moved to paid billing the same day — quota is no longer the constraint,
/// cost is. `gemini-2.5-flash-lite` is ~6× cheaper per output token than
/// `gemini-2.5-flash` (Flash-Lite: $0.10 / $0.40 per 1M in/out; Flash:
/// $0.30 / $2.50 per 1M in/out). At our traffic scale the quality delta
/// isn't worth the multiplier.
/// Settings UI already labels this as "Gemini 2.5 Flash-Lite" — keep
/// the model and the label in sync.
///
/// Uses the non-streaming `generateContent` endpoint for robustness.
/// Returns results through the same `CactusModelHost.StreamEvent` type
/// so AgentCore can treat it identically to on-device inference.
public actor GeminiClient {

 public enum GeminiError: Error, LocalizedError {
 case missingAPIKey
 case httpError(Int, String)
 case invalidResponse(String)
 case networkError(String)
 /// #3 — distinct case for HTTP 429 +
 /// `RESOURCE_EXHAUSTED` so the user sees a friendly Glass-shaped
 /// sentence instead of the raw Google JSON dump that previously
 /// surfaced as `"Cloud retry error: Gemini HTTP 429: {…}"`.
 /// `retryAfterMs` parsed from the `Please retry in Xms` substring
 /// in the error body when present (best-effort).
 case quotaExhausted(retryAfterMs: Int?)

 public var errorDescription: String? {
 switch self {
 case .missingAPIKey: return "Gemini API key not set"
 case .httpError(let code, let body): return "Gemini HTTP \(code): \(body.prefix(200))"
 case .invalidResponse(let msg): return "Invalid Gemini response: \(msg)"
 case .networkError(let msg): return "Network error: \(msg)"
 case .quotaExhausted(let retryMs):
 let suffix = retryMs.map { " Try again in ~\($0 / 1000)s." } ?? ""
 return "Cloud quota exhausted for the day (Gemini free tier).\(suffix) On-device replies still work; cloud-routed turns will retry tomorrow."
 }
 }
 }

 private let apiKey: String
 private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent"

 public init(apiKey: String) {
 self.apiKey = apiKey
 }

 /// Generate a completion via Gemini 2.5 Flash-Lite (non-streaming).
 /// Returns the same StreamEvent type as CactusModelHost for AgentCore compatibility.
 public nonisolated func stream(
 messages: [RelayMessage],
 tools: [any RelayTool],
 options: CactusModelHost.CompletionOptions = .init(),
 systemPrompt: String? = nil
 ) -> AsyncThrowingStream<CactusModelHost.StreamEvent, Error> {
 AsyncThrowingStream { continuation in
 Task {
 do {
 let result = try await self.generate(
 messages: messages,
 tools: tools,
 options: options,
 systemPrompt: systemPrompt
 )
 // Emit full text as a single token (non-streaming)
 if !result.text.isEmpty {
 continuation.yield(.token(result.text))
 }
 continuation.yield(.done(result))
 continuation.finish()
 } catch {
 continuation.finish(throwing: error)
 }
 }
 }
 }

 public func validateGreetingProbe() async throws -> String {
 let validationMessage = MessageFactory.userText("Hi")
 let validationOptions = CactusModelHost.CompletionOptions(
 maxTokens: 32,
 temperature: 0,
 topP: nil,
 topK: nil,
 forceTools: false,
 confidenceThreshold: 0
 )

 var capturedText = ""
 for try await event in stream(
 messages: [validationMessage],
 tools: [],
 options: validationOptions,
 systemPrompt: "Reply with a short greeting only."
 ) {
 switch event {
 case .token(let token):
 capturedText += token
 case .done(let result):
 if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
 capturedText = result.text
 }
 }
 }

 let trimmed = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
 if trimmed.isEmpty {
 throw GeminiError.invalidResponse("Empty greeting probe response")
 }
 return trimmed
 }

 // MARK: - Core Request

 private func generate(
 messages: [RelayMessage],
 tools: [any RelayTool],
 options: CactusModelHost.CompletionOptions,
 systemPrompt: String?
 ) async throws -> CactusModelHost.CompletionResult {
 let startTime = CFAbsoluteTimeGetCurrent()

 // Build request body
 var body: [String: Any] = [:]

 // System instruction
 if let sys = systemPrompt, !sys.isEmpty {
 body["systemInstruction"] = [
 "parts": [["text": sys]]
 ]
 }

 // Convert messages
 body["contents"] = encodeMessages(messages)

 // web-search grounding. If the latest
 // user message is an explicit web-search intent ("search the web
 // for X", "what's the latest news", etc.), append the built-in
 // `googleSearch` tool to the request body so Gemini answers with
 // real-time grounded results. Replaces the removed Brave Search
 // API tool. Detection runs here (rather than threading a
 // `requiresGrounding` flag through `HostExecutionOptions`) so
 // every cloud handoff that happens to carry a search-intent user
 // message gets grounding for free.
 let needsWebGrounding = Self.shouldEnableWebGrounding(messages: messages)

 // Convert tools
 let toolDecls = encodeTools(tools)
 var toolsArray: [[String: Any]] = []
 if !toolDecls.isEmpty {
 toolsArray.append(["functionDeclarations": toolDecls])
 }
 if needsWebGrounding {
 toolsArray.append(["googleSearch": ()[String: Any]])
 }
 if !toolsArray.isEmpty {
 body["tools"] = toolsArray
 }

 if !toolDecls.isEmpty && !needsWebGrounding {
 // — always send toolConfig explicitly instead of
 // relying on Gemini's implicit AUTO default. When
 // `options.forceTools == true` (HostToolMode.required surfaced
 // via ModelHostAdapters), force ANY so Gemini MUST call a tool
 // (fixes memory_write silently dropped on declarativeFact).
 // Otherwise pin to AUTO explicitly so a future Gemini default
 // change can't silently flip agent behavior.
 //
 // Note: when `needsWebGrounding` is true, we deliberately skip
 // toolConfig entirely — grounding tools must coexist with
 // function declarations under Gemini's default AUTO so the
 // model can pick the search path itself.
 //
 // Reference: Google Gemini API `toolConfig.functionCallingConfig`,
 // mode values { AUTO | ANY | NONE }, v1beta `gemini-2.5-flash-lite`.
 let mode = options.forceTools ? "ANY" : "AUTO"
 body["toolConfig"] = [
 "functionCallingConfig": ["mode": mode]
 ]
 }

 // — explicit safety thresholds. Gemini default is
 // BLOCK_MEDIUM_AND_ABOVE which can silently intercept benign
 // agentic queries. BLOCK_ONLY_HIGH preserves real safety
 // (CSAM, explicit violence) while freeing the agent path.
 body["safetySettings"] = [
 ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_ONLY_HIGH"],
 ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_ONLY_HIGH"],
 ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_ONLY_HIGH"],
 ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_ONLY_HIGH"]
 ]

 // Generation config
 var config: [String: Any] = ["maxOutputTokens": options.maxTokens]
 if let temp = options.temperature { config["temperature"] = temp }
 if let topP = options.topP { config["topP"] = topP }
 if let topK = options.topK { config["topK"] = topK }

 // — let Gemini 2.5 Flash dynamically allocate thinking
 // budget per turn. `thinkingBudget: -1` = dynamic (simple queries
 // use 0 thinking tokens, complex ones up to model max). Keep
 // `includeThoughts: false` in product; raw reasoning stays server-side.
 config["thinkingConfig"] = [
 "thinkingBudget": -1,
 "includeThoughts": false
 ]
 body["generationConfig"] = config

 // HTTP request
 guard var urlComponents = URLComponents(string: baseURL) else {
 throw GeminiError.invalidResponse("Bad URL")
 }
 urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]

 var request = URLRequest(url: urlComponents.url!)
 request.httpMethod = "POST"
 request.setValue("application/json", forHTTPHeaderField: "Content-Type")
 request.timeoutInterval = 60
 request.httpBody = try JSONSerialization.data(withJSONObject: body)

 #if DEBUG
 // — mirror of on-device [DEBUG_GEMMA_RAW]. Log outgoing
 // body so we can verify on device that inlineData images,
 // safetySettings, thinkingConfig, toolConfig are actually sent.
 if let bodyData = request.httpBody,
 let bodyStr = String(data: bodyData, encoding: .utf8) {
 print("[DEBUG_GEMINI_RAW] request (\(bodyData.count) bytes): \(bodyStr.prefix(4096))")
 }
 #endif

 // — exponential backoff on transient errors.
 // Worst-case total added latency: ~3.1s. Non-transient 4xx fails
 // immediately (invalid API key, malformed request, etc.). 5xx
 // and 429 back off; 429 respects Retry-After when present.
 let backoffsNs: [UInt64] = [300_000_000, 800_000_000, 2_000_000_000]
 var attempt = 0
 var data: Data = Data()
 var response: URLResponse? = nil

 retryLoop: while true {
 do {
 (data, response) = try await URLSession.shared.data(for: request)
 } catch {
 if attempt < backoffsNs.count {
 #if DEBUG
 print("[DEBUG_GEMINI_RAW] network error (attempt \(attempt + 1)): \(error.localizedDescription) — backing off \(backoffsNs[attempt] / 1_000_000)ms")
 #endif
 try? await Task.sleep(nanoseconds: backoffsNs[attempt])
 attempt += 1
 continue retryLoop
 }
 throw GeminiError.networkError(error.localizedDescription)
 }

 guard let httpResponse = response as? HTTPURLResponse else {
 throw GeminiError.invalidResponse("Non-HTTP response")
 }
 if (200...299).contains(httpResponse.statusCode) {
 break retryLoop
 }

 let bodyText = String(data: data, encoding: .utf8) ?? ""

 // 429 / RESOURCE_EXHAUSTED: respect Retry-After header if present; otherwise backoff.
 if httpResponse.statusCode == 429 || bodyText.contains("RESOURCE_EXHAUSTED") {
 if attempt < backoffsNs.count {
 let retryNs: UInt64 = {
 if let header = httpResponse.value(forHTTPHeaderField: "Retry-After"),
 let seconds = UInt64(header) {
 return seconds * 1_000_000_000
 }
 return backoffsNs[attempt]
 }()
 #if DEBUG
 print("[DEBUG_GEMINI_RAW] 429 quota (attempt \(attempt + 1)) — backing off \(retryNs / 1_000_000)ms")
 #endif
 try? await Task.sleep(nanoseconds: retryNs)
 attempt += 1
 continue retryLoop
 }
 // detect Gemini free-tier
 // quota exhaustion so the user sees a friendly Glass-shaped
 // sentence rather than raw Google JSON.
 let retryAfterMs = Self.parseRetryAfterMs(from: bodyText)
 throw GeminiError.quotaExhausted(retryAfterMs: retryAfterMs)
 }

 // 5xx transient — backoff.
 if (500...599).contains(httpResponse.statusCode), attempt < backoffsNs.count {
 #if DEBUG
 print("[DEBUG_GEMINI_RAW] \(httpResponse.statusCode) transient (attempt \(attempt + 1)) — backing off \(backoffsNs[attempt] / 1_000_000)ms")
 #endif
 try? await Task.sleep(nanoseconds: backoffsNs[attempt])
 attempt += 1
 continue retryLoop
 }

 // Non-retriable OR retries exhausted.
 throw GeminiError.httpError(httpResponse.statusCode, bodyText)
 }

 // Parse response
 let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

 #if DEBUG
 // — raw Gemini response before parse, symmetric with
 // [DEBUG_GEMMA_RAW] on the on-device path.
 let respStr = String(data: data, encoding: .utf8) ?? ""
 print("[DEBUG_GEMINI_RAW] response (\(data.count) bytes): \(respStr.prefix(8192))")
 #endif

 guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
 let candidates = json["candidates"] as? [[String: Any]],
 let first = candidates.first else {
 throw GeminiError.invalidResponse("Cannot parse candidates")
 }

 // — surface finishReason / safetyRatings BEFORE
 // requiring `content.parts`. When Gemini blocks for SAFETY, the
 // candidate has no `parts` field and the prior guard would fail
 // with "Cannot parse candidates" — masking the real block reason.
 if let finishReason = first["finishReason"] as? String {
 #if DEBUG
 print("[DEBUG_GEMINI_RAW] finishReason=\(finishReason)")
 #endif
 if finishReason == "SAFETY" || finishReason == "RECITATION" || finishReason == "BLOCKLIST" {
 #if DEBUG
 if let ratings = first["safetyRatings"] as? [[String: Any]] {
 print("[DEBUG_GEMINI_RAW] safetyRatings=\(ratings)")
 }
 #endif
 throw GeminiError.invalidResponse("Gemini blocked: finishReason=\(finishReason)")
 }
 }

 guard let content = first["content"] as? [String: Any],
 let parts = content["parts"] as? [[String: Any]] else {
 throw GeminiError.invalidResponse("Cannot parse candidates")
 }

 // Extract text and tool calls
 var text = ""
 var toolUses: [ToolUseBlock] = []

 for part in parts {
 if let t = part["text"] as? String {
 text += t
 }
 if let fc = part["functionCall"] as? [String: Any],
 let name = fc["name"] as? String {
 let args = fc["args"] as? [String: Any] ?? [:]
 let argsData = try JSONSerialization.data(withJSONObject: args)
 let argsJson = String(data: argsData, encoding: .utf8) ?? "{}"
 toolUses.append(ToolUseBlock(
 id: UUID().uuidString,
 name: name,
 inputJson: argsJson
 ))
 }
 }

 // if Gemini used Google Search
 // grounding, extract `candidates[0].groundingMetadata.groundingChunks[]`
 // (each chunk has `web.uri` + `web.title`) and append a
 // Markdown-formatted Sources footer to the response. Capped at
 // top 5 sources to keep replies readable. Skipped silently if
 // the model didn't actually search.
 if needsWebGrounding,
 let citationFooter = Self.formatGroundingFooter(from: first) {
 text += citationFooter
 }

 return CactusModelHost.CompletionResult(
 text: text,
 toolUses: toolUses,
 confidence: 0.9,
 cloudHandoff: false,
 prefillTPS: 0,
 decodeTPS: 0,
 timeToFirstTokenMs: elapsed,
 totalTimeMs: elapsed,
 ramUsageMB: 0
 )
 }

 // MARK: - Round-6 web-grounding helpers

 /// #3 — best-effort parse of the Google quota error
 /// body for `"Please retry in 841.498321ms"` style suffix. Returns
 /// the integer millisecond value when it matches; nil otherwise.
 /// Used only to enrich `GeminiError.quotaExhausted`'s user-facing
 /// message; never load-bearing.
 internal static func parseRetryAfterMs(from body: String) -> Int? {
 // Match "Please retry in 841.498321ms" or "retry in 841ms".
 let pattern = #"retry in (\d+)(?:\.\d+)?\s*ms"#
 guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
 return nil
 }
 let range = NSRange(body.startIndex..., in: body)
 guard let match = regex.firstMatch(in: body, range: range), match.numberOfRanges >= 2,
 let msRange = Range(match.range(at: 1), in: body) else {
 return nil
 }
 return Int(body[msRange])
 }

 /// Inspect the latest user message text in `messages` and decide
 /// whether to enable Gemini's Google Search grounding tool for this
 /// turn. Centralized here so any cloud handoff that happens to
 /// carry a search-intent user message gets grounding for free —
 /// no separate `requiresGrounding` flag has to be plumbed through
 /// `HostExecutionOptions`.
 private static func shouldEnableWebGrounding(messages: [RelayMessage]) -> Bool {
 for message in messages.reversed() {
 guard case .user(let user) = message else { continue }
 for block in user.blocks {
 if case .text(let t) = block {
 let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
 if !trimmed.isEmpty {
 return TurnClassifier.isWebSearchIntent(latestUserText: trimmed)
 }
 }
 }
 }
 return false
 }

 /// Parse Gemini's `groundingMetadata.groundingChunks[]` and render
 /// a Markdown Sources footer. Returns nil if grounding wasn't used
 /// or the response shape doesn't match.
 ///
 /// Expected shape per Gemini grounding docs:
 /// ```json
 /// "groundingMetadata": {
 /// "groundingChunks": [
 /// { "web": { "uri": "https://...", "title": "..." } },
 /// ...
 /// ]
 /// }
 /// ```
 internal static func formatGroundingFooter(from candidate: [String: Any]) -> String? {
 guard let metadata = candidate["groundingMetadata"] as? [String: Any],
 let chunks = metadata["groundingChunks"] as? [[String: Any]],
 !chunks.isEmpty else {
 return nil
 }
 var lines: [String] = []
 for (i, chunk) in chunks.prefix(5).enumerated() {
 guard let web = chunk["web"] as? [String: Any],
 let uri = web["uri"] as? String,
 !uri.isEmpty else { continue }
 let title = (web["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? uri
 lines.append("\(i + 1). [\(title)](\(uri))")
 }
 guard !lines.isEmpty else { return nil }
 return "\n\n---\n**Sources:**\n" + lines.joined(separator: "\n")
 }

 // MARK: - Message Encoding

 // — `internal nonisolated` (not private) so RelayTests can
 // unit-test the inlineData image encoding + error fallback shape
 // without mocking URLSession. The method is pure: it only reads its
 // parameters and touches `FileManager` for image files, with no
 // dependency on actor state.
 internal nonisolated func encodeMessages(_ messages: [RelayMessage]) -> [[String: Any]] {
 // Track toolUseId → name for toolResult conversion
 var toolUseIdToName: [String: String] = [:]
 var contents: [[String: Any]] = []

 for message in messages {
 switch message {
 case .user(let user):
 var parts: [[String: Any]] = []
 for block in user.blocks {
 switch block {
 case .text(let t):
 parts.append(["text": t])
 case .audioRef:
 // Audio not sent to Gemini — only text transcript
 continue
 case .image(let url):
 // — Gemini REST `inlineData` schema
 // (docs/vision.md): contents[].parts[].inlineData
 // .{mimeType, data:<base64>}. camelCase matches our
 // existing keys (functionCall, toolConfig, maxOutputTokens).
 let path = url.path(percentEncoded: false)
 guard FileManager.default.fileExists(atPath: path),
 let imageData = try? Data(contentsOf: url) else {
 #if DEBUG
 print("[DEBUG_GEMINI_RAW] image missing at cloud encode: \(path)")
 #endif
 parts.append(["text": "[image at \(path) could not be loaded]"])
 continue
 }
 // Hard-cap per-image base64 at 7MB so we stay under
 // Gemini's ~20MB total request payload even with system
 // prompt + history. Files API upload is out of scope
 // for this phase (it's a new feature).
 if imageData.count > 7 * 1024 * 1024 {
 #if DEBUG
 print("[DEBUG_GEMINI_RAW] image too large for inlineData (\(imageData.count) bytes): \(path)")
 #endif
 parts.append(["text": "[image at \(path) too large for cloud inline upload]"])
 continue
 }
 let mime: String = {
 switch url.pathExtension.lowercased() {
 case "png": return "image/png"
 case "gif": return "image/gif"
 case "webp": return "image/webp"
 case "heic": return "image/heic"
 default: return "image/jpeg"
 }
 }()
 parts.append([
 "inlineData": [
 "mimeType": mime,
 "data": imageData.base64EncodedString
 ]
 ])
 case .fileRef:
 continue
 }
 }
 if !parts.isEmpty {
 contents.append(["role": "user", "parts": parts])
 }

 case .assistant(let assistant):
 var parts: [[String: Any]] = []
 for block in assistant.blocks {
 switch block {
 case .text(let t):
 parts.append(["text": t])
 case .toolUse(let use):
 toolUseIdToName[use.id] = use.name
 let args = (try? JSONSerialization.jsonObject(
 with: use.inputJson.data(using: .utf8) ?? Data()
 )) as? [String: Any] ?? [:]
 parts.append([
 "functionCall": [
 "name": use.name,
 "args": args
 ]
 ])
 }
 }
 if !parts.isEmpty {
 contents.append(["role": "model", "parts": parts])
 }

 case .toolResult(let blocks):
 var parts: [[String: Any]] = []
 for block in blocks {
 let name = toolUseIdToName[block.toolUseId] ?? "unknown_tool"
 parts.append([
 "functionResponse": [
 "name": name,
 "response": ["output": block.output]
 ]
 ])
 }
 if !parts.isEmpty {
 contents.append(["role": "user", "parts": parts])
 }
 }
 }

 return contents
 }

 // MARK: - Tool Encoding

 private func encodeTools(_ tools: [any RelayTool]) -> [[String: Any]] {
 tools.compactMap { tool -> [String: Any]? in
 let params = (try? JSONSerialization.jsonObject(
 with: tool.inputSchema.json.data(using: .utf8) ?? Data()
 )) as? [String: Any] ?? ["type": "object", "properties": [:]]

 return [
 "name": tool.name,
 "description": tool.description,
 "parameters": params
 ]
 }
 }
}
