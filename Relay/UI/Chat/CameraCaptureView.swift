import SwiftUI
import UIKit

struct CameraCaptureView: UIViewControllerRepresentable {
 let onCapture: (URL?) -> Void

 func makeCoordinator() -> Coordinator {
 Coordinator(onCapture: onCapture)
 }

 func makeUIViewController(context: Context) -> UIImagePickerController {
 let picker = UIImagePickerController()
 picker.sourceType = .camera
 picker.delegate = context.coordinator
 picker.cameraCaptureMode = .photo
 picker.allowsEditing = false
 return picker
 }

 func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

 final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
 private let onCapture: (URL?) -> Void

 init(onCapture: @escaping (URL?) -> Void) {
 self.onCapture = onCapture
 }

 func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
 picker.dismiss(animated: true)
 onCapture(nil)
 }

 func imagePickerController(
 _ picker: UIImagePickerController,
 didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
 ) {
 let url: URL?
 if let image = info[.originalImage] as? UIImage,
 let jpegData = image.jpegData(compressionQuality: 0.92) {
 let directory = FileManager.default.temporaryDirectory
 .appendingPathComponent("relay-camera-capture", isDirectory: true)
 try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
 let fileURL = directory.appendingPathComponent("\(UUID().uuidString).jpg")
 try? jpegData.write(to: fileURL, options: .atomic)
 url = fileURL
 } else {
 url = nil
 }

 picker.dismiss(animated: true)
 onCapture(url)
 }
 }
}
