import SwiftUI

/// Shared heavy services — initialized once at app level, injected into sessions.
/// Avoids re-creating CactusModelHost on every session switch.
@Observable
final class SharedServices {
 enum State {
 case notLoaded
 case loading
 case loaded
 case failed(String)
 }

 private(set) var state: State = .notLoaded
 private(set) var modelHost: CactusModelHost?
 private(set) var fileProvider: FileProvider?
 private(set) var appIntentsService: SystemIntentsService?
 private(set) var mcpProvider: MCPToolProvider?
 private(set) var gmailService: GmailServiceImpl?
 private(set) var voiceRuntime: SharedVoiceRuntime?
 private(set) var functionGemmaRuntime: SharedFunctionGemmaRuntime?
 /// Process-wide MemoryStore actor. Single instance so concurrent
 /// Settings / agent writes serialize through one actor and don't
 /// trample `MEMORY.md` mid-write.
 private(set) var memoryStore: MemoryStore?

 /// eagerly construct `memoryStore` at
 /// `SharedServices` init time so any consumer that captures
 /// `sharedServices.memoryStore` later (notably
 /// `MemoryWritebackCoordinator` from `ChatViewModel.init()`) never
 /// sees a stale nil during the cold-start warm window.
 ///
 /// Without this, on a 16s Gemma cold-load the chat session is
 /// constructed long before `loadIfNeeded` runs to set `memoryStore`,
 /// the coordinator captures the still-nil reference, and
 /// deterministic writeback silently no-ops for the rest of the
 /// session — surfaced by Isaac's device test the same day:
 /// `My name is Isaac` produced no `[Memory] writeback wrote` log.
 ///
 /// `MemoryStore` is a synchronous actor constructor with no I/O;
 /// the directory is created lazily on first read/write via
 /// `ensureDirectory`, so eager init is free.
 init() {
 self.memoryStore = MemoryStore
 }

 @MainActor
 func loadIfNeeded(sessionIndex: SessionIndex? = nil) async {
 guard case .notLoaded = state else { return }
 state = .loading
 let gemmaBootstrapStartedAt = CFAbsoluteTimeGetCurrent()

 // 1. Load model. If the app bundles Gemma, hydrate it into a writable
 // Application Support cache first — loading directly from the
 // read-only app bundle fails on device.
 let resolved: AppPaths.ResolvedModel
 do {
 guard let prepared = try await AppPaths.prepareGemmaE2BForLoad else {
 state = .failed("Gemma-4-E2B is missing from the app bundle. Reinstall the app to recover.")
 return
 }
 resolved = prepared
 } catch {
 state = .failed("Failed to prepare bundled Gemma-4-E2B for loading: \(error.localizedDescription)")
 return
 }
 let gemmaPrepareMs = (CFAbsoluteTimeGetCurrent() - gemmaBootstrapStartedAt) * 1000
 let modelPath = resolved.url.path
 #if DEBUG
 print("MODEL_RESOLVE gemma source=\(resolved.source.rawValue) path=\(modelPath)")
 #endif
 let host = CactusModelHost(modelPath: modelPath)
 let gemmaLoadStartedAt = CFAbsoluteTimeGetCurrent()
 do {
 try await host.load
 modelHost = host
 } catch {
 let sourceNote = resolved.source == .documents
 ? "Gemma-4-E2B from the Documents fallback"
 : "hydrated bundled Gemma-4-E2B"
 state = .failed("Failed to load \(sourceNote): \(error.localizedDescription)")
 return
 }
 let gemmaLoadMs = (CFAbsoluteTimeGetCurrent() - gemmaLoadStartedAt) * 1000
 print(
 "[MODEL_BOOT] gemma_ready source=\(resolved.source.rawValue) " +
 "prepare_ms=\(String(format: "%.0f", gemmaPrepareMs)) " +
 "load_ms=\(String(format: "%.0f", gemmaLoadMs)) " +
 "total_ms=\(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - gemmaBootstrapStartedAt) * 1000))"
 )

 // 1b. Voice runtime — prewarm Whisper immediately after primary Gemma
 // is ready so the first mic tap is not serialized behind lower-priority
 // bootstrap work like tool-specialist warmup.
 //
 // flag-aware Whisper prewarm skip.
 // After R7-C, `VoiceEngine.useAppleSpeech == true` and the Apple
 // Speech path never calls `ensureWhisperReady`. Loading Whisper
 // at boot then is dead weight (~6s of CPU contention competing
 // with the first Gemma inference + ~177MB RAM held by an unused
 // model). Skipping it keeps `SharedVoiceRuntime` intact and the
 // Cactus Whisper fallback still works — just flip the flag and
 // prewarm resumes automatically.
 let runtime = SharedVoiceRuntime
 voiceRuntime = runtime
 let functionRuntime = SharedFunctionGemmaRuntime
 functionGemmaRuntime = functionRuntime
 Task {
 if VoiceEngine.useAppleSpeech {
 print("[VOICE_PREWARM] skipped — apple_speech is default backend")
 } else {
 await runtime.prewarmWhisper
 }
 await functionRuntime.prewarmIfAvailable(trigger: "post_voice_startup")
 }

 // 2. FileProvider — workspace-bookmark authorization store. Runs
 // off the main actor.
 fileProvider = await SharedServices.loadFileProvider

 // 2b. MemoryStore — eagerly constructed in `SharedServices.init()`
 // (R6-Mem hotfix ). Kept here as a no-op marker for
 // historical clarity; never re-create at this point because any
 // consumer that captured the eager-init reference would be left
 // pointing at the previous instance.

 // 3. SystemIntentsService
 appIntentsService = SystemIntentsService

 // 4. MCPToolProvider
 if RelayConfig.shared.mcpEnabled {
 mcpProvider = MCPToolProvider
 }

 // 5. Gmail (native embedded provider — single-account personal workflow).
 gmailService = GmailServiceImpl

 state = .loaded
 }

