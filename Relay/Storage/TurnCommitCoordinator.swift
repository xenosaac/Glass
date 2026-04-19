import Foundation

/// Owns the fixed post-accept / post-turn commit order for one session.
/// Transcript persistence stays canonical; failure truth is captured in
/// runtime sidecars instead of fake assistant transcript rows.
internal actor TurnCommitCoordinator {
 private let sessionId: String
 private let sessionStore: SessionStore
 private let sessionIndex: SessionIndex
 private let memoryWritebackCoordinator: MemoryWritebackCoordinator
 private let runtimeSidecarStore: RuntimeSidecarStore

 internal init(
 sessionId: String,
 sessionStore: SessionStore,
 sessionIndex: SessionIndex,
 memoryWritebackCoordinator: MemoryWritebackCoordinator,
 runtimeSidecarStore: RuntimeSidecarStore
 ) {
 self.sessionId = sessionId
 self.sessionStore = sessionStore
 self.sessionIndex = sessionIndex
 self.memoryWritebackCoordinator = memoryWritebackCoordinator
 self.runtimeSidecarStore = runtimeSidecarStore
 }

 internal func commitAcceptedUserTurn(
 turnID: UUID,
 message: RelayMessage,
 firstUserText: String?
 ) async -> TurnCommitTrace {
 var trace = TurnCommitTrace()
 do {
 try await sessionStore.append(message)
 trace.append(stage: .acceptedUserTranscriptAppended, succeeded: true, detail: turnID.uuidString)
 } catch {
 trace.append(stage: .acceptedUserTranscriptAppended, succeeded: false, detail: error.localizedDescription)
 }

 do {
 try await sessionIndex.recordMessage(sessionId: sessionId, firstUserText: firstUserText)
 trace.append(stage: .acceptedUserIndexed, succeeded: true)
 } catch {
 trace.append(stage: .acceptedUserIndexed, succeeded: false, detail: error.localizedDescription)
 }
 return trace
 }

 internal func commitCompletedTurn(
 acceptedUserMessage: RelayMessage,
 assistantMessage: RelayMessage,
 wasVoiceTurn: Bool,
 trace: TurnCommitTrace
 ) async -> TurnCommitTrace {
 var updatedTrace = trace
 do {
 try await sessionStore.append(assistantMessage)
 updatedTrace.append(stage: .completedAssistantTranscriptAppended, succeeded: true)
 } catch {
 updatedTrace.append(stage: .completedAssistantTranscriptAppended, succeeded: false, detail: error.localizedDescription)
 }

 do {
 try await sessionIndex.recordMessage(sessionId: sessionId)
 updatedTrace.append(stage: .completedAssistantIndexed, succeeded: true)
 } catch {
 updatedTrace.append(stage: .completedAssistantIndexed, succeeded: false, detail: error.localizedDescription)
 }

 await memoryWritebackCoordinator.afterTurn(
 sessionId: sessionId,
 userMessage: acceptedUserMessage,
 assistantMessage: assistantMessage,
 wasVoiceTurn: wasVoiceTurn
 )
 updatedTrace.append(stage: .completedMemoryWriteback, succeeded: true)
 return updatedTrace
 }

 internal func commitFailedTurn(
 runArtifacts: TurnRunArtifacts,
 canonicalTranscriptSnapshot: [RelayMessage],
 trace: TurnCommitTrace
 ) async -> TurnCommitTrace {
 var updatedTrace = trace
 guard let failureKind = runArtifacts.exit.failureKind else {
 updatedTrace.append(
 stage: .failureSidecarWritten,
 succeeded: false,
 detail: "No failure sidecar for completed turn"
 )
 return updatedTrace
 }

 do {
 updatedTrace.append(stage: .failureSidecarWritten, succeeded: true)
 let sidecar = TurnRuntimeSidecar(
 sessionId: sessionId,
 turnID: runArtifacts.turnID,
 failureKind: failureKind,
 canonicalTranscriptSnapshot: canonicalTranscriptSnapshot,
 acceptedUserMessage: runArtifacts.acceptedUserMessage,
 attempts: runArtifacts.attempts,
 commitTrace: updatedTrace,
 recoveryState: runArtifacts.recoveryState,
 terminalErrorMessage: runArtifacts.recoveryState.lastErrorMessage
 )
 _ = try await runtimeSidecarStore.save(sidecar)
 } catch {
 updatedTrace.entries.removeLast
 updatedTrace.append(stage: .failureSidecarWritten, succeeded: false, detail: error.localizedDescription)
 }

 return updatedTrace
 }
}
