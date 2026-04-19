import Foundation

internal enum TurnClassification: String, Sendable, Codable, Equatable {
 case socialOpener
 case question
 case declarativeFact
 case factRecallKnown
 case factRecallUnknown
 case referentialFollowup
 case repairCue
 case transportCheck
 case toolFollowup
 case ambiguous
}

internal enum BindingPriority: String, Sendable, Codable, Equatable {
 case latestTurnOnly
 case latestTurnWithVisibleFacts
 case latestTurnWithRecentTail
 case latestTurnWithRetrieval
 case latestTurnWithFactsAndRetrieval
}

internal struct VisibleFactRecord: Sendable, Codable, Equatable {
 internal let text: String
 internal let sourceTurnIndex: Int
 internal let sourceClassification: TurnClassification
}

internal struct BoundConversationTurn: Sendable, Codable, Equatable {
 internal let role: String
 internal let text: String
}

internal struct TurnOverlayBundle: Sendable, Codable, Equatable {
 internal let classification: TurnClassification
 internal let bindingPriority: BindingPriority
 internal let latestUserText: String
 internal let visibleFacts: [VisibleFactRecord]
 internal let recentTail: [BoundConversationTurn]
 internal let retrievalArtifacts: [ScoredContextArtifact]
 internal let summarySnippet: String?
 internal let instructions: [String]
}
