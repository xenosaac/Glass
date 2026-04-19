import SwiftUI
import UIKit

struct InputBar: View {
 @Binding var draft: ComposerDraft
 let isRunning: Bool
 var isVoiceActive: Bool = false
 var voiceAudioLevel: Float = 0
 var isReady: Bool = true
 var isAccessoryDrawerPresented: Bool = false
 let onSend:  () -> Void
 var onVoiceTap: (() -> Void)?
 let onAccessoryToggle:  () -> Void
 let onAccessoryDismiss:  () -> Void
 let onImportFilesTap:  () -> Void
 let onTakePhotoTap:  () -> Void
 let onChoosePhotosTap:  () -> Void
 let onRemoveImage: (PendingDraftImage) -> Void
 let onRemoveFile: (PendingFileIngestion) -> Void

 @FocusState private var isFocused: Bool
 @Environment(\.colorScheme) private var colorScheme
 @State private var drawerBurstTrigger = 0

 var body: some View {
 VStack(alignment: .leading, spacing: GlassSpacing.s) {
 if draft.hasAttachments {
 attachmentTray
 }

 if isAccessoryDrawerPresented {
 accessoryDrawer
 .transition(.move(edge: .bottom).combined(with: .opacity))
 }

 composerShell
 }
 .opacity(isReady ? 1.0 : 0.55)
 .animation(.easeOut(duration: 0.2), value: isReady)
 .animation(.easeOut(duration: 0.18), value: draft.pendingImages.count)
 .animation(.easeOut(duration: 0.18), value: draft.pendingFiles.count)
 .animation(.easeOut(duration: 0.18), value: canSend)
 .animation(RetroMotion.drawerSpring, value: isAccessoryDrawerPresented)
 .onChange(of: isAccessoryDrawerPresented) { oldValue, newValue in
 if !oldValue, newValue {
 drawerBurstTrigger += 1
 }
 }
 }

 private var attachmentTray: some View {
 ScrollView(.horizontal, showsIndicators: false) {
 HStack(spacing: GlassSpacing.s) {
 ForEach(draft.pendingImages) { image in
 draftImageChip(image)
 }
 ForEach(draft.pendingFiles) { file in
 draftFileChip(file)
 }
 }
 .padding(.horizontal, 2)
 }
 }

 private var composerShell: some View {
 VStack(alignment: .leading, spacing: GlassSpacing.m) {
 TextField(
 isReady ? "Talk to Glass" : "Warming up on-device model…",
 text: $draft.text,
 axis: .vertical
 )
 .textFieldStyle(.plain)
 .glassType(.body)
 .foregroundStyle(Color.glassText)
 .tint(Color.glassBorder)
 .lineLimit(1...5)
 .focused($isFocused)
 .onSubmit {
 if canSend { onSend() }
 }

 HStack(alignment: .center, spacing: GlassSpacing.s) {
 accessoryButton
 Spacer(minLength: GlassSpacing.s)
 voiceButton
 sendButton
 }
 }
 .padding(.horizontal, GlassSpacing.l)
 .padding(.top, GlassSpacing.l)
 .padding(.bottom, GlassSpacing.m)
 .glassSurface(.composer)
 }

 private var accessoryDrawer: some View {
 VStack(spacing: GlassSpacing.m) {
 HStack(spacing: 4) {
 ForEach(0..<4, id: \.self) { _ in
 RetroPixelBlock(color: Color.glassBorder.opacity(0.4), size: 5)
 }
 }

 HStack(spacing: GlassSpacing.s) {
 drawerActionButton(systemImage: "camera", title: "Camera") {
 onAccessoryDismiss()
 onTakePhotoTap()
 }
 drawerActionButton(systemImage: "photo.on.rectangle", title: "Photos") {
 onAccessoryDismiss()
 onChoosePhotosTap()
 }
 drawerActionButton(systemImage: "doc", title: "Files") {
 onAccessoryDismiss()
 onImportFilesTap()
 }
 }
 }
 .padding(GlassSpacing.l)
 .frame(maxWidth: .infinity)
 .glassSurface(.card)
 .overlay {
 PixelBurstEmitter(trigger: drawerBurstTrigger, style: .drawerOpen)
 }
 .gesture(
 DragGesture(minimumDistance: 8)
 .onEnded { value in
 if value.translation.height > 40 {
 onAccessoryDismiss()
 }
 }
 )
 }

 private var accessoryButton: some View {
 Button {
 onAccessoryToggle()
 } label: {
 Image(systemName: isAccessoryDrawerPresented ? "xmark" : "plus")
 .font(.system(size: 16, weight: .bold))
 .frame(width: 42, height: 42)
 }
 .buttonStyle(.relayGlass(
 isAccessoryDrawerPresented ? .iconAccent : .iconSecondary,
 burst: .buttonTap
 ))
 .disabled(isRunning || !isReady)
 .accessibilityLabel(isAccessoryDrawerPresented ? "Close attachments" : "Open attachments")
 }

