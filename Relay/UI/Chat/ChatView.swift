import SwiftUI
import MessageUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// Main chat conversation view.
///
/// Displays message history, streaming responses, tool executions,
/// and provides input for new messages.
struct ChatView: View {
 let sessionId: String
 let sessionIndex: SessionIndex
 let sharedServices: SharedServices
 var autoStartVoice: Bool = false
 var autoSubmitText: String? = nil
 let onSessionUpdated:  () -> Void
 var onShowSessionList: (() -> Void)? = nil
 /// Called exactly once after cold-launch auto-voice has actually fired
 /// for this session. Shell uses this to clear
 /// `pendingAutoVoiceSessionId` so later remounts of the same session id
 /// don't retrigger. Fires AFTER the latch flips and `startVoice` runs
 /// never on a guard bail. Shell must re-match the id before clearing
 /// so a late callback can't clobber a freshly-set pending for a
 /// different session.
 var onAutoVoiceConsumed: ((String) -> Void)? = nil
 /// Same contract as `onAutoVoiceConsumed` but for the App-Shortcut
 /// `autoSubmitText` path — fires after `sendMessage` has been called.
 var onAutoTextConsumed: ((String) -> Void)? = nil

 @State private var viewModel: ChatViewModel?
 @State private var composerDraft = ComposerDraft
 @State private var autoVoiceError: String?
 @State private var didAutoStartVoice = false
 @State private var didAutoSubmitText = false
 @State private var showingAlternateModel = false
 @State private var selectedPhotoItems: [PhotosPickerItem] = []
 @State private var isAccessoryDrawerPresented = false
 @Environment(\.horizontalSizeClass) private var horizontalSizeClass