 /// Construct + initialize a FileProvider off the main actor. Any error is
 /// logged and a freshly-constructed (uninitialized) FileProvider is still
 /// returned, so downstream code can keep its `fileProvider != nil`
 /// assumption.
 private nonisolated static func loadFileProvider() async -> FileProvider {
 let fp = FileProvider
 do {
 try await fp.initialize
 } catch {
 print("⚠️ FileProvider init failed: \(error)")
 }
 return fp
 }

 /// Retry bootstrap from a clean state. Safe to call from `.failed` or
 /// `.loaded`; returns early if already `.loading` to prevent double-init.
 @MainActor
 func reload(sessionIndex: SessionIndex? = nil) async {
 if case .loading = state { return }
 modelHost = nil
 fileProvider = nil
 appIntentsService = nil
 mcpProvider = nil
 gmailService = nil
 // keep `memoryStore` alive across
 // `reload`. The store is a file-IO actor with no in-memory
 // state worth resetting, AND any `MemoryWritebackCoordinator`
 // that captured the eager-init reference would be left
 // pointing at a discarded instance otherwise. Other services
 // (modelHost, fileProvider, etc.) are re-resolved each turn
 // through `sharedServices.X`, so nilling them is fine.
 functionGemmaRuntime = nil
 state = .notLoaded
 await loadIfNeeded(sessionIndex: sessionIndex)
 }
}

/// Root app shell with sidebar navigation.
///
/// Uses `NavigationSplitView` for adaptive layout:
/// iPhone: Sidebar collapses to drawer/sheet
/// iPad: Persistent sidebar
///
/// The body branches on `SharedServices.state` so users can NEVER drop into
/// a non-functional chat when the on-device model is missing. Cf. the old
/// behavior where ChatView was always shown and `SharedServices.state.failed`
/// was read only indirectly inside `ChatViewModel`.

/// Once-per-process cold-start flag.
private enum ColdStart {
 static var pending = true
}

internal enum SessionSelectionPolicy {
 internal static func detailSessionID(currentSessionId: String?) -> String? {
 currentSessionId
 }

