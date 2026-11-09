import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum ImportSheet: Identifiable {
    case photos, files, replace, image, music, export
    var id: Int {
        switch self {
        case .photos: return 0
        case .files: return 1
        case .replace: return 2
        case .image: return 3
        case .music: return 4
        case .export: return 5
        }
    }
}

/// Photos library picker for videos. limit 0 = any number.
struct VideoPhotosPicker: UIViewControllerRepresentable {
    var limit: Int
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = limit
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPhotosPicker
        init(_ parent: VideoPhotosPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else { parent.onCancel(); return }
            var urls = [URL?](repeating: nil, count: results.count)
            let lock = NSLock()
            let group = DispatchGroup()
            for (i, r) in results.enumerated() {
                group.enter()
                r.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    if let url = url {
                        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString + "." + ext)
                        if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                            lock.lock()
                            urls[i] = dest
                            lock.unlock()
                        }
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let list = urls.compactMap { $0 }
                if list.isEmpty { self.parent.onCancel() } else { self.parent.onPick(list) }
            }
        }
    }
}

/// Photos picker for one image (used for image overlays).
struct ImagePhotosPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePhotosPicker
        init(_ parent: ImagePhotosPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                parent.onCancel()
                return
            }
            provider.loadObject(ofClass: UIImage.self) { obj, _ in
                DispatchQueue.main.async {
                    if let img = obj as? UIImage { self.parent.onPick(img) } else { self.parent.onCancel() }
                }
            }
        }
    }
}

/// Files app picker (videos or audio). Files are copied into the app first.
struct FilePicker: UIViewControllerRepresentable {
    let types: [UTType]
    let multiple: Bool
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.allowsMultipleSelection = multiple
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FilePicker
        init(_ parent: FilePicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