 private var voiceButton: some View {
 ZStack {
 if isVoiceActive {
 RetroCutShape(cut: 8)
 .fill(Color.glassError.opacity(0.16))
 .frame(width: 42, height: 42)
 .scaleEffect(1.0 + min(CGFloat(voiceAudioLevel) * 0.6, 0.6))
 .animation(.easeOut(duration: 0.12), value: voiceAudioLevel)
 }

 Button {
 onVoiceTap?()
 } label: {
 ZStack {
 Image(systemName: isVoiceActive ? "mic.fill" : "mic")
 .font(.system(size: 17, weight: .semibold))
 .foregroundStyle(isVoiceActive ? Color.white : Color.glassText)
 if isVoiceActive {
 RetroPixelBlock(color: .white, size: 7)
 .offset(x: 13, y: -13)
 }
 }
 .frame(width: 42, height: 42)
 }
 .buttonStyle(.relayGlass(
 isVoiceActive ? .iconError : .iconSecondary,
 burst: .microphoneTap
 ))
 .disabled(isRunning || !isReady || !draft.isVoiceAllowed)
 .accessibilityLabel(isVoiceActive ? "Stop recording" : "Voice input")
 }
 }

 private var sendButton: some View {
 Button {
 onSend()
 } label: {
 Group {
 if isRunning {
 PixelStepIndicator(
 tint: colorScheme == .dark ? Color.glassBorder : .white,
 inactiveTint: (colorScheme == .dark ? Color.glassBorder : .white).opacity(0.32),
 count: 3,
 blockSize: 5,
 spacing: 3
 )
 } else {
 Image(systemName: "arrow.up")
 .font(.system(size: 16, weight: .semibold))
 }
 }
 .frame(width: 42, height: 42)
 }
 .buttonStyle(.relayGlass(.iconPrimary, burst: .buttonTap))
 .disabled(!canSend)
 .accessibilityLabel(isRunning ? "Generating" : "Send")
 }

 private func drawerActionButton(systemImage: String, title: String, action: @escaping  () -> Void) -> some View {
 Button(action: action) {
 VStack(spacing: GlassSpacing.s) {
 Image(systemName: systemImage)
 .font(.system(size: 20, weight: .semibold))
 Text(title)
 .glassType(.caption)
 }
 .frame(maxWidth: .infinity)
 .frame(height: 84)
 }
 .buttonStyle(.relayGlass(.secondary, burst: .subtleTap))
 .disabled(isRunning || !isReady)
 }

 private func draftImageChip(_ image: PendingDraftImage) -> some View {
 ZStack(alignment: .topTrailing) {
 Group {
 if let uiImage = UIImage(contentsOfFile: image.stagedURL.path) {
 Image(uiImage: uiImage)
 .resizable()
 .scaledToFill()
 } else {
 ZStack {
 Color.clear
 Image(systemName: "photo")
 .foregroundStyle(Color.glassTextMuted)
 }
 }
 }
 .frame(width: 76, height: 76)
 .clipShape(RetroCutShape(cut: 8))
 .glassSurface(.cardSubtle)

 Button {
 onRemoveImage(image)
 } label: {
 Image(systemName: "xmark")
 .font(.system(size: 10, weight: .bold))
 .frame(width: 22, height: 22)
 }
 .buttonStyle(.relayGlass(.iconSecondary))
 .offset(x: 6, y: -6)
 }
 }

 private func draftFileChip(_ file: PendingFileIngestion) -> some View {
 HStack(spacing: GlassSpacing.s) {
 Image(systemName: "doc.text")
 .font(.system(size: 14, weight: .medium))
 .foregroundStyle(Color.glassTextMuted)
 VStack(alignment: .leading, spacing: 2) {
 Text(file.displayName)
 .glassType(.bodyEmphasis)
 .lineLimit(1)
 Text(file.contentTypeIdentifier)
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .lineLimit(1)
 }
 Button {
 onRemoveFile(file)
 } label: {
 Image(systemName: "xmark")
 .font(.system(size: 11, weight: .bold))
 .frame(width: 20, height: 20)
 }
 .buttonStyle(.relayGlass(.iconSecondary))
 }
 .padding(.horizontal, GlassSpacing.m)
 .padding(.vertical, GlassSpacing.s)
 .glassSurface(.field)
 }

 private var canSend: Bool {
 draft.canSend && !isRunning && isReady
 }
}