 internal static func persistedSessionID(
 afterSelectionChange newSelection: String?,
 currentPersistedSessionId: String?,
 sessions: [SessionMetadata]
 ) -> String? {
 if let newSelection {
 return newSelection
 }
 return sessions.isEmpty ? nil : currentPersistedSessionId
 }

 internal static func refreshedSelection(
 currentSessionId: String?,
 sessions: [SessionMetadata]
 ) -> String? {
 guard let currentSessionId else { return nil }
 if sessions.contains(where: { $0.id == currentSessionId }) {
 return currentSessionId
 }
 return sessions.first?.id
 }
}

struct RelayAppShell: View {
 @State private var sessionIndex = SessionIndex
 @State private var sessions: [SessionMetadata] = []
 @State private var currentSessionId: String?
 @AppStorage("lastSessionId") private var persistedSessionId: String?
 @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
 @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
 @State private var showingSettings = false
 @State private var showingWorkspacePicker = false
 @State private var workspaceError: String?
 @State private var pendingAutoVoiceSessionId: String?
 @State private var pendingTextForSession: (sessionId: String, text: String)?
 @State private var initialLaunchResolved = false
 @Environment(\.scenePhase) private var scenePhase
 @Environment(\.colorScheme) private var systemColorScheme
 @State private var isLoading = true
 @State private var sharedServices = SharedServices
 /// Observed so the Settings sheet's `.preferredColorScheme` below reacts
 /// to changes. Sheets on iOS present in a separate UIWindow and do NOT
 /// inherit the WindowGroup's preferredColorScheme set in `RelayApp`, so
 /// this app has to apply it to the sheet content explicitly.
 @State private var themeManager = ThemeManager.shared

 var body: some View {
 Group {
 switch sharedServices.state {
 case .failed(let msg):
 ModelUnavailableView(
 message: msg,
 whisperMissing: AppPaths.resolveWhisperSmall == nil
 ) {
 Task { await sharedServices.reload(sessionIndex: sessionIndex) }
 }
 case .notLoaded, .loading, .loaded:
 // Mount the shell immediately on cold launch instead of
 // blocking behind PreparingView until every background
 // service finishes. The send gate still lives in the
 // composer (`InputBar.isReady` ← `ChatViewModel.isModelReady`
 // ← `sharedServices.modelHost != nil`), so no turn can
 // submit before Gemma finishes loading. During the warm
 // window the user can already scroll the sidebar, open
 // sessions, read history, and enter Settings — matching
 // the big-app pattern (Messages / ChatGPT / Claude iOS
 // never show a full-screen "preparing" blocker on launch).
 mainShell
 }
 }
 .task {
 // One-shot bootstrap. Retry from the blocker re-enters this path
 // via `SharedServices.reload(sessionIndex:)` (which calls
 // `loadIfNeeded(sessionIndex:)`). sessionIndex is threaded in so
 // the memory-palace rebuild path can rehydrate conversations +
 // preferences + contexts from session JSONL without a separate
 // dependency-injection pass.
 await sharedServices.loadIfNeeded(sessionIndex: sessionIndex)
 }
 }

 // MARK: - Main shell (rendered during warm + loaded; only `.failed` swaps it out)

