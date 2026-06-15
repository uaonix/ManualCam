import UIKit
import Foundation

// MARK: - Persistent photo store
// Saves thumbnails to app's Documents directory so they survive app restarts

final class PhotoStore: ObservableObject {
    @Published var photos: [UIImage] = []

    private let dir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("ManualCamPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() { load() }

    // Load all saved thumbnails on startup, sorted newest first
    func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let sorted = files
            .filter { $0.pathExtension == "jpg" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return d0 > d1   // newest first
            }

        photos = sorted.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let img  = UIImage(data: data) else { return nil }
            return img
        }
    }

    // Save a new photo and prepend to array
    func add(_ image: UIImage) {
        // Save full-res JPEG
        let name = "\(Date().timeIntervalSince1970).jpg"
        let url  = dir.appendingPathComponent(name)
        if let data = image.jpegData(compressionQuality: 0.92) {
            try? data.write(to: url)
        }
        DispatchQueue.main.async {
            self.photos.insert(image, at: 0)
        }
    }

    // Thumbnail for gallery grid
    static func thumbnail(from image: UIImage, size: CGFloat = 300) -> UIImage {
        let scale = size / max(image.size.width, image.size.height)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let thumb = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return thumb
    }
}
