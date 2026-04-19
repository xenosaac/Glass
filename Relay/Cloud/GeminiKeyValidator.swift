import Foundation

struct GeminiKeyValidator: Sendable {
 enum ValidationError: LocalizedError, Equatable {
 case emptyResponse
 case invalidGreeting(String)

 var errorDescription: String? {
 switch self {
 case .emptyResponse:
 return "Gemini returned an empty validation response."
 case .invalidGreeting(let response):
 return "Gemini returned an unexpected response: \(response)"
 }
 }
 }

 private let probe: @Sendable (String) async throws -> String

 init(probe: @escaping @Sendable (String) async throws -> String = { key in try await GeminiKeyValidator.liveProbe(key) }) {
 self.probe = probe
 }

 func validate(_ key: String) async throws {
 let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
 let response = try await probe(trimmedKey)
 let normalized = response.trimmingCharacters(in: .whitespacesAndNewlines)

 guard !normalized.isEmpty else {
 throw ValidationError.emptyResponse
 }

 guard Self.looksLikeGreeting(normalized) else {
 throw ValidationError.invalidGreeting(normalized)
 }
 }

 static func looksLikeGreeting(_ response: String) -> Bool {
 let lowered = response.lowercased()
 return ["hi", "hello", "hey", "greetings", "good to see you", "nice to meet you"]
 .contains { lowered.contains($0) }
 }

 private static func liveProbe(_ key: String) async throws -> String {
 let client = GeminiClient(apiKey: key)
 return try await client.validateGreetingProbe()
 }
}
