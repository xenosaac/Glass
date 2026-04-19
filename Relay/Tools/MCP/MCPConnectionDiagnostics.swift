import Foundation

enum MCPConnectionPhase: String, CaseIterable, Identifiable, Sendable {
 case reachability
 case protocolCompatibility = "protocol"
 case initialize
 case discovery

 var id: String { rawValue }

 var title: String {
 switch self {
 case .reachability: return "Reachability"
 case .protocolCompatibility: return "Protocol"
 case .initialize: return "Initialize"
 case .discovery: return "Discovery"
 }
 }
}

enum MCPConnectionPhaseState: Sendable {
 case success
 case warning
 case failure
 case skipped
}

enum MCPConnectionFailureCategory: String, Sendable {
 case network
 case timeout
 case tls
 case httpStatus
 case acceptRejected
 case authRejected
 case protocolVersionMismatch
 case missingSessionID
 case sseUnsupportedYet
 case malformedResponse
 case jsonRPCError
 case zeroTools
}

struct MCPConnectionFailure: Sendable {
 let category: MCPConnectionFailureCategory
 let headline: String
 let detail: String?
 let remediation: String?
}

struct MCPConnectionDiagnostic: Identifiable, Sendable {
 let phase: MCPConnectionPhase
 let state: MCPConnectionPhaseState
 let message: String?
 let failure: MCPConnectionFailure?

 var id: String { phase.id }

 static func success(_ phase: MCPConnectionPhase, message: String) -> MCPConnectionDiagnostic {
 MCPConnectionDiagnostic(phase: phase, state: .success, message: message, failure: nil)
 }

 static func warning(_ phase: MCPConnectionPhase, message: String, failure: MCPConnectionFailure) -> MCPConnectionDiagnostic {
 MCPConnectionDiagnostic(phase: phase, state: .warning, message: message, failure: failure)
 }

 static func failure(_ phase: MCPConnectionPhase, failure: MCPConnectionFailure) -> MCPConnectionDiagnostic {
 MCPConnectionDiagnostic(phase: phase, state: .failure, message: failure.headline, failure: failure)
 }

 static func skipped(_ phase: MCPConnectionPhase) -> MCPConnectionDiagnostic {
 MCPConnectionDiagnostic(phase: phase, state: .skipped, message: nil, failure: nil)
 }
}

struct MCPConnectionReport: Sendable {
 let diagnostics: [MCPConnectionDiagnostic]
 let toolCount: Int?
 let toolNames: [String]
 let errorMessage: String?
 let checkedAt: Date
 let negotiatedProtocolVersion: String?
}