 var body: some View {
 messageList
 .overlay {
 if isAccessoryDrawerPresented {
 Color.black.opacity(0.001)
 .ignoresSafeArea
 .contentShape(Rectangle)
 .onTapGesture {
 withAnimation(.easeOut(duration: 0.18)) {
 isAccessoryDrawerPresented = false
 }
 }
 }
 }
 .scrollDismissesKeyboard(.interactively)
 .safeAreaInset(edge: .top, spacing: 0) {
 // Top stack — compact top-bar cluster + error banner. The
 // chat title is intentionally gone; active model identity now
 // lives in the left-top chip, and tapping it only reveals the
 // inactive alternate model below.
 VStack(spacing: GlassSpacing.s) {
 if horizontalSizeClass == .compact {
 HStack(alignment: .center, spacing: GlassSpacing.s) {
 Button {
 onShowSessionList?
 } label: {
 ConversationListGlyph
 .frame(width: 44, height: 44)
 .contentShape(Circle)
 }
 .buttonStyle(.relayGlass(.iconSidebar))
 .accessibilityLabel("Conversation list")

 VStack(alignment: .leading, spacing: GlassSpacing.xs) {
 Button {
 withAnimation(RetroMotion.chipToggle) {
 showingAlternateModel.toggle
 }
 } label: {
 ChatModelChip(model: activeHeaderModel)
 }
 .buttonStyle(.relaySurfaceFeedback)
 .accessibilityLabel("Current model: \(activeHeaderModel.rawValue)")
 .accessibilityHint("Shows available models")

 if showingAlternateModel {
 ChatModelChip(
 model: activeHeaderModel.alternate,
 active: false
 )
 .transition(.move(edge: .top).combined(with: .opacity))
 }
 }

 Spacer(minLength: 0)
 }
 }

 if let err = viewModel?.error, !err.isEmpty {
 errorBanner(err)
 }
 }
 .padding(.top, GlassSpacing.s)
 .padding(.horizontal, GlassSpacing.m)
 }
 .safeAreaInset(edge: .bottom, spacing: 0) {
 // Composer stack — floating InputBar only. The old status bar
 // is intentionally gone; model identity now lives in the
 // top-left model capsule next to the conversation-list glyph.
 ZStack(alignment: .bottom) {
 composerBackdrop

 VStack(spacing: GlassSpacing.s) {
 // live partial transcript while
 // voice recording. Whisper streams partials at chunk
 // cadence; the bubble vanishes on finalize.
 LivePartialTranscriptView(
 isVisible: viewModel?.isVoiceActive ?? false,
 partialText: viewModel?.voiceEngine?.partialTranscript ?? ""
 )
 composerInputBar
 }
 .padding(.horizontal, GlassSpacing.m)
 .padding(.bottom, GlassSpacing.s)
 .animation(.easeOut(duration: 0.18), value: viewModel?.isVoiceActive ?? false)
 }
 }
 .navigationBarBackButtonHidden(horizontalSizeClass == .compact)
 .toolbar {
 if horizontalSizeClass != .compact {
 ToolbarItem(placement: .topBarLeading) {
 ChatModelChip(model: activeHeaderModel)
 }
 }
 }
 .task(id: sessionId) {
 // Load the session (model-independent) immediately. Cold-launch
 // auto-voice / auto-text handling moved out of this task and
 // into `.onChange` reactors below — the shell only flips the
 // autoStartVoice / autoSubmitText props after Gemma is actually
 // ready, so reacting to the prop transition is deterministic.
 // The previous in-task `waitForModelReadyOrFailure` poll raced
 // with SwiftUI's one-shot `.task` lifecycle: the task captured
 // the initial (false) prop value and never re-entered the
 // auto-voice branch after the shell flipped the prop.
 await loadSession
 triggerAutoStartVoiceIfNeeded
 triggerAutoSubmitTextIfNeeded
 }
 .onChange(of: autoStartVoice) { _, _ in
 triggerAutoStartVoiceIfNeeded
 }
 .onChange(of: autoSubmitText) { _, _ in
 triggerAutoSubmitTextIfNeeded
 }
 .onChange(of: activeHeaderModel) { _, _ in
 showingAlternateModel = false
 }
 .alert("Voice Unavailable", isPresented: voiceUnavailablePresented) {
 Button("OK") { autoVoiceError = nil }
 } message: {
 voiceUnavailableMessage
 }
 .onChange(of: voiceEnginePhase) { _, newPhase in
 handleVoiceEnginePhaseChange(newPhase)
 }
 .sheet(item: mailComposeBinding) { data in
 if canSendMail {
 MailComposeView(data: data) { result in
 viewModel?.pendingMailCompose = nil
 }
 } else {
 VStack(spacing: GlassSpacing.s) {
 Text("Cannot send email")
 .glassType(.bodyEmphasis)
 Text("Mail is not configured on this device")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 Button("Dismiss") { viewModel?.pendingMailCompose = nil }
 .buttonStyle(.relayGlass(.secondary, burst: .subtleTap))
 }
 }
 }
 .sheet(item: smsComposeBinding) { data in
 if canSendText {
 MessageComposeView(data: data) { result in
 viewModel?.pendingSMSCompose = nil
 }
 } else {
 VStack(spacing: GlassSpacing.s) {
 Text("Cannot send messages")
 .glassType(.bodyEmphasis)
 Text("iMessage is not configured on this device")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 Button("Dismiss") { viewModel?.pendingSMSCompose = nil }
 .buttonStyle(.relayGlass(.secondary, burst: .subtleTap))
 }
 }
 }
 .onChange(of: viewModel?.pendingComposerText) { _, newValue in
 // Dictation completion handoff: drain the view-model's
 // `pendingComposerText` into the composer field and clear it.
 // Replaces the old modal VoiceInputView path; user now reviews
 // and presses send explicitly instead of auto-submitting voice.
 guard let text = newValue, !text.isEmpty else { return }
 if composerDraft.text.isEmpty {
 composerDraft.text = text
 } else {
 // Append with a space so partial drafts compose cleanly
 // with a dictated continuation.
 composerDraft.text += (composerDraft.text.hasSuffix(" ") ? "" : " ") + text
 }
 viewModel?.pendingComposerText = nil
 }
 .sheet(isPresented: cameraPresentationBinding) {
 CameraCaptureView { capturedURL in
 composerDraft.cameraPresentation = false
 guard let capturedURL else { return }
 Task {
 await appendCapturedImage(from: capturedURL)
 }
 }
 }
 .photosPicker(
 isPresented: photosPickerPresentedBinding,
 selection: $selectedPhotoItems,
 maxSelectionCount: 10,
 matching: .images
 )
 .onChange(of: selectedPhotoItems) { _, newItems in
 guard !newItems.isEmpty else { return }
 Task {
 await appendSelectedPhotos(newItems)
 }
 }
 .fileImporter(
 isPresented: filesPickerPresentedBinding,
 allowedContentTypes: supportedAttachmentTypes,
 allowsMultipleSelection: true
 ) { result in
 Task {
 await appendImportedFiles(result)
 }
 }
 .alert(
 "Confirm Action",
 isPresented: confirmationPresented
 ) {
 Button("Approve") { respondToConfirmation(true) }
 Button("Deny", role: .cancel) { respondToConfirmation(false) }
 } message: {
 confirmationMessage
 }
 }

