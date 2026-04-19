import Foundation

internal enum PromptProfileID: String, CaseIterable, Sendable, Codable, Equatable {
 case gemmaLocal
 case geminiCloud
 case functionGemmaTool
}

internal enum PromptSectionLayer: String, CaseIterable, Sendable, Codable, Equatable {
 case stableBootstrap
 case providerOverlay
 case dynamicTurn
 case recoveryRuntime
 case exampleBank
}

internal enum PromptSectionID: String, CaseIterable, Sendable, Codable, Equatable {
 case intro
 case systemRules
 case answering
 case multimodal
 case interactionStyle
 case toneAndStyle
 case outputEfficiency
 case toolGovernance
 case availableTools
 case dynamicBoundary
 case memory
 case environment
 case providerOverlay
 case extraSystemContext
 case currentTurnFocus
 case recoveryNotes
 case exampleBank
}

internal enum PromptSectionOwner: String, CaseIterable, Sendable, Codable, Equatable {
 case systemPrompt
 case promptCompiler
 case contextBuilder
 case runtimeRecovery
}

internal enum PromptExampleModuleID: String, CaseIterable, Sendable, Codable, Equatable {
 case socialGreeting
 case socialCheckIn
 case factRecallKnown
 case factRecallUnknown
 case referentialFollowup
 case repairCue
 case retrievalFollowup
 case toolContinuation
 /// Identity question — `"Tell me about yourself"`, `"Who are you?"`,
 /// `"What are you?"`. Added round 5 because a text-only
 /// system-prompt rule wasn't enough to keep Gemma from leaking
 /// `"I am Gemma 4..."` at long context.
 case identityQuestion
}

internal struct PromptBudgetPolicy: Sendable, Codable, Equatable {
 internal let targetEstimatedTokens: Int
 internal let hardEstimatedTokens: Int
 internal let droppableLayers: [PromptSectionLayer]
 internal let protectedSectionIDs: [PromptSectionID]

 internal init(
 targetEstimatedTokens: Int,
 hardEstimatedTokens: Int,
 droppableLayers: [PromptSectionLayer],
 protectedSectionIDs: [PromptSectionID]
 ) {
 self.targetEstimatedTokens = targetEstimatedTokens
 self.hardEstimatedTokens = hardEstimatedTokens
 self.droppableLayers = droppableLayers
 self.protectedSectionIDs = protectedSectionIDs
 }

 internal static func `default`(for profileID: PromptProfileID) -> PromptBudgetPolicy {
 switch profileID {
 case .gemmaLocal:
 return PromptBudgetPolicy(
 targetEstimatedTokens: 5_500,
 hardEstimatedTokens: 7_000,
 droppableLayers: [.exampleBank, .providerOverlay],
 protectedSectionIDs: [
 .systemRules,
 .answering,
 .availableTools,
 .currentTurnFocus,
 .recoveryNotes
 ]
 )
 case .geminiCloud:
 return PromptBudgetPolicy(
 targetEstimatedTokens: 9_000,
 hardEstimatedTokens: 12_000,
 droppableLayers: [.exampleBank],
 protectedSectionIDs: [
 .systemRules,
 .answering,
 .availableTools,
 .currentTurnFocus,
 .recoveryNotes
 ]
 )
 case .functionGemmaTool:
 return PromptBudgetPolicy(
 targetEstimatedTokens: 2_000,
 hardEstimatedTokens: 3_000,
 droppableLayers: [.exampleBank, .providerOverlay],
 protectedSectionIDs: [
 .systemRules,
 .availableTools,
 .currentTurnFocus,
 .recoveryNotes
 ]
 )
 }
 }
}

internal struct PromptSection: Sendable, Codable, Equatable {
 internal let id: PromptSectionID
 internal let layer: PromptSectionLayer
 internal let owner: PromptSectionOwner
 internal let required: Bool
 internal let truncationPriority: Int
 internal let profileApplicability: Set<PromptProfileID>
 internal let text: String
 internal let truncated: Bool

 internal init(
 id: PromptSectionID,
 layer: PromptSectionLayer,
 owner: PromptSectionOwner,
 required: Bool,
 truncationPriority: Int,
 profileApplicability: Set<PromptProfileID>,
 text: String,
 truncated: Bool = false
 ) {
 self.id = id
 self.layer = layer
 self.owner = owner
 self.required = required
 self.truncationPriority = truncationPriority
 self.profileApplicability = profileApplicability
 self.text = text
 self.truncated = truncated
 }
}