 private var mainShell: some View {
 NavigationSplitView(
 columnVisibility: $columnVisibility,
 preferredCompactColumn: $preferredCompactColumn
 ) {
 SessionSidebar(
 sessions: sessions,
 currentSessionId: $currentSessionId,
 onSelectSession: { sessionId in
 Task { await activateSession(sessionId) }
 },
 onNewSession: { await createNewSession },
 onDeleteSession: deleteSession,
 onShowSettings: { showingSettings = true },
 onNewSessionInFolder: { showingWorkspacePicker = true }
 )
 } detail: {
 if let sessionId = SessionSelectionPolicy.detailSessionID(
 currentSessionId: currentSessionId
 ) {
 let shouldAutoVoice = pendingAutoVoiceSessionId == sessionId
 let autoText: String? = (pendingTextForSession?.sessionId == sessionId)
 ? pendingTextForSession?.text
 : nil
 ChatView(
 sessionId: sessionId,
 sessionIndex: sessionIndex,
 sharedServices: sharedServices,
 autoStartVoice: shouldAutoVoice,
 autoSubmitText: autoText,
 onSessionUpdated: refreshSessions,
 onShowSessionList: {
 preferredCompactColumn = .sidebar
 },
 onAutoVoiceConsumed: { id in
 // Defensive id-match: a delayed callback on an old
 // session must NOT clobber a freshly-set pending
 // for a different session the user has since
 // switched to.
 if pendingAutoVoiceSessionId == id {
 pendingAutoVoiceSessionId = nil
 }
 },
 onAutoTextConsumed: { id in
 if pendingTextForSession?.sessionId == id {
 pendingTextForSession = nil
 }
 }
 )
 .id(sessionId)
 } else {
 emptyState
 }
 }
 .navigationSplitViewStyle(.balanced)
 .sheet(isPresented: $showingSettings) {
 SettingsView(
 sessionIndex: sessionIndex,
 sharedServices: sharedServices,
 onClearAllSessions: { await clearAllHistoryFromShell }
 )
 // Sheets present in a separate UIWindow; they don't inherit
 // the WindowGroup-level preferredColorScheme. Apply it here
 // so the picker changes the sheet live, not just the app
 // behind it.
 // IMPORTANT: Passing `nil` here for "Follow System" can leave
 // a stale scheme on an already-presented sheet (e.g. Light ->
 // Follow System). Resolve to the live environment scheme
 // instead so the sheet always tracks system appearance.
 .preferredColorScheme(
 themeManager.mode.colorScheme ?? systemColorScheme
 )
 }
 .sheet(isPresented: $showingWorkspacePicker) {
 FolderPicker { url in
 showingWorkspacePicker = false
 Task { await createNewSession(workspace: url) }
 } onCancel: {
 showingWorkspacePicker = false
 }
 }
 .alert("Workspace Unavailable", isPresented: Binding(
 get: { workspaceError != nil },
 set: { if !$0 { workspaceError = nil } }
 )) {
 Button("OK") { workspaceError = nil }
 } message: {
 Text(workspaceError ?? "")
 }
 .task {
 // Fires on first entry to .loaded. Re-fires cleanly if we return
 // here after a Retry (SwiftUI attaches a fresh .task per view
 // identity).
 await loadSessions

 // Consume shortcut-initiated launch action if present.
 let launchAction = LaunchActionStore.consume
 if launchAction != .none {
 ColdStart.pending = false
 await consumeLaunchAction(launchAction)
 } else if ColdStart.pending {
 ColdStart.pending = false
 // Plain cold launch — just create a session. NO auto-voice.
 // Auto-voice only triggers for .startVoice shortcut (handled
 // in consumeLaunchAction above).
 await createNewSession
 }

 initialLaunchResolved = true
 }
 .onChange(of: currentSessionId) { _, newValue in
 persistedSessionId = SessionSelectionPolicy.persistedSessionID(
 afterSelectionChange: newValue,
 currentPersistedSessionId: persistedSessionId,
 sessions: sessions
 )
 }
 .onChange(of: scenePhase) { _, newPhase in
 guard initialLaunchResolved else { return }
 if newPhase == .active {
 let action = LaunchActionStore.consume
 if action != .none {
 Task { await consumeLaunchAction(action) }
 }
 }
 }
 }

 // MARK: - Empty State

