import CoreGraphics
import Foundation
import ImageIO
import Photos
import PhotoEngineApple

/// A trip read straight from the Photos library, one thumbnail at a time.
public struct PhotoKitTripSource: TripPhotoSource {
    public let items: [TripPhotoItem]

    public init(assets: [PHAsset]) {
        items = assets.map { asset in
            TripPhotoItem(
                identifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            )
        }
    }

    public func thumbnail(for item: TripPhotoItem, maxPixel: Int) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.identifier], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                ] as CFDictionary))
            }
        }
    }
}

/// Reads a folder of JPEGs as if it were a Photos trip. Used by tests and the
/// Mac to exercise the streamed cull without a Photos library.
public struct FolderTripSource: TripPhotoSource {
    public let items: [TripPhotoItem]
    private let folder: URL

    public init(folder: URL) throws {
        self.folder = folder
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { ["jpg", "jpeg", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        let imported = try PhotoFolderImporter().importFolder(folder, thumbnailMaxPixelSize: 64)
        let byName = Dictionary(uniqueKeysWithValues: imported.map { (URL(fileURLWithPath: $0.asset.relativePath).lastPathComponent, $0.asset) })
        items = names.compactMap { name in
            guard let asset = byName[name] else { return nil }
            return TripPhotoItem(
                identifier: name,
                creationDate: asset.metadata.captureDate,
                modificationDate: asset.sourceModifiedAt,
                latitude: asset.metadata.latitude,
                longitude: asset.metadata.longitude,
                pixelWidth: asset.metadata.pixelWidth,
                pixelHeight: asset.metadata.pixelHeight
            )
        }
    }

    public func thumbnail(for item: TripPhotoItem, maxPixel: Int) async -> CGImage? {
        CGImage.photocoreThumbnail(url: folder.appendingPathComponent(item.identifier), maxPixel: maxPixel)
    }
}