 private var voiceUnavailablePresented: Binding<Bool> {
 Binding(
 get: { autoVoiceError != nil },
 set: { if !$0 { autoVoiceError = nil } }
 )
 }

 private var voiceUnavailableMessage: Text {
 Text(autoVoiceError ?? "")
 }

 private var confirmationMessage: Text {
 Text(viewModel?.pendingConfirmation?.prompt ?? "")
 }

 private var confirmationPresented: Binding<Bool> {
 Binding(
 get: { viewModel?.pendingConfirmation != nil },
 set: { newValue in
 if !newValue { respondToConfirmation(false) }
 }
 )
 }

 private func respondToConfirmation(_ approved: Bool) {
 viewModel?.pendingConfirmation?.respond(approved)
 viewModel?.pendingConfirmation = nil
 }

 private func handleVoiceEnginePhaseChange(_ phase: VoiceEngine.Phase) {
 guard didAutoStartVoice else { return }
 guard case .error(let message) = phase else { return }
 autoVoiceError = message
 }

 private var composerInputBar: some View {
 InputBar(
 draft: $composerDraft,
 isRunning: viewModel?.isRunning ?? false,
 isVoiceActive: viewModel?.isVoiceActive ?? false,
 voiceAudioLevel: viewModel?.voiceEngine?.audioLevel ?? 0,
 isReady: viewModel?.isModelReady ?? true,
 isAccessoryDrawerPresented: isAccessoryDrawerPresented,
 onSend: sendMessage,
 onVoiceTap: handleVoiceTap,
 onAccessoryToggle: {
 withAnimation(.easeOut(duration: 0.18)) {
 isAccessoryDrawerPresented.toggle
 }
 },
 onAccessoryDismiss: {
 withAnimation(.easeOut(duration: 0.18)) {
 isAccessoryDrawerPresented = false
 }
 },
 onImportFilesTap: chooseDocuments,
 onTakePhotoTap: presentCamera,
 onChoosePhotosTap: choosePhotos,
 onRemoveImage: removePendingImage,
 onRemoveFile: removePendingFile
 )
 }

 private func chooseDocuments() {
 isAccessoryDrawerPresented = false
 composerDraft.pickerPresentation = .files
 }

 private func choosePhotos() {
 isAccessoryDrawerPresented = false
 composerDraft.pickerPresentation = .photos
 }

 private func handleVoiceTap() {
 // Tap toggles dictation. If already active, stop and transcribe
 // (the view-model drops the transcript into `pendingComposerText`
 // which the `.onChange` observer drains into `composerDraft.text`).
 // If idle, start a fresh dictation session.
 isAccessoryDrawerPresented = false
 if viewModel?.isVoiceActive == true {
 viewModel?.stopVoice
 } else {
 viewModel?.startVoice
 }
 }

 // handleVoiceLongPressStart/End removed —
 // long-press path replaced by tap-to-toggle in handleVoiceTap above.

