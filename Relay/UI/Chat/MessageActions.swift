import SwiftUI

/// Action bar for completed assistant messages — copy and share only.
/// Appears below the message text and keeps the same retro-3D interaction
/// language as the rest of the app, just with the secondary icon variant.
struct MessageActions: View {
 let text: String
 @State private var copied = false

 var body: some View {
 HStack(spacing: GlassSpacing.l) {
 // Copy
 Button {
 UIPasteboard.general.string = text
 withAnimation(.easeOut(duration: 0.15)) {
 copied = true
 }
 DispatchQueue.main.asyncAfter(deadline: .now + 1.5) {
 withAnimation(.easeOut(duration: 0.15)) {
 copied = false
 }
 }
 } label: {
 Image(systemName: copied ? "checkmark" : "doc.on.doc")
 .font(.system(size: 14, weight: .medium))
 .frame(width: 34, height: 34)
 .contentTransition(.symbolEffect(.replace))
 }
 .buttonStyle(.relayGlass(copied ? .iconAccent : .iconSecondary))
 .accessibilityLabel("Copy")

 // Share
 Button {
 share(text: text)
 } label: {
 Image(systemName: "square.and.arrow.up")
 .font(.system(size: 14, weight: .medium))
 .frame(width: 34, height: 34)
 }
 .buttonStyle(.relayGlass(.iconSecondary))
 .accessibilityLabel("Share")

 Spacer
 }
 }

 private func share(text: String) {
 let activityVC = UIActivityViewController(
 activityItems: [text],
 applicationActivities: nil
 )
 if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
 let rootVC = windowScene.windows.first?.rootViewController {
 rootVC.present(activityVC, animated: true)
 }
 }
}

#Preview {
 VStack(alignment: .leading, spacing: GlassSpacing.m) {
 Text("Here's your answer to the question about Swift concurrency...")
 .glassType(.body)
 MessageActions(text: "Here's your answer...")
 }
 .padding
}
