import Foundation

enum ComposerPickerPresentation: Equatable {
 case photos
 case files
}

struct PendingDraftImage: Identifiable, Equatable, Sendable {
 let id: UUID
 let stagedURL: URL
 let displayName: String

 init(id: UUID = UUID(), stagedURL: URL, displayName: String) {
 self.id = id
 self.stagedURL = stagedURL
 self.displayName = displayName
 }
}

struct ComposerDraft: Equatable {
 var text: String = ""
 var pendingImages: [PendingDraftImage] = []
 var pendingFiles: [PendingFileIngestion] = []
 var pickerPresentation: ComposerPickerPresentation?
 var cameraPresentation: Bool = false

 var hasText: Bool {
 !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
 }

 var hasAttachments: Bool {
 !pendingImages.isEmpty || !pendingFiles.isEmpty
 }

 var canSend: Bool {
 hasText || hasAttachments
 }

 var isVoiceAllowed: Bool {
 pendingImages.isEmpty && pendingFiles.isEmpty
 }

 mutating func clear() {
 text = ""
 pendingImages = []
 pendingFiles = []
 pickerPresentation = nil
 cameraPresentation = false
 }
}