 // Bindings for compose sheets (bridge @Observable to Binding<Item?>)
 private var mailComposeBinding: Binding<MailComposeData?> {
 Binding(
 get: { viewModel?.pendingMailCompose },
 set: { viewModel?.pendingMailCompose = $0 }
 )
 }

 private var voiceEnginePhase: VoiceEngine.Phase {
 viewModel?.voiceEngine?.phase ?? .idle
 }

 private var smsComposeBinding: Binding<MessageComposeData?> {
 Binding(
 get: { viewModel?.pendingSMSCompose },
 set: { viewModel?.pendingSMSCompose = $0 }
 )
 }

 // MARK: - Header

 private var activeHeaderModel: ChatHeaderModel {
 if viewModel?.routingTier == .cloud {
 return .gemini
 }
 return .gemma
 }

 // MARK: - Message List

 private var messageList: some View {
 ScrollViewReader { proxy in
 ScrollView {
 LazyVStack(spacing: GlassSpacing.m) {
 if let vm = viewModel {
 ForEach(vm.displayMessages) { message in
 MessageRow(message: message)
 .id(message.id)
 }

 // Streaming text
 if !vm.streamingText.isEmpty {
 AssistantBubble(text: vm.streamingText, isStreaming: true)
 .id("streaming")
 }
 }

 // chat-area "Thinking…" indicator.
 // Visible only when the agent is running AND no tokens
 // have streamed yet. Disjoint from the streaming bubble
 // above (which takes over the moment streamingText is
 // non-empty) and from `LivePartialTranscriptView` in
 // the composer area (which covers voice CAPTURE, not
 // model INFERENCE). Reuses existing observable state;
 // no parallel state machine.
 ThinkingIndicator(isVisible: shouldShowThinkingIndicator)
 .id("thinking")

 // Stable bottom anchor for scroll targeting
 Color.clear.frame(height: 1).id("bottom")
 }
 .padding
 .padding(.bottom, chatBottomContentPadding)
 }
 .background(chatBackgroundGradient)
 .onAppear {
 proxy.scrollTo("bottom", anchor: .bottom)
 }
 .onChange(of: viewModel?.displayMessages.count) { _, _ in
 withAnimation {
 proxy.scrollTo("bottom", anchor: .bottom)
 }
 }
 .onChange(of: viewModel?.streamingText) { _, _ in
 proxy.scrollTo("bottom", anchor: .bottom)
 }
 .onChange(of: shouldShowThinkingIndicator) { _, _ in
 withAnimation(RetroMotion.quickFade) {
 proxy.scrollTo("bottom", anchor: .bottom)
 }
 }
 }
 }

 /// derived helper for `ThinkingIndicator` visibility.
 /// True only when the agent loop is in flight AND no tokens have
 /// streamed yet. Closes the UX gap on cold-start prefill.
 private var shouldShowThinkingIndicator: Bool {
 guard let vm = viewModel else { return false }
 return vm.isRunning && vm.streamingText.isEmpty
 }

 /// Pure chat-stage backdrop. The glass surfaces already carry enough
 /// depth; the user requested a strict white / black canvas.
 @ViewBuilder
 private var chatBackgroundGradient: some View {
 chatBackgroundColor
 .ignoresSafeArea
 }

 @Environment(\.colorScheme) private var colorScheme

 private var chatBackgroundColor: Color {
 Color.glassPageBackground
 }

 private var chatBottomContentPadding: CGFloat {
 composerBackdropHeight + GlassSpacing.m
 }

 private var composerBackdrop: some View {
 LinearGradient(
 stops: [
 .init(color: composerBackdropBase.opacity(0.0), location: 0.0),
 .init(color: composerBackdropBase.opacity(colorScheme == .dark ? 0.04 : 0.08), location: 0.44),
 .init(color: composerBackdropBase.opacity(colorScheme == .dark ? 0.12 : 0.18), location: 1.0)
 ],
 startPoint: .top,
 endPoint: .bottom
 )
 .frame(maxWidth: .infinity, maxHeight: composerBackdropHeight)
 .allowsHitTesting(false)
 }

