import SwiftUI
import MessageUI

/// Data for presenting MFMessageComposeViewController.
public struct MessageComposeData: Identifiable {
 public let id = UUID()
 public let recipients: [String]
 public let body: String

 public init(recipients: [String], body: String) {
 self.recipients = recipients
 self.body = body
 }

 /// Parse from JSON payload string.
 public static func from(payload: String) -> MessageComposeData? {
 guard let data = payload.data(using: .utf8),
 let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
 return nil
 }
 guard let recipients = json["recipients"] as? [String] else { return nil }
 return MessageComposeData(
 recipients: recipients,
 body: json["body"] as? String ?? ""
 )
 }
}

/// Result of a message compose attempt.
public enum MessageComposeResult {
 case cancelled
 case sent
 case failed
}

/// SwiftUI wrapper for MFMessageComposeViewController.
public struct MessageComposeView: UIViewControllerRepresentable {
 public let data: MessageComposeData
 public let onComplete: (MessageComposeResult) -> Void

 public init(data: MessageComposeData, onComplete: @escaping (MessageComposeResult) -> Void) {
 self.data = data
 self.onComplete = onComplete
 }

 public func makeUIViewController(context: Context) -> MFMessageComposeViewController {
 let vc = MFMessageComposeViewController
 vc.messageComposeDelegate = context.coordinator
 vc.recipients = data.recipients
 vc.body = data.body
 return vc
 }

 public func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

 public func makeCoordinator() -> Coordinator {
 Coordinator(onComplete: onComplete)
 }

 public class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
 let onComplete: (MessageComposeResult) -> Void

 init(onComplete: @escaping (MessageComposeResult) -> Void) {
 self.onComplete = onComplete
 }

 public func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageUI.MessageComposeResult) {
 let mapped: MessageComposeResult
 switch result {
 case .cancelled: mapped = .cancelled
 case .sent: mapped = .sent
 case .failed: mapped = .failed
 @unknown default: mapped = .failed
 }
 onComplete(mapped)
 }
 }
}

/// Check if the device can send text messages.
public func canSendText() -> Bool {
 MFMessageComposeViewController.canSendText
}
