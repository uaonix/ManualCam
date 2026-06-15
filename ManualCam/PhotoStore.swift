import UIKit
import Photos
import Foundation

// MARK: - PhotoStore
// Stores photo thumbnails in app's Documents folder.
// Syncs with the Photos library on every load so deleted photos disappear.

final class PhotoStore: ObservableObject {
    @Published var photos: [StoredPhoto] = []

    struct StoredPhoto: Identifiable {
        let id: String          // filename without extension
        var thumbnail: UIImage
        var localIdentifier: String?  // PHAsset identifier for deletion check
    }

    private let dir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("ManualCamPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    // Metadata file stores id → PHAsset localIdentifier mapping
    private var metaURL: URL { dir.appendingPathComponent("meta.json") }
    private var meta: [String: String] = [:]   // id → localIdentifier

    init() {
        loadMeta()
        load()
    }

    // MARK: - Load & sync
    func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let jpgFiles = files
            .filter { $0.pathExtension == "jpg" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return d0 > d1
            }

        var loaded: [StoredPhoto] = []
        for url in jpgFiles {
            let id = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let img  = UIImage(data: data) else { continue }
            let localId = meta[id]
            loaded.append(StoredPhoto(id: id, thumbnail: img, localIdentifier: localId))
        }

        // Sync: remove entries whose PHAsset was deleted from Photos library
        let synced = loaded.filter { photo in
            guard let localId = photo.localIdentifier else { return true }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
            if assets.count == 0 {
                // Asset deleted from Photos — remove our copy too
                let url = dir.appendingPathComponent("\(photo.id).jpg")
                try? FileManager.default.removeItem(at: url)
                meta.removeValue(forKey: photo.id)
                return false
            }
            return true
        }
        saveMeta()

        DispatchQueue.main.async { self.photos = synced }
    }

    // MARK: - Add
    func add(_ image: UIImage, localIdentifier: String? = nil) {
        let id   = "\(Int(Date().timeIntervalSince1970 * 1000))"
        let url  = dir.appendingPathComponent("\(id).jpg")

        // Save thumbnail (resized to save space)
        let thumb = Self.resize(image, maxDim: 600)
        if let data = thumb.jpegData(compressionQuality: 0.88) {
            try? data.write(to: url)
        }

        if let localId = localIdentifier {
            meta[id] = localId
            saveMeta()
        }

        DispatchQueue.main.async {
            self.photos.insert(
                StoredPhoto(id: id, thumbnail: thumb, localIdentifier: localIdentifier),
                at: 0
            )
        }
    }

    // MARK: - Delete from app only
    func delete(at offsets: IndexSet) {
        for i in offsets {
            let photo = photos[i]
            let url   = dir.appendingPathComponent("\(photo.id).jpg")
            try? FileManager.default.removeItem(at: url)
            meta.removeValue(forKey: photo.id)
        }
        saveMeta()
        photos.remove(atOffsets: offsets)
    }

    func delete(photo: StoredPhoto) {
        if let i = photos.firstIndex(where: { $0.id == photo.id }) {
            delete(at: IndexSet(integer: i))
        }
    }

    // MARK: - Refresh (call when app comes to foreground)
    func refresh() { load() }

    // MARK: - Helpers
    private func loadMeta() {
        guard let data = try? Data(contentsOf: metaURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        meta = dict
    }

    private func saveMeta() {
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL)
        }
    }

    static func resize(_ image: UIImage, maxDim: CGFloat) -> UIImage {
        let s = max(image.size.width, image.size.height)
        guard s > maxDim else { return image }
        let scale   = maxDim / s
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let out = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return out
    }
}