 private var composerBackdropBase: Color {
 Color.glassPageBackground
 }

 // MARK: - Error banner

 private func errorBanner(_ message: String) -> some View {
 // Uses `.card` not `.pill` — multi-line error messages need a rounded
 // rectangle, not a capsule that'd crop to a single line. Top-spacing
 // is handled by the enclosing safe-area VStack.
 HStack(alignment: .top, spacing: GlassSpacing.s) {
 Image(systemName: "exclamationmark.circle.fill")
 .foregroundStyle(Color.glassError)
 .padding(.top, 1)
 Text(message)
 .glassType(.caption)
 .foregroundStyle(Color.glassText)
 .fixedSize(horizontal: false, vertical: true)
 Spacer(minLength: 0)
 Button {
 viewModel?.error = nil
 } label: {
 Image(systemName: "xmark")
 .font(.caption.weight(.medium))
 .frame(width: 28, height: 28)
 .contentShape(Rectangle)
 }
 .buttonStyle(.relayGlass(.iconSecondary))
 .accessibilityLabel("Dismiss error")
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.vertical, GlassSpacing.s)
 .glassSurface(.card)
 .padding(.horizontal, GlassSpacing.m)
 }

 // MARK: - Actions

 private func loadSession() async {
 didAutoStartVoice = false
 didAutoSubmitText = false
 autoVoiceError = nil
 cleanupDraftAssets(composerDraft)
 composerDraft.clear
 selectedPhotoItems = []
 let vm = ChatViewModel(
 sessionId: sessionId,
 sessionIndex: sessionIndex,
 sharedServices: sharedServices
 )
 vm.onSessionUpdated = onSessionUpdated
 await vm.loadHistory
 self.viewModel = vm
 }

 private func sendMessage() {
 guard composerDraft.canSend else { return }

 isAccessoryDrawerPresented = false
 let draftSnapshot = composerDraft
 let envelope = makeEnvelope(from: draftSnapshot)

 Task {
 let accepted = await viewModel?.send(
 envelope: envelope,
 onAccepted: {
 cleanupDraftAssets(draftSnapshot)
 composerDraft.clear
 selectedPhotoItems = []
 onSessionUpdated
 }
 ) ?? false
 if !accepted {
 composerDraft = draftSnapshot
 }
 }
 }

 private var composerBackdropHeight: CGFloat {
 composerDraft.hasAttachments ? 226 : 176
 }

 /// Fire `startVoice` exactly once after the shell has flipped
 /// `autoStartVoice` to `true` AND the view model is loaded. Safe to call
 /// from both the initial `.task` and the `autoStartVoice` `.onChange`;
 /// the `didAutoStartVoice` latch dedupes.
 private func triggerAutoStartVoiceIfNeeded() {
 guard autoStartVoice, !didAutoStartVoice, viewModel != nil else { return }
 didAutoStartVoice = true
 viewModel?.startVoice
 if viewModel?.isVoiceActive != true {
 autoVoiceError = viewModel?.error ?? "Could not start voice input"
 }
 // Notify the shell that this cold-launch signal has been honoured so
 // it can clear `pendingAutoVoiceSessionId`. Only reached on the
 // successful-fire path — if the guard above bailed, pending stays
 // set so the `.task` body retry can still complete the trigger
 // once the view model has loaded.
 onAutoVoiceConsumed?(sessionId)
 }

 /// Fire the auto-submit-text path exactly once after the shell has
 /// flipped `autoSubmitText` to a non-nil string AND the view model is
 /// loaded. Mirrors `triggerAutoStartVoiceIfNeeded` — the shell already
 /// gated this on `modelHost` being non-nil, so no in-view polling.
 private func triggerAutoSubmitTextIfNeeded() {
 guard let text = autoSubmitText, !didAutoSubmitText, viewModel != nil else { return }
 didAutoSubmitText = true
 composerDraft.text = text
 sendMessage
 onAutoTextConsumed?(sessionId)
 }

