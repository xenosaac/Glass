import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI wrapper for UIDocumentPickerViewController in folder-selection mode.
///
/// Usage:
/// ```swift
/// @State private var showingPicker = false
///
/// Button("Grant Folder Access") { showingPicker = true }
/// .sheet(isPresented: $showingPicker) {
/// FolderPicker { url in
/// Task { try await fileProvider.addAuthorization(url: url) }
/// }
/// }
/// ```
public struct FolderPicker: UIViewControllerRepresentable {
 private let onPick: (URL) -> Void
 private let onCancel: (() -> Void)?

 public init(onPick: @escaping (URL) -> Void, onCancel: (() -> Void)? = nil) {
 self.onPick = onPick
 self.onCancel = onCancel
 }

 public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
 let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
 picker.delegate = context.coordinator
 picker.allowsMultipleSelection = false
 return picker
 }

 public func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

 public func makeCoordinator() -> Coordinator {
 Coordinator(onPick: onPick, onCancel: onCancel)
 }

 public class Coordinator: NSObject, UIDocumentPickerDelegate {
 private let onPick: (URL) -> Void
 private let onCancel: (() -> Void)?

 init(onPick: @escaping (URL) -> Void, onCancel: (() -> Void)?) {
 self.onPick = onPick
 self.onCancel = onCancel
 }

 public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
 if let url = urls.first {
 onPick(url)
 }
 }

 public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
 onCancel?()
 }
 }
}
