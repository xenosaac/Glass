import Foundation

internal struct PromptCompiler: Sendable {
 internal typealias Input = PromptAssemblyInput
 private static let socialCheckInPhrases = [
 "how are you",
 "what's up",
 "what s up",
 "how is it going",
 "hows it going",
 "how s it going"
 ]

 internal init() {}

 internal func compile(_ input: Input) -> PromptAssembly {
 var sections = SystemPrompt.basePromptSections(
 enabledToolNames: input.enabledToolNames,
 toolDescriptions: input.toolDescriptions,
 environment: input.environment,
 memoryIndex: input.memoryIndex,
 memoryTopics: input.memoryTopics,
 profileID: input.profileID
 )

 if let extraSystemContext = SystemPrompt.extraSystemContextSection(
 input.extraSystemContext,
 profileID: input.profileID
 ) {
 sections.append(extraSystemContext)
 }

 let renderedCurrentTurnFocus = input.currentTurnFocus
 ?? FocusSectionRenderer().render(input.turnOverlay)
 if let currentTurnFocus = SystemPrompt.currentTurnFocusSection(
 renderedCurrentTurnFocus,
 profileID: input.profileID
 ) {
 sections.append(currentTurnFocus)
 }
 let selectedExampleModules = Self.selectedExampleModules(for: input)
 if let exampleBank = SystemPrompt.exampleBankSection(
 selectedExampleModules,
 profileID: input.profileID
 ) {
 sections.append(exampleBank)
 }
 if let recoveryNotes = SystemPrompt.recoveryNotesSection(
 input.recoveryNotes,
 profileID: input.profileID
 ) {
 sections.append(recoveryNotes)
 }

 let renderedPrompt = sections.map(\.text).joined(separator: "\n\n")
 let diagnostics = PromptAssemblyDiagnostics(sections: sections, rendered: renderedPrompt)
 let stableDynamicBoundaryIndex = sections.firstIndex(where: { $0.id == .dynamicBoundary }) ?? 0

 return PromptAssembly(
 profileID: input.profileID,
 sections: sections,
 stableDynamicBoundaryIndex: stableDynamicBoundaryIndex,
 renderedPrompt: renderedPrompt,
 diagnostics: diagnostics,
 selectedExampleModules: selectedExampleModules,
 budgetPolicy: input.budgetPolicy
 )
 }

 private static func selectedExampleModules(for input: Input) -> [PromptExampleModuleID] {
 if !input.exampleModuleIDs.isEmpty {
 return input.exampleModuleIDs
 }
 guard input.profileID == .gemmaLocal,
 let turnOverlay = input.turnOverlay else {
 return []
 }

 // identity-question short-circuit. Bind
 // the `.identityQuestion` example whenever the user's text matches
 // an identity-probe phrase, regardless of upstream classification.
 // Catches the T16 device-log shape `"Tell me about yourself"` (which
 // the classifier currently routes to `.question`).
 if isAssistantIdentityProbe(turnOverlay.latestUserText) {
 return [.identityQuestion]
 }

 switch turnOverlay.classification {
 case .socialOpener:
 return [socialExampleModule(for: turnOverlay.latestUserText)]
 case .factRecallUnknown:
 return [.factRecallUnknown]
 case .factRecallKnown:
 return [.factRecallKnown]
 case .referentialFollowup:
 return [.referentialFollowup]
 case .declarativeFact:
 // Prompt-surgery follow-up: cover declarative facts ("My name is X")
 // via the fact-recall-known example pattern, not via a rule bullet.
 return [.factRecallKnown]
 case .question, .repairCue, .transportCheck, .toolFollowup, .ambiguous:
 return []
 }
 }

 private static let assistantIdentityProbePhrases: [String] = [
 "what is your name",
 "what s your name",
 "whats your name",
 "who are you",
 "what are you",
 "what should i call you",
 "how should i address you",
 "what do i call you",
 "tell me about yourself",
 "introduce yourself",
 "tell me who you are"
 ]

 private static func isAssistantIdentityProbe(_ latestUserText: String) -> Bool {
 let normalized = latestUserText
 .lowercased()
 .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
 .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
 .trimmingCharacters(in: .whitespacesAndNewlines)
 return assistantIdentityProbePhrases.contains { normalized.contains($0) }
 }

 private static func socialExampleModule(for latestUserText: String) -> PromptExampleModuleID {
 let normalized = latestUserText
 .lowercased()
 .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
 .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
 .trimmingCharacters(in: .whitespacesAndNewlines)

 if socialCheckInPhrases.contains(where: { normalized.contains($0) }) {
 return .socialCheckIn
 }
 return .socialGreeting
 }
}