 private var cameraPresentationBinding: Binding<Bool> {
 Binding(
 get: { composerDraft.cameraPresentation },
 set: { composerDraft.cameraPresentation = $0 }
 )
 }

 private var photosPickerPresentedBinding: Binding<Bool> {
 Binding(
 get: { composerDraft.pickerPresentation == .photos },
 set: { isPresented in
 if !isPresented && composerDraft.pickerPresentation == .photos {
 composerDraft.pickerPresentation = nil
 }
 }
 )
 }

 private var filesPickerPresentedBinding: Binding<Bool> {
 Binding(
 get: { composerDraft.pickerPresentation == .files },
 set: { isPresented in
 if !isPresented && composerDraft.pickerPresentation == .files {
 composerDraft.pickerPresentation = nil
 }
 }
 )
 }

 private var supportedAttachmentTypes: [UTType] {
 [.plainText, .utf8PlainText, .utf16ExternalPlainText, .commaSeparatedText, .tabSeparatedText, .json, .xml]
 }

 private func presentCamera() {
 isAccessoryDrawerPresented = false
 guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
 viewModel?.error = "Camera is not available on this device."
 return
 }
 composerDraft.cameraPresentation = true
 }

 private func makeEnvelope(from draft: ComposerDraft) -> TurnEnvelope {
 let kind: TurnKind
 if draft.hasText && draft.hasAttachments {
 kind = .mixed
 } else if !draft.pendingFiles.isEmpty && draft.pendingImages.isEmpty {
 kind = draft.hasText ? .mixed : .file
 } else if !draft.pendingImages.isEmpty && draft.pendingFiles.isEmpty {
 kind = draft.hasText ? .mixed : .image
 } else {
 kind = .text
 }

 let source: TurnSource
 if !draft.pendingFiles.isEmpty {
 source = .composerFile
 } else if !draft.pendingImages.isEmpty {
 source = .composerImage
 } else {
 source = .composerText
 }

 return TurnEnvelope(
 kind: kind,
 visibleText: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
 imageRefs: draft.pendingImages.map(\.stagedURL),
 fileRefs: draft.pendingFiles,
 source: source
 )
 }

 @MainActor
 private func appendSelectedPhotos(_ items: [PhotosPickerItem]) async {
 defer {
 selectedPhotoItems = []
 composerDraft.pickerPresentation = nil
 }

 var appended: [PendingDraftImage] = []
 for item in items {
 do {
 guard let data = try await item.loadTransferable(type: Data.self) else { continue }
 let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
 let filename = "\(UUID().uuidString).\(ext)"
 let url = try stageDraftData(data, subdirectory: "images", filename: filename)
 appended.append(PendingDraftImage(
 stagedURL: url,
 displayName: item.itemIdentifier ?? filename
 ))
 } catch {
 viewModel?.error = "Could not import one of the selected photos."
 }
 }
 composerDraft.pendingImages.append(contentsOf: appended)
 }

 @MainActor
 private func appendCapturedImage(from capturedURL: URL) async {
 do {
 let ext = capturedURL.pathExtension.isEmpty ? "jpg" : capturedURL.pathExtension
 let filename = "\(UUID().uuidString).\(ext)"
 let url = try stageDraftFile(from: capturedURL, subdirectory: "images", filename: filename)
 composerDraft.pendingImages.append(PendingDraftImage(
 stagedURL: url,
 displayName: url.lastPathComponent
 ))
 } catch {
 viewModel?.error = "Could not save the captured photo."
 }
 }

 @MainActor
 private func appendImportedFiles(_ result: Result<[URL], Error>) async {
 defer {
 composerDraft.pickerPresentation = nil
 }

 let urls: [URL]
 switch result {
 case .success(let selected):
 urls = selected
 case .failure(let error):
 viewModel?.error = error.localizedDescription
 return
 }

 var appended: [PendingFileIngestion] = []
 for sourceURL in urls {
 do {
 appended.append(try stageImportedFile(from: sourceURL))
 } catch {
 viewModel?.error = error.localizedDescription
 return
 }
 }
 composerDraft.pendingFiles.append(contentsOf: appended)
 }

 private func removePendingImage(_ image: PendingDraftImage) {
 cleanupFileIfNeeded(image.stagedURL)
 composerDraft.pendingImages.removeAll { $0.id == image.id }
 }

 private func removePendingFile(_ file: PendingFileIngestion) {
 cleanupFileIfNeeded(file.sourceURL)
 composerDraft.pendingFiles.removeAll { $0.attachmentID == file.attachmentID }
 }

 private func stageImportedFile(from sourceURL: URL) throws -> PendingFileIngestion {
 let accessed = sourceURL.startAccessingSecurityScopedResource
 defer {
 if accessed {
 sourceURL.stopAccessingSecurityScopedResource
 }
 }

 let contentType = try sourceURL.resourceValues(forKeys: [.contentTypeKey]).contentType
 ?? UTType(filenameExtension: sourceURL.pathExtension)
 ?? .data
 let contentTypeIdentifier = contentType.identifier
 let filename = sourceURL.lastPathComponent
 let stagedURL = try stageDraftFile(
 from: sourceURL,
 subdirectory: "files",
 filename: "\(UUID().uuidString)-\(filename)"
 )
 return PendingFileIngestion(
 sourceURL: stagedURL,
 displayName: filename,
 contentTypeIdentifier: contentTypeIdentifier
 )
 }

 private func stageDraftData(_ data: Data, subdirectory: String, filename: String) throws -> URL {
 let directory = draftStagingDirectory.appendingPathComponent(subdirectory, isDirectory: true)
 try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
 let url = directory.appendingPathComponent(filename)
 try data.write(to: url, options: .atomic)
 return url
 }

 private func stageDraftFile(from sourceURL: URL, subdirectory: String, filename: String) throws -> URL {
 let directory = draftStagingDirectory.appendingPathComponent(subdirectory, isDirectory: true)
 try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
 let destinationURL = directory.appendingPathComponent(filename)
 if FileManager.default.fileExists(atPath: destinationURL.path) {
 try FileManager.default.removeItem(at: destinationURL)
 }
 try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
 return destinationURL
 }

 private func draftStagingDirectory() -> URL {
 FileManager.default.temporaryDirectory
 .appendingPathComponent("relay-composer-drafts", isDirectory: true)
 .appendingPathComponent(sessionId, isDirectory: true)
 }

 private func cleanupDraftAssets(_ draft: ComposerDraft) {
 draft.pendingImages.forEach { cleanupFileIfNeeded($0.stagedURL) }
 draft.pendingFiles.forEach { cleanupFileIfNeeded($0.sourceURL) }
 }

 private func cleanupFileIfNeeded(_ url: URL) {
 guard FileManager.default.fileExists(atPath: url.path) else { return }
 try? FileManager.default.removeItem(at: url)
 }
}

/// Renders a single message in the list.
struct MessageRow: View {
 let message: DisplayMessage

 var body: some View {
 switch message {
 case .user(_, let content):
 UserBubble(content: content)

 case .assistant(_, let text, let isStreaming):
 VStack(alignment: .leading, spacing: GlassSpacing.s) {
 AssistantBubble(text: text, isStreaming: isStreaming)
 // Action bar appears after streaming completes
 if !isStreaming && !text.isEmpty {
 MessageActions(text: text)
 .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .top)))
 }
 }

 case .toolExecution(_, _, let name, let status, let input, let output):
 ToolCard(name: name, status: status, input: input, output: output)

 case .contextInjection(_, let source):
 ContextBadge(source: source)
 }
 }
}

#Preview {
 NavigationStack {
 ChatView(
 sessionId: "preview",
 sessionIndex: SessionIndex,
 sharedServices: SharedServices,
 onSessionUpdated: {}
 )
 }
}
