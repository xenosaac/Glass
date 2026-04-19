import SwiftUI

/// Settings detail view for the native embedded Gmail provider.
/// Shows configuration/connection state via a Liquid Glass status card
/// consistent with chat surfaces, and lets the user connect or disconnect
/// a single Gmail account via OAuth.
struct GmailSettingsSection: View {
 let sharedServices: SharedServices

 @State private var isConfigured = false
 @State private var isSignedIn = false
 @State private var userEmail: String?
 @State private var isWorking = false
 @State private var errorMessage: String?


 var body: some View {
 List {
 Section {
 statusCard
 .listRowInsets(EdgeInsets(
 top: GlassSpacing.s,
 leading: GlassSpacing.m,
 bottom: GlassSpacing.s,
 trailing: GlassSpacing.m
 ))
 .listRowBackground(Color.clear)
 .listRowSeparator(.hidden)
 } header: {
 SettingsSectionHeader(title: "Status")
 }

 if isConfigured {
 Section {
 if !isSignedIn {
 Button {
 Task { await connect }
 } label: {
 HStack(spacing: GlassSpacing.m) {
 SettingsMonochromeIcon(systemImage: "person.badge.plus")
 Text("Connect Gmail")
 .glassType(.bodyEmphasis)
 Spacer()
 if isWorking {
 PixelStepIndicator(
 tint: Color.glassBorder,
 inactiveTint: Color.glassTextMuted.opacity(0.22),
 count: 3,
 blockSize: 5,
 spacing: 3
 )
 }
 }
 }
 .buttonStyle(.relayGlass(.primary, burst: .buttonTap))
 .disabled(isWorking)
 } else {
 Button(role: .destructive) {
 Task { await disconnect }
 } label: {
 SettingsRowLabel(title: "Disconnect", systemImage: "person.badge.minus") {
 EmptyView()
 }
 .foregroundStyle(Color.glassError)
 }
 .buttonStyle(.relayGlass(.destructive, burst: .subtleTap))
 .disabled(isWorking)
 }
 } header: {
 SettingsSectionHeader(title: "Actions")
 }
 }

 if let msg = errorMessage {
 Section {
 Text(msg)
 .glassType(.caption)
 .foregroundStyle(Color.glassError)
 } header: {
 SettingsSectionHeader(title: "Last Error")
 }
 }

 Section {
 Text("Gmail tools (search, read message/thread, draft reply, send) are registered with the agent only while you're connected.")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 } header: {
 SettingsSectionHeader(title: "About")
 }
 }
 .settingsListChrome()
 .navigationTitle("Gmail")
 .navigationBarTitleDisplayMode(.large)
 .task { await refresh() }
 }

 // MARK: - Status card

 @ViewBuilder
 private var statusCard: some View {
 if !isConfigured {
 notConfiguredCard
 } else if isSignedIn {
 connectedCard
 } else {
 notConnectedCard
 }
 }

 private var connectedCard: some View {
 SettingsInfoCard {
 HStack(alignment: .center, spacing: GlassSpacing.m) {
 Image(systemName: "envelope.badge")
 .font(.system(size: 18, weight: .semibold))
 .foregroundStyle(Color.glassSuccess)
 VStack(alignment: .leading, spacing: 4) {
 Text("Gmail is connected")
 .glassType(.bodyEmphasis)
 .foregroundStyle(Color.glassSuccess)
 if let email = userEmail {
 Text(email)
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .lineLimit(1)
 }
 }
 Spacer(minLength: 0)
 }
 }
 }

 private var notConnectedCard: some View {
 SettingsInfoCard {
 HStack(spacing: GlassSpacing.m) {
 SettingsMonochromeIcon(systemImage: "envelope.badge")
 VStack(alignment: .leading, spacing: GlassSpacing.xs) {
 Text("Not connected")
 .glassType(.bodyEmphasis)
 Text("Connect Gmail to enable mail tools inside Glass.")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 }
 Spacer()
 }
 }
 }

 private var notConfiguredCard: some View {
 SettingsInfoCard {
 HStack(spacing: GlassSpacing.s) {
 SettingsMonochromeIcon(systemImage: "wrench.and.screwdriver")
 Text("Owner setup required")
 .glassType(.bodyEmphasis)
 .foregroundStyle(.primary)
 }
 Text("Gmail uses a Google Cloud OAuth Client ID. On iOS the redirect URL scheme must be declared at build time (`CFBundleURLTypes`), so Client ID entry lives in code — not this screen — by design.")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .fixedSize(horizontal: false, vertical: true)
 .frame(maxWidth: .infinity, alignment: .leading)
 VStack(alignment: .leading, spacing: 2) {
 Text("One-time setup")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 Text("Relay/Gmail/GmailConfig.swift")
 .glassType(.numeric)
 .textSelection(.enabled)
 Text("Relay/project.yml → CFBundleURLTypes")
 .glassType(.numeric)
 .textSelection(.enabled)
 }
 .padding(.top, GlassSpacing.xs)
 Text("Once the Client ID and reversed Client ID are in place and the app is rebuilt, this card turns into a Connect button.")
 .glassType(.caption)
 .foregroundStyle(Color.glassTextMuted)
 .fixedSize(horizontal: false, vertical: true)
 .frame(maxWidth: .infinity, alignment: .leading)
 }
 }

 // MARK: - Actions

 @MainActor
 private func refresh() async {
 guard let service = sharedServices.gmailService else {
 isConfigured = false
 isSignedIn = false
 userEmail = nil
 return
 }
 isConfigured = await service.isConfigured()
 isSignedIn = await service.isSignedIn()
 userEmail = await service.currentUserEmail()
 }

 @MainActor
 private func connect() async {
 guard let service = sharedServices.gmailService else { return }
 isWorking = true
 errorMessage = nil
 defer { isWorking = false }
 do {
 try await service.signIn()
 await refresh()
 } catch GmailError.authCancelled {
 // Silent — user dismissed the auth sheet
 } catch {
 errorMessage = error.localizedDescription
 }
 }

 @MainActor
 private func disconnect() async {
 guard let service = sharedServices.gmailService else { return }
 isWorking = true
 defer { isWorking = false }
 await service.signOut()
 await refresh()
 }
}