internal struct PromptAssemblyDiagnostics: Sendable, Codable, Equatable {
 internal let sectionOrder: [PromptSectionID]
 internal let sectionsByLayer: [PromptSectionLayer: [PromptSectionID]]
 internal let characterCountByLayer: [PromptSectionLayer: Int]
 internal let estimatedTokensByLayer: [PromptSectionLayer: Int]
 internal let totalCharacters: Int
 internal let totalEstimatedTokens: Int
 internal let truncatedSections: [PromptSectionID]

 internal init(sections: [PromptSection], rendered: String) {
 self.sectionOrder = sections.map(\.id)

 var sectionsByLayer = Dictionary(
 uniqueKeysWithValues: PromptSectionLayer.allCases.map { ($0, [PromptSectionID]) }
 )
 var characterCountByLayer = Dictionary(
 uniqueKeysWithValues: PromptSectionLayer.allCases.map { ($0, 0) }
 )
 var estimatedTokensByLayer = Dictionary(
 uniqueKeysWithValues: PromptSectionLayer.allCases.map { ($0, 0) }
 )

 for section in sections {
 sectionsByLayer[section.layer, default: []].append(section.id)
 characterCountByLayer[section.layer, default: 0] += section.text.count
 estimatedTokensByLayer[section.layer, default: 0] += Self.estimatedTokens(for: section.text)
 }

 self.sectionsByLayer = sectionsByLayer
 self.characterCountByLayer = characterCountByLayer
 self.estimatedTokensByLayer = estimatedTokensByLayer
 self.totalCharacters = rendered.count
 self.totalEstimatedTokens = estimatedTokensByLayer.values.reduce(0, +)
 self.truncatedSections = sections.filter(\.truncated).map(\.id)
 }

 private static func estimatedTokens(for text: String) -> Int {
 max(1, text.lengthOfBytes(using: .utf8) / 4)
 }
}

internal struct PromptAssemblyInput: Sendable {
 internal let profileID: PromptProfileID
 internal let enabledToolNames: Set<String>
 /// per-tool first-sentence description map.
 /// Threaded from `AgentRunner` via the tool catalog so
 /// `SystemPrompt.toolsSection` can render `- name: description.`
 /// bullets (CC-aligned pattern). Empty dict = legacy "names only"
 /// behavior preserved for callers that don't plumb the catalog.
 internal let toolDescriptions: [String: String]
 internal let environment: SystemPrompt.Environment
 internal let memoryIndex: String?
 internal let memoryTopics: [String: String]
 internal let extraSystemContext: [String: String]
 internal let turnOverlay: TurnOverlayBundle?
 internal let currentTurnFocus: String?
 internal let recoveryNotes: String?
 internal let exampleModuleIDs: [PromptExampleModuleID]
 internal let budgetPolicy: PromptBudgetPolicy

 internal init(
 profileID: PromptProfileID = .gemmaLocal,
 enabledToolNames: Set<String>,
 toolDescriptions: [String: String] = [:],
 environment: SystemPrompt.Environment,
 memoryIndex: String?,
 memoryTopics: [String: String],
 extraSystemContext: [String: String],
 turnOverlay: TurnOverlayBundle? = nil,
 currentTurnFocus: String? = nil,
 recoveryNotes: String? = nil,
 exampleModuleIDs: [PromptExampleModuleID] = [],
 budgetPolicy: PromptBudgetPolicy? = nil
 ) {
 self.profileID = profileID
 self.enabledToolNames = enabledToolNames
 self.toolDescriptions = toolDescriptions
 self.environment = environment
 self.memoryIndex = memoryIndex
 self.memoryTopics = memoryTopics
 self.extraSystemContext = extraSystemContext
 self.turnOverlay = turnOverlay
 self.currentTurnFocus = currentTurnFocus
 self.recoveryNotes = recoveryNotes
 self.exampleModuleIDs = exampleModuleIDs
 self.budgetPolicy = budgetPolicy ?? .default(for: profileID)
 }
}

internal struct PromptAssembly: Sendable, Codable, Equatable {
 internal let profileID: PromptProfileID
 internal let sections: [PromptSection]
 internal let stableDynamicBoundaryIndex: Int
 internal let renderedPrompt: String
 internal let diagnostics: PromptAssemblyDiagnostics
 internal let selectedExampleModules: [PromptExampleModuleID]
 internal let budgetPolicy: PromptBudgetPolicy

 internal var rendered: String { renderedPrompt }
}

internal typealias PromptCompositionDiagnostics = PromptAssemblyDiagnostics
internal typealias PromptCompilation = PromptAssembly
internal typealias PromptLayer = PromptSectionLayer
