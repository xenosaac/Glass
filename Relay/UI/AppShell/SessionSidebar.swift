import SwiftUI

struct SessionSidebar: View {
 let sessions: [SessionMetadata]
 @Binding var currentSessionId: String?
 let onSelectSession: (String) -> Void
 let onNewSession:  () async -> Void
 let onDeleteSession: (String) -> Void
 let onShowSettings:  () -> Void
 let onNewSessionInFolder:  () -> Void

 private var sortedSessions: [SessionMetadata] {
 sessions.sorted() { $0.lastMessageAt > $1.lastMessageAt }
 }

 var body: some View {
 GeometryReader { proxy in
 ZStack(alignment: .bottomTrailing) {
 Color.glassPageBackground.ignoresSafeArea()

 ScrollView(showsIndicators: false) {
 VStack(alignment: .leading, spacing: GlassSpacing.xl) {
 header

 if !sortedSessions.isEmpty {
 recentSection
 }
 }
 .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
 .padding(.horizontal, GlassSpacing.l)
 .padding(.top, GlassSpacing.l)
 .padding(.bottom, 120)
 }

 if sortedSessions.isEmpty {
 emptyState
 .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
 .padding(.horizontal, GlassSpacing.l)
 .allowsHitTesting(false)
 }

 floatingCTA
 .padding(.trailing, GlassSpacing.l)
 .padding(.bottom, GlassSpacing.l)
 }
 .toolbar(.hidden, for: .navigationBar)
 }
 }

 private var header: some View {
 HStack(alignment: .top, spacing: GlassSpacing.m) {
 HStack(spacing: GlassSpacing.s) {
 Image("AppLogo")
 .resizable()
 .scaledToFit()
 .frame(width: 28, height: 28)
 .clipShape(RetroCutShape(cut: 8))

 VStack(alignment: .leading, spacing: 2) {
 Text("Glass")
 .glassType(.display)
 .foregroundStyle(Color.glassText)
 Text("Recent conversations")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 }
 }

 Spacer(minLength: GlassSpacing.m)

 Button {
 onShowSettings()
 } label: {
 Image(systemName: "gearshape")
 .font(.system(size: 18, weight: .semibold))
 .frame(width: 44, height: 44)
 }
 .buttonStyle(.relayGlass(.iconSidebar))
 .accessibilityLabel("Settings")
 }
 }

 private var recentSection: some View {
 VStack(alignment: .leading, spacing: GlassSpacing.m) {
 Text("Recent")
 .glassType(.sectionHeader)
 .foregroundStyle(Color.glassTextMuted)

 LazyVStack(alignment: .leading, spacing: GlassSpacing.s) {
 ForEach(sortedSessions) { session in
 SessionRow(
 session: session,
 isSelected: currentSessionId == session.id,
 onSelect: { onSelectSession(session.id) },
 onDelete: { onDeleteSession(session.id) }
 )
 }
 }
 }
 }

 private var floatingCTA: some View {
 Button {
 Task { await onNewSession }
 } label: {
 HStack(spacing: GlassSpacing.xs) {
 Image(systemName: "square.and.pencil")
 Text("Chat")
 }
 }
 .buttonStyle(.relayGlass(.floatingChat, burst: .buttonTap))
 .contextMenu {
 Button {
 onNewSessionInFolder()
 } label: {
 Label("New Chat in Folder...", systemImage: "folder.badge.plus")
 }
 }
 .accessibilityLabel("New Chat")
 }

 private var emptyState: some View {
 VStack(spacing: GlassSpacing.m) {
 Image(systemName: "bubble.left.and.text.bubble.right")
 .font(.system(size: 30, weight: .medium))
 .foregroundStyle(Color.glassBorder)

 Text("No conversations yet")
 .glassType(.title)
 .foregroundStyle(Color.glassText)
 .multilineTextAlignment(.center)

 Text("Start a new chat from the Chat button below and your recent conversations will appear here.")
 .glassType(.body)
 .foregroundStyle(Color.glassTextMuted)
 .multilineTextAlignment(.center)
 .frame(maxWidth: 300)
 }
 .padding(GlassSpacing.xl)
 .glassSurface(.card)
 .offset(y: -GlassSpacing.l)
 }
}

struct SessionRow: View {
 let session: SessionMetadata
 let isSelected: Bool
 let onSelect:  () -> Void
 let onDelete:  () -> Void

 var body: some View {
 Button(action: onSelect) {
 HStack(alignment: .center, spacing: GlassSpacing.m) {
 Text(session.title)
 .glassType(.bodyEmphasis)
 .foregroundStyle(Color.glassText)
 .lineLimit(1)
 .frame(maxWidth: .infinity, alignment: .leading)

 TimelineView(.periodic(from: .now, by: 30)) { context in
 Text(Self.relativeTimestamp(from: session.lastMessageAt, now: context.date))
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .lineLimit(1)
 }
 }
 .padding(.horizontal, GlassSpacing.m)
 .padding(.vertical, GlassSpacing.m)
 .frame(maxWidth: .infinity, alignment: .leading)
 .background(rowBackground)
 }
 .buttonStyle(.relaySurfaceFeedback)
 .contextMenu {
 Button(role: .destructive) {
 onDelete()
 } label: {
 Label("Delete", systemImage: "trash")
 }
 }
 .accessibilityAddTraits(isSelected ? .isSelected : [])
 }

 @ViewBuilder
 private var rowBackground: some View {
 if isSelected {
 HStack(spacing: 0) {
 Color.glassAccent.frame(width: 8)
 Color.clear
 }
 .clipShape(RetroCutShape(cut: 9))
 .background {
 RetroCutShape(cut: 9)
 .fill(Color.glassSurfaceRaised)
 }
 .overlay {
 RetroCutShape(cut: 9)
 .stroke(Color.glassBorder, lineWidth: RetroMetrics.borderWidth)
 }
 .overlay(alignment: .top) {
 RetroCutShape(cut: 9)
 .stroke(Color.glassHighlight.opacity(0.75), lineWidth: 1)
 .mask { Rectangle().frame(height: 18) }
 }
 } else {
 Color.clear
 }
 }

 private static func relativeTimestamp(from date: Date, now: Date) -> String {
 let elapsed = max(0, Int(now.timeIntervalSince(date)))

 if elapsed < 60 { return "Now" }
 if elapsed < 3_600 {
 let minutes = max(1, elapsed / 60)
 return minutes == 1 ? "1 min ago" : "\(minutes) mins ago"
 }
 if elapsed < 86_400 {
 let hours = max(1, elapsed / 3_600)
 return hours == 1 ? "1 hr ago" : "\(hours) hrs ago"
 }
 let days = max(1, elapsed / 86_400)
 return days == 1 ? "1 day ago" : "\(days) days ago"
 }
}
