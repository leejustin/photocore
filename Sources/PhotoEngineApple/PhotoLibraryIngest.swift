import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import PhotoEngineCore

/// One exported library photo: the working-folder file the engine culls, and the
/// Photos asset it came from, so keepers can be written back as an album.
public struct LibraryExportEntry: Codable, Sendable, Equatable {
    public var fileName: String
    public var localIdentifier: String
    public var creationDate: Date?
    public var modificationDate: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var utility: UtilityShotKind

    public init(fileName: String, localIdentifier: String, creationDate: Date?, modificationDate: Date?, latitude: Double? = nil, longitude: Double? = nil, utility: UtilityShotKind = .none) {
        self.fileName = fileName
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.latitude = latitude
        self.longitude = longitude
        self.utility = utility
    }
}

/// Maps working-folder files back to Photos assets. Stored beside the exported
/// thumbnails so a resumed trip skips files that are already current, which keeps
/// file dates stable and lets the analysis cache hit.
public struct LibraryExportIndex: Codable, Sendable, Equatable {
    public static let fileName = "library-index.json"
    public var entries: [String: LibraryExportEntry]

    public init(entries: [String: LibraryExportEntry] = [:]) {
        self.entries = entries
    }

    public static func load(from folder: URL) -> LibraryExportIndex {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(LibraryExportIndex.self, from: data) else { return LibraryExportIndex() }
        return index
    }

    public func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Photos identifiers look like `UUID/L0/001`; the folder needs a flat, stable name.
    public static func fileName(for localIdentifier: String) -> String {
        let safe = localIdentifier.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return String(safe) + ".jpg"
    }

    /// True when the exported thumbnail on disk still matches the library asset.
    public func isCurrent(localIdentifier: String, modificationDate: Date?, in folder: URL) -> Bool {
        let name = Self.fileName(for: localIdentifier)
        guard let entry = entries[name], entry.modificationDate == modificationDate else { return false }
        return entry.utility != .none || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    public func localIdentifier(forFile name: String) -> String? {
        entries[name]?.localIdentifier
    }

    public var utilityCount: Int {
        entries.values.filter { $0.utility != .none }.count
    }
}

public struct LibraryIngestReport: Sendable {
    public var folder: URL
    public var exported: Int
    public var reused: Int
    public var skippedUtility: Int
    public var failed: Int
}

/// Reads a trip from the Photos library into a working folder of 1024-pixel JPEGs
/// with capture date and location in EXIF. The cull runs on that folder, exactly
/// as it does on a camera card, so the engine stays the same on Mac and iPhone.
public enum PhotoLibraryIngest {
    public static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Photos taken between two dates, oldest first. Screenshots are excluded here;
    /// receipts and documents are caught later by text coverage.
    public static func fetchPhotos(from start: Date, to end: Date) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
            PHAssetMediaType.image.rawValue, start as NSDate, end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            if !asset.mediaSubtypes.contains(.photoScreenshot) { assets.append(asset) }
        }
        return assets
    }

    public static func fetchPhotos(identifiers: [String]) -> [PHAsset] {
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    public static func workingFolder(named name: String) throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photocore/trips", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public static func export(
        _ assets: [PHAsset],
        to folder: URL,
        maxPixel: CGFloat = 1024,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> LibraryIngestReport {
        var index = LibraryExportIndex.load(from: folder)
        var exported = 0, reused = 0, failed = 0
        let manager = PHImageManager.default()
        for (position, asset) in assets.enumerated() {
            try Task.checkCancellation()
            defer { progress(position + 1, assets.count) }
            if index.isCurrent(localIdentifier: asset.localIdentifier, modificationDate: asset.modificationDate, in: folder) {
                reused += 1
                continue
            }
            guard let image = await requestImage(asset, manager: manager, maxPixel: maxPixel) else {
                failed += 1
                continue
            }
            let name = LibraryExportIndex.fileName(for: asset.localIdentifier)
            let utility = UtilityShotDetector.classify(image)
            var entry = LibraryExportEntry(
                fileName: name,
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                utility: utility
            )
            if utility == .none {
                do {
                    try writeJPEG(image, date: asset.creationDate, location: asset.location, to: folder.appendingPathComponent(name))
                    exported += 1
                } catch {
                    failed += 1
                    continue
                }
            } else {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                entry.utility = utility
            }
            index.entries[name] = entry
            if position % 50 == 49 { try? index.save(to: folder) }
        }
        try index.save(to: folder)
        return LibraryIngestReport(folder: folder, exported: exported, reused: reused, skippedUtility: index.utilityCount, failed: failed)
    }

    private static func requestImage(_ asset: PHAsset, manager: PHImageManager, maxPixel: CGFloat) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let scale = maxPixel / CGFloat(max(asset.pixelWidth, asset.pixelHeight, 1))
        let size = CGSize(width: CGFloat(asset.pixelWidth) * min(scale, 1), height: CGFloat(asset.pixelHeight) * min(scale, 1))
        return await withCheckedContinuation { continuation in
            manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)
                ] as CFDictionary)
                continuation.resume(returning: thumbnail)
            }
        }
    }

    /// Writes a culling thumbnail with the EXIF fields the engine reads for bursts,
    /// moments and the trip book's place names.
    public static func writeJPEG(_ image: CGImage, date: Date?, location: CLLocation?, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.88]
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: date)]
        }
        if let coordinate = location?.coordinate {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(coordinate.latitude),
                kCGImagePropertyGPSLatitudeRef: coordinate.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(coordinate.longitude),
                kCGImagePropertyGPSLongitudeRef: coordinate.longitude >= 0 ? "E" : "W"
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Writes culling results back to Photos: an album of keepers, optionally marked
/// as Favorites. Source photos are never modified or deleted.
public enum PhotoLibraryWriter {
    @discardableResult
    public static func saveAlbum(title: String, localIdentifiers: [String], markFavorite: Bool) async throws -> String? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else { return nil }
        var albumIdentifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            album.addAssets(assets)
            albumIdentifier = album.placeholderForCreatedAssetCollection.localIdentifier
            if markFavorite {
                assets.enumerateObjects { asset, _, _ in
                    PHAssetChangeRequest(for: asset).isFavorite = true
                }
            }
        }
        return albumIdentifier
    }
}

public extension LibraryExportIndex {
    /// Photos identifiers for the given culled photos, in capture order.
    func localIdentifiers(for photoIDs: [PhotoID], in result: PipelineResult) -> [String] {
        let wanted = Set(photoIDs)
        return result.analyzed
            .filter { wanted.contains($0.id) }
            .sorted { ($0.asset.metadata.captureDate ?? .distantPast) < ($1.asset.metadata.captureDate ?? .distantPast) }
            .compactMap { localIdentifier(forFile: URL(fileURLWithPath: $0.asset.relativePath).lastPathComponent) }
    }
}