 private var emptyState: some View {
 VStack(spacing: GlassSpacing.l) {
 Image("AppLogo")
 .resizable
 .scaledToFit
 .frame(width: 64, height: 64)
 .clipShape(RetroCutShape(cut: 10))

 Text("Glass")
 .glassType(.title)

 Text("Your on-device AI agent")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)

 Button {
 Task { await createNewSession }
 } label: {
 Label("New Chat", systemImage: "plus")
 }
 .buttonStyle(.relayGlass(.primary, burst: .buttonTap))
 .padding(.top, GlassSpacing.m)
 }
 .frame(maxWidth: .infinity, maxHeight: .infinity)
 }

 // MARK: - Session Management

 private func loadSessions() async {
 do {
 try await sessionIndex.load
 sessions = await sessionIndex.all

 if let persisted = persistedSessionId,
 sessions.contains(where: { $0.id == persisted }) {
 currentSessionId = persisted
 } else if let current = currentSessionId,
 sessions.contains(where: { $0.id == current }) {
 // Keep the existing selection if still valid.
 } else {
 currentSessionId = sessions.first?.id
 }
 await purgeOrphanedEmptySessions
 sessions = await sessionIndex.all
 currentSessionId = SessionSelectionPolicy.refreshedSelection(
 currentSessionId: currentSessionId,
 sessions: sessions
 )
 preferredCompactColumn = currentSessionId == nil ? .sidebar : .detail
 } catch {
 print("Failed to load sessions: \(error)")
 }
 isLoading = false
 }

 private func refreshSessions() {
 Task {
 sessions = await sessionIndex.all
 currentSessionId = SessionSelectionPolicy.refreshedSelection(
 currentSessionId: currentSessionId,
 sessions: sessions
 )
 await purgeOrphanedEmptySessions
 sessions = await sessionIndex.all
 currentSessionId = SessionSelectionPolicy.refreshedSelection(
 currentSessionId: currentSessionId,
 sessions: sessions
 )
 if currentSessionId == nil {
 preferredCompactColumn = .sidebar
 }
 }
 }

 /// Creates a new session and returns its ID. Returns nil on failure.
 @discardableResult
 private func createNewSession(workspace: URL? = nil) async -> String? {
 if let url = workspace, let fp = sharedServices.fileProvider {
 do {
 try await fp.addAuthorization(url: url)
 } catch {
 workspaceError = "Could not authorize folder \"\(url.lastPathComponent)\". Chat created without workspace."
 return await createNewSession(workspace: nil)
 }
 }

 if workspace == nil, let reusableSessionID = reusableEmptySessionID {
 await activateSession(reusableSessionID)
 return reusableSessionID
 }

 do {
 let session = try await sessionIndex.create(workspace: workspace)
 sessions = await sessionIndex.all
 await activateSession(session.id)

 // Workspace folder indexing used to mine files into the MemoryPalace
 // here. With the palace removed, workspace attachment is pure UI
 // state (the user knows what they attached) — no indexing step.
 return session.id
 } catch {
 print("Failed to create session: \(error)")
 return nil
 }
 }

 private func consumeLaunchAction(_ action: PendingLaunchAction) async {
 switch action {
 case .none:
 return
 case .startVoice:
 // Capture session ID immediately — don't read currentSessionId after async waits
 // since user could switch sessions during model load.
 guard let sessionId = await createNewSession else { return }
 print("[COLD_VOICE] createdSessionId=\(sessionId)")
 await waitForModelReady
 if sharedServices.modelHost != nil {
 pendingAutoVoiceSessionId = sessionId
 print("[COLD_VOICE] pendingSetForSessionId=\(sessionId)")
 }
 case .askText(let text):
 guard let sessionId = await createNewSession else { return }
 print("[COLD_TEXT] createdSessionId=\(sessionId)")
 await waitForModelReady
 if sharedServices.modelHost != nil {
 pendingTextForSession = (sessionId, text)
 print("[COLD_TEXT] pendingSetForSessionId=\(sessionId)")
 }
 }
 }

 /// Shell-level bounded wait for Gemma readiness. Mirrors the previous
 /// in-view poll but lives at the shell so cold-launch orchestration is
 /// fully deterministic: the shell decides when to signal ChatView, and
 /// the view only reacts to the prop flip (via `.onChange`). Exits on
 /// `.failed` so the outer blocker takes over; caller re-checks
 /// `modelHost != nil` after this returns.
 @MainActor
 private func waitForModelReady() async {
 while sharedServices.modelHost == nil {
 if case .failed = sharedServices.state { return }
 try? await Task.sleep(nanoseconds: 100_000_000)
 }
 }

 private func deleteSession(_ id: String) {
 Task {
 await deleteSessionImmediately(id)
 }
 }

 /// Shell-owned Clear Chat History — atomic storage wipe plus the visible
 /// state reset the Settings view can't do on its own. SettingsView used
 /// to iterate `sessionIndex.delete(id:)` per row but never updated the
 /// shell's `sessions` / `currentSessionId` state, so the sidebar kept
 /// showing ghost rows until the next explicit refresh.
 @MainActor
 private func clearAllHistoryFromShell() async {
 do {
 try await sessionIndex.deleteAll
 } catch {
 print("Clear chat history failed: \(error)")
 return
 }
 sessions = []
 currentSessionId = nil
 persistedSessionId = nil
 preferredCompactColumn = .sidebar
 // Every session is gone — clear any pending cold-launch / shortcut
 // signals unconditionally. They can only target session ids that
 // no longer exist.
 pendingAutoVoiceSessionId = nil
 pendingTextForSession = nil
 }

 @MainActor
 private func activateSession(_ sessionId: String) async {
 let abandonedEmptySessionID =
 currentSessionId != sessionId && isEmptySession(id: currentSessionId)
 ? currentSessionId
 : nil

 currentSessionId = sessionId
 persistedSessionId = sessionId
 preferredCompactColumn = .detail

 if let abandonedEmptySessionID {
 await cleanupEmptySession(abandonedEmptySessionID)
 }
 }

 @MainActor
 private func purgeOrphanedEmptySessions() async {
 let keepEmptySessionID = isEmptySession(id: currentSessionId) ? currentSessionId : nil
 let orphanedEmptySessionIDs = sessions
 .filter { $0.messageCount == 0 && $0.id != keepEmptySessionID }
 .map(\.id)

 guard !orphanedEmptySessionIDs.isEmpty else { return }

 for id in orphanedEmptySessionIDs {
 do {
 try await sessionIndex.delete(id: id)
 clearStateForDeletedSession(id)
 } catch {
 print("Failed to purge empty session \(id): \(error)")
 }
 }
 }

 @MainActor
 private func cleanupEmptySession(_ id: String) async {
 guard isEmptySession(id: id) else { return }
 await deleteSessionImmediately(id)
 }

 @MainActor
 private func deleteSessionImmediately(_ id: String) async {
 let wasDeletingCurrentSession = currentSessionId == id

 do {
 try await sessionIndex.delete(id: id)
 } catch {
 print("Failed to delete session: \(error)")
 return
 }

 clearStateForDeletedSession(id)
 sessions = await sessionIndex.all
 currentSessionId = SessionSelectionPolicy.refreshedSelection(
 currentSessionId: currentSessionId,
 sessions: sessions
 )
 await purgeOrphanedEmptySessions
 sessions = await sessionIndex.all
 currentSessionId = SessionSelectionPolicy.refreshedSelection(
 currentSessionId: currentSessionId,
 sessions: sessions
 )

 if wasDeletingCurrentSession {
 persistedSessionId = currentSessionId
 }

 preferredCompactColumn = currentSessionId == nil ? .sidebar : preferredCompactColumn
 }

 @MainActor
 private func clearStateForDeletedSession(_ id: String) {
 if currentSessionId == id {
 currentSessionId = nil
 }
 if persistedSessionId == id {
 persistedSessionId = nil
 }
 if pendingAutoVoiceSessionId == id {
 pendingAutoVoiceSessionId = nil
 }
 if pendingTextForSession?.sessionId == id {
 pendingTextForSession = nil
 }
 }

 private func reusableEmptySessionID() -> String? {
 guard let currentSessionId, isEmptySession(id: currentSessionId) else { return nil }
 return currentSessionId
 }

 private func isEmptySession(id: String?) -> Bool {
 guard let id else { return false }
 return sessions.first(where: { $0.id == id })?.messageCount == 0
 }
}

#Preview {
 RelayAppShell
}
