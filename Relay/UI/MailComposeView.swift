import SwiftUI
import MessageUI

/// Data for presenting MFMailComposeViewController.
public struct MailComposeData: Identifiable {
 public let id = UUID()
 public let to: [String]
 public let cc: [String]
 public let bcc: [String]
 public let subject: String
 public let body: String
 public let isHTML: Bool

 public init(to: [String], cc: [String] = [], bcc: [String] = [], subject: String, body: String, isHTML: Bool = false) {
 self.to = to
 self.cc = cc
 self.bcc = bcc
 self.subject = subject
 self.body = body
 self.isHTML = isHTML
 }

 /// Parse from JSON payload string.
 public static func from(payload: String) -> MailComposeData? {
 guard let data = payload.data(using: .utf8),
 let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
 return nil
 }
 guard let to = json["to"] as? [String] else { return nil }
 return MailComposeData(
 to: to,
 cc: json["cc"] as? [String] ?? [],
 bcc: json["bcc"] as? [String] ?? [],
 subject: json["subject"] as? String ?? "",
 body: json["body"] as? String ?? "",
 isHTML: json["is_html"] as? Bool ?? false
 )
 }
}

/// Result of a mail compose attempt.
public enum MailComposeResult {
 case cancelled
 case saved
 case sent
 case failed(Error?)
}

/// SwiftUI wrapper for MFMailComposeViewController.
public struct MailComposeView: UIViewControllerRepresentable {
 public let data: MailComposeData
 public let onComplete: (MailComposeResult) -> Void

 public init(data: MailComposeData, onComplete: @escaping (MailComposeResult) -> Void) {
 self.data = data
 self.onComplete = onComplete
 }

 public func makeUIViewController(context: Context) -> MFMailComposeViewController {
 let vc = MFMailComposeViewController()
 vc.mailComposeDelegate = context.coordinator
 vc.setToRecipients(data.to)
 vc.setCcRecipients(data.cc)
 vc.setBccRecipients(data.bcc)
 vc.setSubject(data.subject)
 vc.setMessageBody(data.body, isHTML: data.isHTML)
 return vc
 }

 public func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

 public func makeCoordinator() -> Coordinator {
 Coordinator(onComplete: onComplete)
 }

 public class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
 let onComplete: (MailComposeResult) -> Void

 init(onComplete: @escaping (MailComposeResult) -> Void) {
 self.onComplete = onComplete
 }

 public func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
 let mapped: MailComposeResult
 switch result {
 case .cancelled: mapped = .cancelled
 case .saved: mapped = .saved
 case .sent: mapped = .sent
 case .failed: mapped = .failed(error)
 @unknown default: mapped = .failed(nil)
 }
 onComplete(mapped)
 }
 }
}

/// Check if the device can send email.
public func canSendMail() -> Bool {
 MFMailComposeViewController.canSendMail()
}
