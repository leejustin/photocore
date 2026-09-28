import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

import PhotoEngineCore
import PhotoEnginePersistence

public struct ImportedPhoto: Sendable {
    public let asset: PhotoAsset
    public let thumbnail: Data

    public init(asset: PhotoAsset, thumbnail: Data) {
        self.asset = asset
        self.thumbnail = thumbnail
    }
}

public struct ImportIssue: Codable, Sendable, Equatable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct ImportBatch: Sendable {
    public let photos: [ImportedPhoto]
    public let issues: [ImportIssue]

    public init(photos: [ImportedPhoto], issues: [ImportIssue]) {
        self.photos = photos
        self.issues = issues
    }
}

public final class PhotoFolderImporter: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func importFolder(_ folder: URL, thumbnailMaxPixelSize: Int = AppleAnalysisEngine.analysisPixelSize) throws -> [ImportedPhoto] {
        try importFolderReport(folder, thumbnailMaxPixelSize: thumbnailMaxPixelSize).photos
    }

    public func importFolderReport(
        _ folder: URL,
        thumbnailMaxPixelSize: Int = AppleAnalysisEngine.analysisPixelSize,
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws -> ImportBatch {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PhotoEngineError.invalidFolder(folder)
        }

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw PhotoEngineError.invalidFolder(folder)
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if shouldCancel() { throw CancellationError() }
            guard Self.isSupportedImage(url), !PhotoFormatSupport.shouldSkipImport(url) else { continue }
            candidates.append(url)
        }

        let paired = Self.collapsePairedMasters(candidates, root: folder)
        var imported: [ImportedPhoto] = []
        var issues: [ImportIssue] = []
        for url in paired {
            try Task.checkCancellation()
            if shouldCancel() { throw CancellationError() }
            do {
                let metadata = try ImageMetadataReader.read(url: url)
                let relativePath = Self.relativePath(for: url, root: folder)
                let sourceModifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                let sourceSignature = try SHA256Hasher.quickSignature(url: url)
                // Full-file digests on huge RAW cards are expensive; use the
                // quick signature for RAW masters and a full hash for rendered files.
                let contentHash: String
                if metadata.format.isRawMaster {
                    contentHash = sourceSignature
                } else {
                    contentHash = try SHA256Hasher.hash(url: url)
                }
                let asset = PhotoAsset(
                    id: PhotoID(Self.stableUUID(
                        rootPath: folder.standardizedFileURL.path,
                        relativePath: relativePath,
                        metadata: metadata,
                        sourceFingerprint: contentHash
                    )),
                    url: url,
                    relativePath: relativePath,
                    metadata: metadata,
                    sourceModifiedAt: sourceModifiedAt,
                    sourceSignature: sourceSignature,
                    contentHash: contentHash
                )
                let thumbnail = try PreviewDiskCache.shared.jpegPreview(for: url, maxPixelSize: thumbnailMaxPixelSize)
                imported.append(ImportedPhoto(asset: asset, thumbnail: thumbnail))
            } catch {
                // A single corrupt file should not abort the complete import.
                issues.append(ImportIssue(path: url.path, message: error.localizedDescription))
            }
        }

        imported.sort {
            let leftDate = $0.asset.metadata.captureDate ?? .distantPast
            let rightDate = $1.asset.metadata.captureDate ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            return $0.asset.relativePath.localizedStandardCompare($1.asset.relativePath) == .orderedAscending
        }

        guard !imported.isEmpty else { throw PhotoEngineError.noPhotos(folder) }
        return ImportBatch(photos: imported, issues: issues)
    }

    public static func isSupportedImage(_ url: URL) -> Bool {
        PhotoFormatSupport.isSupportedImage(url)
    }

    private static func collapsePairedMasters(_ urls: [URL], root: URL) -> [URL] {
        var groups: [String: [URL]] = [:]
        for url in urls {
            let key = PhotoFormatSupport.pairingKey(for: url, root: root)
            groups[key, default: []].append(url)
        }
        return groups.keys.sorted().compactMap { key in
            guard let members = groups[key], !members.isEmpty else { return nil }
            return PhotoFormatSupport.preferMaster(in: members)
        }
    }

    public func countSupportedPhotos(in folder: URL) throws -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PhotoEngineError.invalidFolder(folder)
        }
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw PhotoEngineError.invalidFolder(folder)
        }

        var count = 0
        for case let url as URL in enumerator {
            if Self.isSupportedImage(url) { count += 1 }
        }
        return count
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
    }

    private static func stableUUID(rootPath: String, relativePath: String, metadata: PhotoMetadata, sourceFingerprint: String) -> UUID {
        let material = "\(rootPath.precomposedStringWithCanonicalMapping)\u{0}\(relativePath.precomposedStringWithCanonicalMapping)\u{0}\(metadata.fileSize)\u{0}\(sourceFingerprint)"
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        // RFC 9562 variant and custom/version-8 bits for a deterministic
        // application-defined identifier derived from SHA-256.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum ImageMetadataReader {
    static func read(url: URL) throws -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoEngineError.unreadableImage(url)
        }
        guard let dictionary = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? else {
            throw PhotoEngineError.unreadableImage(url)
        }

        let width = number(dictionary, key: kCGImagePropertyPixelWidth) ?? 0
        let height = number(dictionary, key: kCGImagePropertyPixelHeight) ?? 0
        guard width > 0, height > 0 else { throw PhotoEngineError.unreadableImage(url) }

        let orientation = number(dictionary, key: kCGImagePropertyOrientation) ?? 1
        let tiff = dictionary.object(forKey: kCGImagePropertyTIFFDictionary) as? NSDictionary
        let exif = dictionary.object(forKey: kCGImagePropertyExifDictionary) as? NSDictionary
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0

        let captureDate = captureDate(exif: exif, tiff: tiff)

        let format = PhotoFormatSupport.format(for: url)

        return PhotoMetadata(
            pixelWidth: width,
            pixelHeight: height,
            orientation: orientation,
            captureDate: captureDate,
            cameraMake: tiff?.object(forKey: kCGImagePropertyTIFFMake) as? String,
            cameraModel: tiff?.object(forKey: kCGImagePropertyTIFFModel) as? String,
            lensModel: exif?.object(forKey: kCGImagePropertyExifLensModel) as? String,
            fileSize: size,
            format: format,
            rating: readRating(from: source)
        )
    }

    private static func readRating(from source: CGImageSource) -> Int? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        let paths = ["xmp:Rating", "exif:Rating"]
        for path in paths {
            guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
                  let value = CGImageMetadataTagCopyValue(tag) else { continue }
            if let number = value as? NSNumber {
                let stars = number.intValue
                if (0...5).contains(stars) { return stars }
            }
            if let string = value as? String, let stars = Int(string), (0...5).contains(stars) {
                return stars
            }
        }
        return nil
    }

    static func thumbnailData(url: URL, maxPixelSize: Int, preferEmbedded: Bool = true) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoEngineError.unreadableImage(url)
        }
        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        if preferEmbedded {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return try jpegData(image: image, quality: 0.82)
        }
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        options.removeValue(forKey: kCGImageSourceCreateThumbnailFromImageIfAbsent)
        guard let fallback = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoEngineError.unreadableImage(url)
        }
        return try jpegData(image: fallback, quality: 0.82)
    }

    static func jpegData(image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoEngineError.exportFailed(URL(fileURLWithPath: "thumbnail.jpg"), "Could not create JPEG destination")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoEngineError.exportFailed(URL(fileURLWithPath: "thumbnail.jpg"), "Could not encode JPEG")
        }
        return data as Data
    }

    private static func number(_ dictionary: NSDictionary, key: CFString) -> Int? {
        (dictionary.object(forKey: key) as? NSNumber)?.intValue
    }

    private static func captureDate(exif: NSDictionary?, tiff: NSDictionary?) -> Date? {
        guard let dateString = (exif?.object(forKey: kCGImagePropertyExifDateTimeOriginal) as? String) ??
            (tiff?.object(forKey: kCGImagePropertyTIFFDateTime) as? String) else { return nil }
        let subseconds = (exif?.object(forKey: kCGImagePropertyExifSubsecTimeOriginal) as? String)
            .map { String($0.filter(\.isNumber).prefix(9)) }
        let offset = exif?.object(forKey: kCGImagePropertyExifOffsetTimeOriginal) as? String
        let fractionalSuffix = subseconds.flatMap { $0.isEmpty ? nil : ".\($0)" } ?? ""
        let fractionFormat = subseconds.flatMap { $0.isEmpty ? nil : ".\(String(repeating: "S", count: $0.count))" } ?? ""

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        if let offset, !offset.isEmpty {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss" + fractionFormat + "XXXXX"
            return formatter.date(from: dateString + fractionalSuffix + offset)
        }
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss" + fractionFormat
        return formatter.date(from: dateString + fractionalSuffix)
    }
}

public enum PhotoThumbnailProvider {
    public static func data(for url: URL, maxPixelSize: Int = 256) throws -> Data {
        try ImageMetadataReader.thumbnailData(url: url, maxPixelSize: maxPixelSize)
    }
}

public struct AppleAnalysisEngine: Sendable {
    /// Long edge of the upright thumbnail Vision and focus measurement share.
    public static let analysisPixelSize = 1024

    public init() {}

    public func analyze(asset: PhotoAsset, thumbnailData: Data? = nil) throws -> AnalysisSignals {
        let thumbnail = try thumbnailData ?? ImageMetadataReader.thumbnailData(url: asset.url, maxPixelSize: Self.analysisPixelSize)
        guard let imageSource = CGImageSourceCreateWithData(thumbnail as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw PhotoEngineError.unreadableImage(asset.url)
        }

        let contentHash: String
        if let existingHash = asset.contentHash {
            contentHash = existingHash
        } else {
            contentHash = try SHA256Hasher.hash(url: asset.url)
        }
        let pixels = PixelStatistics(image: image)
        let focusEnergy = FocusMeasure.energy(image: image)
        let vision = try visionSignals(image: image)
        let subject = SubjectFocusAssessment(image: image, faces: vision.faces)
        var qualityFlags = subject.flags
        if vision.subjectFaceCount > 0 && vision.faceQuality < 0.35 {
            qualityFlags.append("face quality low")
        }
        let eyeValues = vision.faces.compactMap(\.eyeOpenness)
        if !eyeValues.isEmpty {
            let averageOpen = eyeValues.reduce(0, +) / Double(eyeValues.count)
            if averageOpen < 0.28 {
                qualityFlags.append(PhotoTechnicalReject.eyesClosed)
            }
        }
        if pixels.sharpness < 0.06 {
            qualityFlags.append(PhotoTechnicalReject.extremeBlur)
        }
        if pixels.exposureQuality < 0.08 && (pixels.brightness < 0.08 || pixels.brightness > 0.92) {
            qualityFlags.append(PhotoTechnicalReject.unusableExposure)
        }
        if vision.faces.isEmpty {
            let looksUtility = vision.aestheticUtility == true
            let lowAesthetic = (vision.aestheticScore ?? 0.5) < 0.28
            let lowSubject = subject.confidence < 0.18
            if looksUtility || (lowAesthetic && lowSubject && pixels.sharpness < 0.42) {
                qualityFlags.append(PhotoTechnicalReject.noClearSubject)
            }
        }
        let fingerprint = PhotoFingerprint(contentHash: contentHash, perceptualHash: pixels.perceptualHash)

        return AnalysisSignals(
            fingerprint: fingerprint,
            brightness: pixels.brightness,
            exposureQuality: pixels.exposureQuality,
            sharpness: pixels.sharpness,
            subjectSharpness: subject.sharpness,
            subjectConfidence: subject.confidence,
            faceQuality: vision.faceQuality,
            faceCount: vision.faces.count,
            aestheticScore: vision.aestheticScore,
            aestheticUtility: vision.aestheticUtility,
            featurePrint: vision.featurePrint,
            faces: vision.faces,
            qualityFlags: qualityFlags,
            focusEnergy: focusEnergy
        )
    }

    private func visionSignals(image: CGImage) throws -> (featurePrint: Data?, faces: [FaceSignal], faceQuality: Double, aestheticScore: Double?, aestheticUtility: Bool?, subjectFaceCount: Int) {
        let featureRequest = VNGenerateImageFeaturePrintRequest()
        featureRequest.revision = VNGenerateImageFeaturePrintRequestRevision2
        let faceRequest = VNDetectFaceCaptureQualityRequest()
        faceRequest.revision = VNDetectFaceCaptureQualityRequestRevision3
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        var requests: [VNRequest] = [featureRequest, faceRequest, landmarksRequest]
        var aestheticsRequest: VNCalculateImageAestheticsScoresRequest?
        if #available(macOS 15.0, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            aestheticsRequest = request
            requests.append(request)
        }
        try handler.perform(requests)

        let featurePrint = try featureRequest.results?.first.map {
            try JSONEncoder().encode(Vision.FeaturePrintObservation($0))
        }

        let qualityObservations = faceRequest.results ?? []
        let landmarkObservations = landmarksRequest.results ?? []
        let faceSignals: [FaceSignal] = qualityObservations.enumerated().map { index, observation in
            let landmark = landmarkObservations.first {
                $0.boundingBox.intersects(observation.boundingBox)
            } ?? (index < landmarkObservations.count ? landmarkObservations[index] : nil)
            return FaceSignal(
                boundingBox: CGRectCodable(
                    x: observation.boundingBox.origin.x,
                    y: observation.boundingBox.origin.y,
                    width: observation.boundingBox.size.width,
                    height: observation.boundingBox.size.height
                ),
                captureQuality: observation.faceCaptureQuality.map(Double.init),
                eyeOpenness: landmark.flatMap(Self.eyeOpenness(for:))
            )
        }
        let qualifying = faceSignals.filter { $0.boundingBox.width * $0.boundingBox.height >= 0.004 }
        let subjectFaces: [FaceSignal]
        if !qualifying.isEmpty {
            subjectFaces = qualifying
        } else if let largest = faceSignals.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        }) {
            subjectFaces = [largest]
        } else {
            subjectFaces = []
        }
        let measuredQualities = subjectFaces.compactMap(\.captureQuality)
        let faceQuality: Double
        if measuredQualities.isEmpty {
            faceQuality = subjectFaces.isEmpty ? 0.5 : 0.35
        } else {
            // For group shots, an average can hide one very poor important
            // face. Blend a lower quantile with the mean so a single weak
            // subject is visible without making every background face
            // dominate the ranking.
            let sorted = measuredQualities.sorted()
            let lowerQuantile = sorted[min(sorted.count - 1, sorted.count / 4)]
            let average = sorted.reduce(0, +) / Double(sorted.count)
            faceQuality = lowerQuantile * 0.60 + average * 0.40
        }

        let aestheticScore = aestheticsRequest?.results?.first.map {
            min(max((Double($0.overallScore) + 1.0) / 2.0, 0), 1)
        }
        let aestheticUtility = aestheticsRequest?.results?.first?.isUtility
        return (featurePrint, faceSignals, min(max(faceQuality, 0), 1), aestheticScore, aestheticUtility, qualifying.count)
    }

    private static func eyeOpenness(for observation: VNFaceObservation) -> Double? {
        guard let landmarks = observation.landmarks else { return nil }
        let left = openness(for: landmarks.leftEye)
        let right = openness(for: landmarks.rightEye)
        switch (left, right) {
        case let (l?, r?): return min(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    private static func openness(for region: VNFaceLandmarkRegion2D?) -> Double? {
        guard let region, region.pointCount >= 4 else { return nil }
        let points = (0..<region.pointCount).map { region.normalizedPoints[$0] }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = max(maxX - minX, 0.0001)
        let height = max(maxY - minY, 0)
        // Open eyes are taller relative to their width; blinks collapse.
        return min(max(Double(height / width) / 0.45, 0), 1)
    }
}

public enum AppleVisualDistance {
    /// Serialized revision-2 feature print for an already-decoded, upright image.
    /// The analyzer and `photo-engine calibrate` both use this, so measured
    /// distances match what grouping sees.
    public static func featurePrintData(for image: CGImage) throws -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return try request.results?.first.map {
            try JSONEncoder().encode(Vision.FeaturePrintObservation($0))
        }
    }

    public static func distance(_ lhs: Data, _ rhs: Data) -> Double? {
        do {
            let decoder = JSONDecoder()
            let left = try decoder.decode(Vision.FeaturePrintObservation.self, from: lhs)
            let right = try decoder.decode(Vision.FeaturePrintObservation.self, from: rhs)
            return try left.distance(to: right)
        } catch {
            return nil
        }
    }

    public static func distance(_ lhs: AnalysisSignals, _ rhs: AnalysisSignals) -> Double? {
        guard let leftData = lhs.featurePrint, let rightData = rhs.featurePrint else { return nil }
        do {
            let decoder = JSONDecoder()
            let left = try decoder.decode(Vision.FeaturePrintObservation.self, from: leftData)
            let right = try decoder.decode(Vision.FeaturePrintObservation.self, from: rightData)
            return try left.distance(to: right)
        } catch {
            return nil
        }
    }

    /// Creates a run-scoped provider that decodes each serialized Vision
    /// descriptor at most once. Vision's observation type is reference based,
    /// so the cache is intentionally short-lived and confined to one run.
    public static func cachedProvider() -> VisualDistanceProvider {
        let cache = DecodedFeaturePrintCache()
        return { lhs, rhs in cache.distance(lhs, rhs) }
    }

    private final class DecodedFeaturePrintCache: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [Data: Vision.FeaturePrintObservation] = [:]

        func distance(_ lhs: AnalysisSignals, _ rhs: AnalysisSignals) -> Double? {
            guard let leftData = lhs.featurePrint, let rightData = rhs.featurePrint else { return nil }
            do {
                let left = try observation(for: leftData)
                let right = try observation(for: rightData)
                return try left.distance(to: right)
            } catch {
                return nil
            }
        }

        private func observation(for data: Data) throws -> Vision.FeaturePrintObservation {
            if let cached = lock.withLock({ observations[data] }) { return cached }
            let decoded = try JSONDecoder().decode(Vision.FeaturePrintObservation.self, from: data)
            lock.withLock { observations[data] = decoded }
            return decoded
        }
    }
}

public final class ApplePhotoRenderer: @unchecked Sendable {
    private let context: CIContext

    public init() {
        context = CIContext(options: [CIContextOption.cacheIntermediates: false])
    }

    public func releaseCaches() {
        context.clearCaches()
    }

    public func render(
        photo: AnalyzedPhoto,
        outputURL: URL,
        style: StylePreset = .natural,
        styleIntensity: Double = 0.65,
        exportSpecification: ExportSpecification = ExportSpecification()
    ) throws -> ExportedPhoto {
        try render(
            photo: photo,
            outputURL: outputURL,
            recipe: Self.recipe(for: photo, style: style, intensity: styleIntensity),
            exportSpecification: exportSpecification
        )
    }

    public func render(
        photo: AnalyzedPhoto,
        outputURL: URL,
        recipe: EditRecipe,
        exportSpecification: ExportSpecification = ExportSpecification()
    ) throws -> ExportedPhoto {
        let image = try Self.apply(recipe, to: Self.orientedImage(photo))

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let renderedImage: CIImage
        if let maxLongEdge = exportSpecification.maxLongEdge, maxLongEdge > 0 {
            let longEdge = max(image.extent.width, image.extent.height)
            if longEdge > CGFloat(maxLongEdge) {
                let scale = CGFloat(maxLongEdge) / longEdge
                renderedImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            } else {
                renderedImage = image
            }
        } else {
            renderedImage = image
        }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        guard let outputImage = context.createCGImage(
            renderedImage,
            from: renderedImage.extent,
            format: .RGBA8,
            colorSpace: sRGB
        ) else {
            throw PhotoEngineError.exportFailed(photo.asset.url, "Could not render edited image")
        }
        try Self.writeJPEG(
            image: outputImage,
            sourceURL: photo.asset.url,
            outputURL: outputURL,
            quality: exportSpecification.quality
        )

        return ExportedPhoto(photoID: photo.id, sourcePath: photo.asset.url.path, outputPath: outputURL.path, recipe: recipe)
    }

    /// A downscaled JPEG for the develop loupe. The full export path uses the same recipe.
    public func previewJPEG(photo: AnalyzedPhoto, recipe: EditRecipe, maxLongEdge: Int = 1600, quality: Double = 0.82) throws -> Data {
        var image = try Self.apply(recipe, to: Self.orientedImage(photo))
        let longEdge = max(image.extent.width, image.extent.height)
        let limit = CGFloat(max(256, maxLongEdge))
        if longEdge > limit, longEdge.isFinite {
            let scale = limit / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard image.extent.isInfinite == false, image.extent.isNull == false else {
            throw PhotoEngineError.exportFailed(photo.asset.url, "Edited preview had no pixels")
        }
        guard let outputImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw PhotoEngineError.exportFailed(photo.asset.url, "Could not render edited preview")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoEngineError.exportFailed(photo.asset.url, "Could not encode edited preview")
        }
        CGImageDestinationAddImage(destination, outputImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoEngineError.exportFailed(photo.asset.url, "Could not encode edited preview")
        }
        return data as Data
    }

    private static func orientedImage(_ photo: AnalyzedPhoto) throws -> CIImage {
        guard let input = CIImage(contentsOf: photo.asset.url, options: [.applyOrientationProperty: true]) else {
            throw PhotoEngineError.exportFailed(photo.asset.url, "Could not create Core Image input")
        }
        return input
    }

    static func apply(_ recipe: EditRecipe, to input: CIImage) -> CIImage {
        var image = input
        if abs(recipe.exposure) > 0.01 {
            let filter = CIFilter(name: "CIExposureAdjust")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(recipe.exposure, forKey: "inputEV")
            image = filter.outputImage ?? image
        }
        if abs(recipe.contrast) > 0.01 || abs(recipe.saturation) > 0.01 {
            let filter = CIFilter(name: "CIColorControls")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(1 + recipe.saturation, forKey: kCIInputSaturationKey)
            filter.setValue(1 + recipe.contrast, forKey: kCIInputContrastKey)
            image = filter.outputImage ?? image
        }
        let lookWarmth = recipe.style == .warm ? 700 * min(max(recipe.styleIntensity, 0), 1) : 0
        let kelvinShift = lookWarmth + recipe.temperature * 1800
        let tintShift = recipe.tint * 50
        if abs(kelvinShift) > 8 || abs(tintShift) > 0.4 {
            let filter = CIFilter(name: "CITemperatureAndTint")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            filter.setValue(CIVector(x: max(2000, 6500 - kelvinShift), y: tintShift), forKey: "inputTargetNeutral")
            image = filter.outputImage ?? image
        }
        if recipe.style == .blackAndWhite {
            let filter = CIFilter(name: "CIColorControls")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(1 - min(max(recipe.styleIntensity, 0), 1), forKey: kCIInputSaturationKey)
            image = filter.outputImage ?? image
        }
        if abs(recipe.highlights) > 0.01 || abs(recipe.shadows) > 0.01 {
            let filter = CIFilter(name: "CIHighlightShadowAdjust")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(min(max(recipe.shadows, -1), 1), forKey: "inputShadowAmount")
            // The Core Image filter's neutral highlight value is 1, whereas
            // EditRecipe intentionally stores a relative adjustment.
            filter.setValue(min(max(1 + recipe.highlights, 0), 1), forKey: "inputHighlightAmount")
            image = filter.outputImage ?? image
        }
        if abs(recipe.clarity) > 0.02 {
            let extent = image.extent
            if recipe.clarity > 0 {
                let filter = CIFilter(name: "CIUnsharpMask")!
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(14, forKey: kCIInputRadiusKey)
                filter.setValue(min(recipe.clarity, 1.5), forKey: kCIInputIntensityKey)
                image = (filter.outputImage ?? image).cropped(to: extent)
            } else {
                let filter = CIFilter(name: "CIGaussianBlur")!
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(min(-recipe.clarity * 3, 8), forKey: kCIInputRadiusKey)
                image = (filter.outputImage ?? image).cropped(to: extent)
            }
        }
        if abs(recipe.sharpening) > 0.01 {
            let filter = CIFilter(name: "CISharpenLuminance")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(recipe.sharpening, forKey: "inputSharpness")
            image = filter.outputImage ?? image
        }
        if abs(recipe.straighten) > 0.05 {
            image = Self.straighten(image, degrees: recipe.straighten)
        }
        if let lookID = recipe.albumLookID,
           let look = AlbumLookLibrary.shared.look(id: lookID),
           let filter = try? AlbumLookLibrary.shared.colorCubeFilter(for: look) {
            filter.setValue(image, forKey: kCIInputImageKey)
            image = filter.outputImage ?? image
        }
        return image
    }

    public static func detectHorizonDegrees(url: URL, orientation: Int) -> Double? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(url: url, orientation: CGImagePropertyOrientation(exifOrientation: orientation), options: [:])
        do {
            try handler.perform([request])
            guard let angle = request.results?.first?.angle else { return nil }
            // Vision angle is radians; convert to degrees and invert for our straighten convention.
            return -Double(angle) * 180 / .pi
        } catch {
            return nil
        }
    }

    /// Rotates around the center and scales just enough to hide the empty corners.
    static func straighten(_ image: CIImage, degrees: Double) -> CIImage {
        let extent = image.extent
        guard extent.isNull == false, extent.isInfinite == false, extent.width > 1, extent.height > 1 else { return image }
        let angle = CGFloat(degrees * .pi / 180)
        var rotation = CGAffineTransform(translationX: extent.midX, y: extent.midY)
        rotation = rotation.rotated(by: angle)
        rotation = rotation.translatedBy(x: -extent.midX, y: -extent.midY)
        let rotated = image.transformed(by: rotation)
        let cosine = abs(cos(angle))
        let sine = abs(sin(angle))
        let scale = max(
            cosine + sine * extent.height / extent.width,
            cosine + sine * extent.width / extent.height
        ) * 1.02
        let center = CGPoint(x: rotated.extent.midX, y: rotated.extent.midY)
        var zoom = CGAffineTransform(translationX: center.x, y: center.y)
        zoom = zoom.scaledBy(x: scale, y: scale)
        zoom = zoom.translatedBy(x: -center.x, y: -center.y)
        let scaled = rotated.transformed(by: zoom)
        let crop = CGRect(
            x: scaled.extent.midX - extent.width / 2,
            y: scaled.extent.midY - extent.height / 2,
            width: extent.width,
            height: extent.height
        )
        guard crop.width > 1, crop.height > 1 else { return image }
        return scaled.cropped(to: crop)
    }

    public static func recipe(for photo: AnalyzedPhoto, style: StylePreset = .natural, intensity: Double = 0.65) -> EditRecipe {
        let intensity = min(max(intensity, 0), 1)
        let brightnessDelta = 0.5 - photo.signals.brightness
        let exposure = min(max(brightnessDelta * 1.2, -0.45), 0.45)
        let highlights = photo.signals.exposureQuality < 0.45 ? -0.10 : 0
        let shadows = photo.signals.brightness < 0.38 ? 0.14 : 0
        let baseSaturation = photo.signals.aestheticScore.map { $0 < 0.48 ? 0.04 : 0.015 } ?? 0.02
        let baseContrast = photo.signals.exposureQuality > 0.60 ? 0.025 : 0
        let styleSaturation: Double
        let styleContrast: Double
        let styleHighlights: Double
        let styleShadows: Double
        let styleSharpening: Double
        switch style {
        case .natural:
            styleSaturation = 0; styleContrast = 0; styleHighlights = 0; styleShadows = 0; styleSharpening = 0
        case .warm:
            styleSaturation = 0.035; styleContrast = 0.015; styleHighlights = 0; styleShadows = 0.02; styleSharpening = 0
        case .vibrant:
            styleSaturation = 0.12; styleContrast = 0.04; styleHighlights = -0.04; styleShadows = 0.02; styleSharpening = 0.01
        case .soft:
            styleSaturation = 0.015; styleContrast = -0.055; styleHighlights = -0.08; styleShadows = 0.08; styleSharpening = -0.03
        case .blackAndWhite:
            styleSaturation = -1; styleContrast = 0.02; styleHighlights = 0; styleShadows = 0; styleSharpening = 0
        }
        let scaled = { (value: Double) in value * intensity }
        let sharpening = max(0, (photo.signals.sharpness < 0.55 ? 0.16 : 0.08) + scaled(styleSharpening))
        return EditRecipe(
            style: style,
            styleIntensity: intensity,
            exposure: exposure,
            contrast: baseContrast + scaled(styleContrast),
            // Black & white is applied in a separate intensity-aware filter;
            // keeping this technical saturation neutral makes a 0…1 look
            // slider genuinely reversible.
            saturation: style == .blackAndWhite ? 0 : baseSaturation + scaled(styleSaturation),
            highlights: highlights + scaled(styleHighlights),
            shadows: shadows + scaled(styleShadows),
            sharpening: sharpening
        )
    }

    private static func writeJPEG(image: CGImage, sourceURL: URL, outputURL: URL, quality: Double) throws {
        let properties: NSMutableDictionary
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? {
            properties = sourceProperties.mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
        } else {
            properties = NSMutableDictionary()
        }

        // Preserve useful camera, lens, exposure, date, copyright, and color
        // metadata while stripping location by default. The pixels have already
        // been oriented, so leaving the original orientation would rotate them
        // a second time in metadata-aware viewers.
        properties.removeObject(forKey: kCGImagePropertyGPSDictionary)
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height
        properties[kCGImageDestinationLossyCompressionQuality] = quality

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoEngineError.exportFailed(outputURL, "Could not create JPEG destination")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true
        ] as CFDictionary)
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoEngineError.exportFailed(outputURL, "Could not encode JPEG")
        }
        do {
            try (data as Data).write(to: outputURL, options: .atomic)
        } catch {
            throw PhotoEngineError.exportFailed(outputURL, error.localizedDescription)
        }
    }
}

public struct PipelineProgress: Sendable {
    public enum Stage: String, Sendable {
        case discovering
        case analyzing
        case grouping
        case selecting
        case exporting
        case complete
    }

    public let stage: Stage
    public let completed: Int
    public let total: Int
    public let message: String

    public init(stage: Stage, completed: Int, total: Int, message: String) {
        self.stage = stage
        self.completed = completed
        self.total = total
        self.message = message
    }
}

public struct PipelineResult: Sendable {
    public let sessionID: SessionID
    /// Assets only: analysis thumbnails are intentionally released after a run
    /// so large libraries do not remain resident in the UI process.
    public let imported: [PhotoAsset]
    public let analyzed: [AnalyzedPhoto]
    public let grouping: PhotoGrouping
    public let scored: [ScoredPhoto]
    public let shortlist: Shortlist
    public let exports: [ExportedPhoto]
    public let manifestURL: URL
    public let warnings: [ImportIssue]
    public let runDirectory: URL
    public let storageSummary: PhotoCatalog.StorageSummary?
    public let metrics: PipelineMetrics
    public let exportSpecification: ExportSpecification

    public init(sessionID: SessionID, imported: [PhotoAsset], analyzed: [AnalyzedPhoto], grouping: PhotoGrouping, scored: [ScoredPhoto], shortlist: Shortlist, exports: [ExportedPhoto], manifestURL: URL, warnings: [ImportIssue], runDirectory: URL, storageSummary: PhotoCatalog.StorageSummary?, metrics: PipelineMetrics = PipelineMetrics(), exportSpecification: ExportSpecification = ExportSpecification()) {
        self.sessionID = sessionID
        self.imported = imported
        self.analyzed = analyzed
        self.grouping = grouping
        self.scored = scored
        self.shortlist = shortlist
        self.exports = exports
        self.manifestURL = manifestURL
        self.warnings = warnings
        self.runDirectory = runDirectory
        self.storageSummary = storageSummary
        self.metrics = metrics
        self.exportSpecification = exportSpecification
    }
}

/// Produces a conservative, non-destructive cleanup preview. The first
/// implementation only proposes byte-identical hidden copies; near-duplicate
/// frames are never treated as safe deletion candidates.
public enum PhotoCleanupPlanner {
    public static func preview(result: PipelineResult, policy: CleanupPolicy) -> CleanupPlan {
        guard policy != .preserveOriginals else {
            return CleanupPlan(sessionID: result.sessionID, policy: policy, candidates: [])
        }

        let analyzedByID = Dictionary(uniqueKeysWithValues: result.analyzed.map { ($0.id, $0) })
        let decisionsByID = Dictionary(uniqueKeysWithValues: result.shortlist.decisions.map { ($0.photoID, $0) })
        var candidates: [CleanupCandidate] = []
        var warnings: [String] = []

        for group in result.grouping.groups where group.kind == .exactDuplicate {
            let members = group.memberIDs.compactMap { analyzedByID[$0] }
            guard let retained = members.first(where: {
                decisionsByID[$0.id]?.bucket != .hidden
            }) else {
                warnings.append("No retained occurrence was recorded for exact-duplicate group \(group.id.uuidString).")
                continue
            }
            for member in members where member.id != retained.id {
                guard decisionsByID[member.id]?.bucket == .hidden else { continue }
                guard member.signals.fingerprint.contentHash == retained.signals.fingerprint.contentHash else {
                    warnings.append("Skipped \(member.asset.url.path): duplicate evidence changed.")
                    continue
                }
                let sourceURL = member.asset.url.standardizedFileURL
                let retainedURL = retained.asset.url.standardizedFileURL
                guard sourceURL != retainedURL else { continue }
                guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
                    warnings.append("Skipped \(sourceURL.path): source is no longer readable.")
                    continue
                }
                guard FileManager.default.isReadableFile(atPath: retainedURL.path) else {
                    warnings.append("Skipped \(sourceURL.path): retained copy is no longer readable.")
                    continue
                }
                candidates.append(CleanupCandidate(
                    photoID: member.id,
                    sourcePath: sourceURL.path,
                    retainedPath: retainedURL.path,
                    contentHash: member.signals.fingerprint.contentHash,
                    bytes: member.asset.metadata.fileSize,
                    reason: "byte-identical copy of a retained occurrence"
                ))
            }
        }

        candidates.sort { $0.sourcePath < $1.sourcePath }
        return CleanupPlan(
            sessionID: result.sessionID,
            policy: policy,
            candidates: candidates,
            warnings: warnings
        )
    }

    /// Executes an already-reviewed plan using the system Trash. Every source
    /// is re-hashed immediately before mutation, so stale approvals become a
    /// skipped item instead of deleting a changed file.
    public static func moveToTrash(
        _ plan: CleanupPlan,
        fileManager: FileManager = .default
    ) -> CleanupReport {
        guard plan.policy != .preserveOriginals else {
            return CleanupReport(planID: plan.id, movedPhotoIDs: [], skipped: ["Preserve-originals policy has no cleanup targets."])
        }

        var moved: [PhotoID] = []
        var skipped = plan.warnings
        for candidate in plan.candidates {
            let sourceURL = URL(fileURLWithPath: candidate.sourcePath)
            let retainedURL = URL(fileURLWithPath: candidate.retainedPath)
            guard fileManager.isReadableFile(atPath: sourceURL.path) else {
                skipped.append("Skipped \(candidate.sourcePath): source is missing or unreadable.")
                continue
            }
            guard fileManager.isReadableFile(atPath: retainedURL.path) else {
                skipped.append("Skipped \(candidate.sourcePath): retained copy is missing or unreadable.")
                continue
            }
            do {
                guard try SHA256Hasher.hash(url: sourceURL) == candidate.contentHash else {
                    skipped.append("Skipped \(candidate.sourcePath): source content changed since approval.")
                    continue
                }
                try fileManager.trashItem(at: sourceURL, resultingItemURL: nil)
                moved.append(candidate.photoID)
            } catch {
                skipped.append("Skipped \(candidate.sourcePath): \(error.localizedDescription)")
            }
        }
        return CleanupReport(planID: plan.id, movedPhotoIDs: moved, skipped: skipped)
    }
}

/// Removes generated exports and superseded run folders. Source photographs are
/// never touched by this helper.
public enum GeneratedArtifactCleanup {
    public struct DiscardResult: Sendable {
        public let exports: [ExportedPhoto]
        public let removedPath: String?
        public let storageSummary: PhotoCatalog.StorageSummary?
    }

    public static let bucketsThatRetainExports: Set<SelectionBucket> = [.selected, .protected]

    public static func discardExport(
        photoID: PhotoID,
        from result: PipelineResult,
        sessionID: SessionID,
        catalog: PhotoCatalog?,
        cacheBytes: Int64 = 0,
        fileManager: FileManager = .default
    ) throws -> DiscardResult {
        guard let export = result.exports.first(where: { $0.photoID == photoID }) else {
            return DiscardResult(exports: result.exports, removedPath: nil, storageSummary: result.storageSummary)
        }

        let outputURL = URL(fileURLWithPath: export.outputPath).standardizedFileURL
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.trashItem(at: outputURL, resultingItemURL: nil)
        }
        if let catalog {
            try catalog.deleteArtifact(sessionID: sessionID, photoID: photoID, kind: "jpeg-export")
        }

        let exports = result.exports.filter { $0.photoID != photoID }
        let storageSummary = try catalog?.storageSummary(sessionID: sessionID, cacheBytes: cacheBytes) ?? result.storageSummary
        return DiscardResult(exports: exports, removedPath: export.outputPath, storageSummary: storageSummary)
    }

    public static func pruneSupersededRuns(
        in outputDirectory: URL,
        keeping runDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Int {
        let runsRoot = outputDirectory.appendingPathComponent("runs", isDirectory: true)
        guard fileManager.fileExists(atPath: runsRoot.path) else { return 0 }
        let keepingPath = runDirectory?.standardizedFileURL.path
        let runURLs = try fileManager.contentsOfDirectory(
            at: runsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for runURL in runURLs {
            let values = try runURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            if let keepingPath, runURL.standardizedFileURL.path == keepingPath { continue }
            // Only folders Photocore created carry the marker. Anything else in
            // `runs/` belongs to someone else and is never touched.
            let marker = runURL.appendingPathComponent(PhotoPipelineRunner.runMarkerFileName)
            guard fileManager.fileExists(atPath: marker.path) else { continue }
            try fileManager.removeItem(at: runURL)
            removed += 1
        }
        return removed
    }
}

public final class PhotoPipelineRunner: @unchecked Sendable {
    private let importer: PhotoFolderImporter
    private let analyzer: AppleAnalysisEngine
    private let renderer: ApplePhotoRenderer
    private let catalog: PhotoCatalog?
    private let catalogInitializationMessage: String?

    public init(importer: PhotoFolderImporter = PhotoFolderImporter(), analyzer: AppleAnalysisEngine = AppleAnalysisEngine(), renderer: ApplePhotoRenderer = ApplePhotoRenderer(), catalog: PhotoCatalog? = nil) {
        self.importer = importer
        self.analyzer = analyzer
        self.renderer = renderer
        if let catalog {
            self.catalog = catalog
            self.catalogInitializationMessage = nil
        } else {
            do {
                self.catalog = try PhotoCatalog()
                self.catalogInitializationMessage = nil
            } catch {
                self.catalog = nil
                self.catalogInitializationMessage = error.localizedDescription
            }
        }
    }

    public func saveReviewMark(_ mark: PhotoReviewMark) throws {
        guard let catalog else {
            throw PhotoEngineError.invalidArgument("The local catalog is unavailable; this rating could not be saved.")
        }
        try catalog.saveReviewMark(mark)
    }

    public func reviewMarks(for photoIDs: [PhotoID]) throws -> [PhotoReviewMark] {
        guard let catalog else { return [] }
        return try catalog.reviewMarks(for: photoIDs)
    }

    public func setOverride(
        sessionID: SessionID,
        photoID: PhotoID,
        bucket: SelectionBucket,
        reason: String = "user override"
    ) throws {
        guard let catalog else {
            throw PhotoEngineError.invalidArgument("The local catalog is unavailable; this override could not be saved.")
        }
        let override = SelectionOverride(photoID: photoID, bucket: bucket, reason: reason)
        try catalog.saveOverride(override)
        try catalog.applyOverride(override, sessionID: sessionID)
    }

    public func recordCleanupPlan(_ plan: CleanupPlan) throws {
        guard let catalog else { return }
        try catalog.recordCleanupPlan(plan)
    }

    public func updateCleanupPlanStatus(
        _ planID: UUID,
        status: String,
        approvedAt: Date? = nil,
        completedAt: Date? = nil
    ) throws {
        guard let catalog else { return }
        try catalog.updateCleanupPlanStatus(planID, status: status, approvedAt: approvedAt, completedAt: completedAt)
    }

    public func discardExport(photoID: PhotoID, from result: PipelineResult) throws -> GeneratedArtifactCleanup.DiscardResult {
        try GeneratedArtifactCleanup.discardExport(
            photoID: photoID,
            from: result,
            sessionID: result.sessionID,
            catalog: catalog,
            cacheBytes: result.storageSummary?.cacheBytes ?? 0
        )
    }

    public func prunePreviousRuns(in outputDirectory: URL, keeping runDirectory: URL? = nil) throws -> Int {
        try GeneratedArtifactCleanup.pruneSupersededRuns(in: outputDirectory, keeping: runDirectory)
    }

    public func run(
        folder: URL,
        outputDirectory: URL,
        profile: ScoringProfile,
        exportSpecification: ExportSpecification = ExportSpecification(),
        progress: @escaping @Sendable (PipelineProgress) -> Void = { _ in },
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> PipelineResult {
        try Self.validateOutput(source: folder, output: outputDirectory)
        try Self.checkCancellation(shouldCancel)
        let removedRuns = try GeneratedArtifactCleanup.pruneSupersededRuns(in: outputDirectory)
        if removedRuns > 0 {
            progress(PipelineProgress(
                stage: .discovering,
                completed: 0,
                total: 1,
                message: "Removed \(removedRuns) previous export pass(es)"
            ))
        }
        let runStartedAt = Date()
        let sessionID = SessionID()
        var warnings = [ImportIssue]()
        var catalogHealthy = catalog != nil
        if let catalogInitializationMessage {
            warnings.append(ImportIssue(
                path: PhotoCatalog.defaultURL().path,
                message: "Local catalog unavailable: \(catalogInitializationMessage)"
            ))
        }
        var sessionFinished = false
        var cacheHits = 0
        var workerCount = 0
        let discoveryStartedAt = Date()
        var discoverySeconds = 0.0
        var analysisSeconds = 0.0
        var groupingSeconds = 0.0
        var selectionSeconds = 0.0
        var exportSeconds = 0.0
        defer {
            if !sessionFinished, let catalog {
                try? catalog.finishSession(sessionID, status: "failed")
            }
        }
        progress(PipelineProgress(stage: .discovering, completed: 0, total: 1, message: "Discovering photos"))
        let importBatch = try importer.importFolderReport(folder, shouldCancel: shouldCancel)
        let imported = importBatch.photos
        warnings.append(contentsOf: importBatch.issues)
        discoverySeconds = Date().timeIntervalSince(discoveryStartedAt)
        if let catalog, catalogHealthy {
            do {
                try catalog.beginSession(id: sessionID, sourceFolder: folder, settings: profile)
                for item in imported {
                    try catalog.upsert(asset: item.asset, sessionID: sessionID)
                }
            } catch {
                catalogHealthy = false
                warnings.append(ImportIssue(path: PhotoCatalog.defaultURL().path, message: error.localizedDescription))
            }
        }
        progress(PipelineProgress(stage: .discovering, completed: 1, total: 1, message: "Found \(imported.count) photos"))

        let cache = AnalysisCache(sourceFolder: folder)
        let accumulator = ConcurrentAnalysisAccumulator(count: imported.count)
        var uncachedIndices: [Int] = []
        var cachedSignalsByContentHash: [String: AnalysisSignals] = [:]
        for (index, item) in imported.enumerated() {
            if let cached = cache.signals(for: item.asset) {
                cacheHits += 1
                if let contentHash = item.asset.contentHash {
                    cachedSignalsByContentHash[contentHash] = cached
                }
                accumulator.record(cached, at: index) { completed in
                    progress(PipelineProgress(
                        stage: .analyzing,
                        completed: completed,
                        total: imported.count,
                        message: item.asset.relativePath + " (cached)"
                    ))
                }
            } else {
                uncachedIndices.append(index)
            }
        }

        var exactReuseCount = 0
        var duplicateIndicesByRepresentative: [Int: [Int]] = [:]
        var analysisRepresentatives: [Int] = []
        for indices in Dictionary(grouping: uncachedIndices, by: { index in
            imported[index].asset.contentHash ?? imported[index].asset.url.standardizedFileURL.path
        }).values {
            let ordered = indices.sorted()
            guard let representative = ordered.first else { continue }
            if let contentHash = imported[representative].asset.contentHash,
               let cached = cachedSignalsByContentHash[contentHash] {
                for index in ordered {
                    exactReuseCount += 1
                    let item = imported[index]
                    accumulator.record(cached, at: index) { completed in
                        progress(PipelineProgress(
                            stage: .analyzing,
                            completed: completed,
                            total: imported.count,
                            message: item.asset.relativePath + " (exact-content reuse)"
                        ))
                    }
                }
            } else {
                analysisRepresentatives.append(representative)
                duplicateIndicesByRepresentative[representative] = Array(ordered.dropFirst())
            }
        }
        analysisRepresentatives.sort()

        if !analysisRepresentatives.isEmpty {
            let pendingIndices = analysisRepresentatives
            let workers = min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 1), 4, pendingIndices.count)
            workerCount = workers
            let analysisStartedAt = Date()
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                for position in stride(from: worker, to: pendingIndices.count, by: workers) {
                    guard !accumulator.hasError, !shouldCancel() else { return }
                    let index = pendingIndices[position]
                    let item = imported[index]
                    var stopWorker = false
                    autoreleasepool {
                        do {
                            let signals = try analyzer.analyze(asset: item.asset, thumbnailData: item.thumbnail)
                            accumulator.record(signals, at: index) { completed in
                                progress(PipelineProgress(
                                    stage: .analyzing,
                                    completed: completed,
                                    total: imported.count,
                                    message: item.asset.relativePath
                                ))
                            }
                        } catch {
                            accumulator.record(error: error)
                            stopWorker = true
                        }
                    }
                    if stopWorker { return }
                }
            }
            for representative in analysisRepresentatives {
                guard let signals = accumulator.result(at: representative) else { continue }
                for index in duplicateIndicesByRepresentative[representative] ?? [] {
                    exactReuseCount += 1
                    let item = imported[index]
                    accumulator.record(signals, at: index) { completed in
                        progress(PipelineProgress(
                            stage: .analyzing,
                            completed: completed,
                            total: imported.count,
                            message: item.asset.relativePath + " (exact-content reuse)"
                        ))
                    }
                }
            }
            analysisSeconds = Date().timeIntervalSince(analysisStartedAt)
        } else {
            analysisSeconds = 0
        }
        try Self.checkCancellation(shouldCancel)
        if let error = accumulator.firstError { throw error }

        let signalsByIndex = try accumulator.completeResults()
        let rawAnalyzed = zip(imported, signalsByIndex).map { item, signals in
            AnalyzedPhoto(asset: item.asset, signals: signals)
        }
        for index in uncachedIndices {
            cache.update(asset: imported[index].asset, signals: signalsByIndex[index])
        }
        if let catalog, catalogHealthy {
            do {
                for (asset, signals) in zip(imported.map(\.asset), signalsByIndex) {
                    try catalog.upsert(asset: asset, sessionID: sessionID, contentHash: signals.fingerprint.contentHash)
                    try catalog.upsert(analysis: signals, for: asset.id, analyzerVersion: "apple-analysis-0.5.0")
                }
            } catch {
                catalogHealthy = false
                warnings.append(ImportIssue(path: PhotoCatalog.defaultURL().path, message: error.localizedDescription))
            }
        }
        cache.retainAssets(imported.map(\.asset))
        try cache.save()

        let analyzed = PhotoFocusRanking.apply(to: rawAnalyzed)

        progress(PipelineProgress(stage: .grouping, completed: 0, total: 1, message: "Grouping duplicates and bursts"))
        let visualDistance = AppleVisualDistance.cachedProvider()
        let groupingStartedAt = Date()
        let grouping = PhotoGroupingEngine.group(analyzed, profile: profile, visualDistance: visualDistance)
        groupingSeconds = Date().timeIntervalSince(groupingStartedAt)
        progress(PipelineProgress(stage: .grouping, completed: 1, total: 1, message: "Found \(grouping.groups.count) groups"))

        let scored = analyzed.map { ScoredPhoto(photo: $0, score: PhotoScoring.score($0, profile: profile)) }
        progress(PipelineProgress(stage: .selecting, completed: 0, total: 1, message: "Building shortlist"))
        let selectionStartedAt = Date()
        var selectionProfile = profile
        selectionProfile.targetCount = profile.resolvedTargetCount(for: analyzed.count)
        var shortlist = PhotoSelectionEngine.select(scored, grouping: grouping, profile: selectionProfile, visualDistance: visualDistance)
        selectionSeconds = Date().timeIntervalSince(selectionStartedAt)
        if let catalog, catalogHealthy {
            do {
                let overrides = try catalog.overrides(for: analyzed.map(\.id))
                shortlist = PhotoSelectionEngine.applying(overrides, to: shortlist)
            } catch {
                catalogHealthy = false
                warnings.append(ImportIssue(path: PhotoCatalog.defaultURL().path, message: error.localizedDescription))
            }
        }
        progress(PipelineProgress(stage: .selecting, completed: 1, total: 1, message: "Selected \(shortlist.selectedIDs.count) photos"))
        if let catalog, catalogHealthy {
            do {
                try catalog.replaceDecisions(shortlist.decisions, sessionID: sessionID)
            } catch {
                catalogHealthy = false
                warnings.append(ImportIssue(path: PhotoCatalog.defaultURL().path, message: error.localizedDescription))
            }
        }

        let runDirectory = Self.makeRunDirectory(root: outputDirectory)
        var completedRun = false
        defer {
            if !completedRun {
                let marker = runDirectory.appendingPathComponent(Self.runMarkerFileName)
                if FileManager.default.fileExists(atPath: marker.path) {
                    try? FileManager.default.removeItem(at: runDirectory)
                }
            }
        }
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try Data("photocore run \(sessionID)\n".utf8)
            .write(to: runDirectory.appendingPathComponent(Self.runMarkerFileName), options: .atomic)
        let exportDirectory = runDirectory.appendingPathComponent("shortlist", isDirectory: true)
        var exports: [ExportedPhoto] = []
        let exportStartedAt = Date()
        for (index, photoID) in shortlist.selectedIDs.enumerated() {
            try autoreleasepool {
                try Self.checkCancellation(shouldCancel)
                guard let analyzedPhoto = analyzed.first(where: { $0.id == photoID }) else { return }
                let fileName = String(format: "%03d-%@.jpg", index + 1, safeFileStem(analyzedPhoto.asset.url.deletingPathExtension().lastPathComponent))
                let outputURL = exportDirectory.appendingPathComponent(fileName)
                let exported = try renderer.render(
                    photo: analyzedPhoto,
                    outputURL: outputURL,
                    style: profile.style,
                    styleIntensity: profile.styleIntensity,
                    exportSpecification: exportSpecification
                )
                exports.append(exported)
                if let catalog, catalogHealthy {
                    do {
                        try catalog.recordArtifact(sessionID: sessionID, photoID: photoID, kind: "jpeg-export", url: outputURL, recipe: exported.recipe)
                    } catch {
                        catalogHealthy = false
                        warnings.append(ImportIssue(path: PhotoCatalog.defaultURL().path, message: error.localizedDescription))
                    }
                }
                if (index + 1) % 20 == 0 {
                    renderer.releaseCaches()
                }
                progress(PipelineProgress(stage: .exporting, completed: index + 1, total: shortlist.selectedIDs.count, message: fileName))
            }
        }
        exportSeconds = Date().timeIntervalSince(exportStartedAt)

        var storageSummary: PhotoCatalog.StorageSummary?
        if let catalog, catalogHealthy {
            do {
                try catalog.finishSession(sessionID)
                storageSummary = try catalog.storageSummary(sessionID: sessionID, cacheBytes: cache.fileSize)
            } catch {
                warnings.append(ImportIssue(path: PhotoCatalog.defaultURL().path, message: error.localizedDescription))
            }
        }
        let manifest = PipelineManifest(
            sessionID: sessionID,
            schemaVersion: 3,
            pipelineVersion: "0.3.0",
            sourceFolder: folder.path,
            mode: profile.mode,
            profile: profile,
            aggressiveness: profile.aggressiveness,
            style: profile.style,
            styleIntensity: profile.styleIntensity,
            targetCount: selectionProfile.targetCount,
            exportSpecification: exportSpecification,
            assets: imported.map(\.asset),
            // Feature prints remain in the compact analysis cache. They are
            // implementation details and would dominate the portable manifest.
            analyzed: rawAnalyzed.map { $0.removingFeaturePrint() },
            grouping: grouping,
            shortlist: shortlist,
            exports: exports,
            warnings: warnings.map { "\($0.path): \($0.message)" },
            metrics: PipelineMetrics(
                totalSeconds: Date().timeIntervalSince(runStartedAt),
                discoverySeconds: discoverySeconds,
                analysisSeconds: analysisSeconds,
                groupingSeconds: groupingSeconds,
                selectionSeconds: selectionSeconds,
                exportSeconds: exportSeconds,
                cacheHits: cacheHits,
                exactContentReuses: exactReuseCount,
                analyzedCount: analyzed.count,
                workerCount: max(workerCount, 1)
            )
        )
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let manifestURL = runDirectory.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        sessionFinished = true
        progress(PipelineProgress(stage: .complete, completed: 1, total: 1, message: "Complete"))
        completedRun = true

        return PipelineResult(
            sessionID: sessionID,
            imported: imported.map(\.asset),
            analyzed: analyzed,
            grouping: grouping,
            scored: scored,
            shortlist: shortlist,
            exports: exports,
            manifestURL: manifestURL,
            warnings: warnings,
            runDirectory: runDirectory,
            storageSummary: storageSummary,
            metrics: manifest.metrics,
            exportSpecification: exportSpecification
        )
    }

    private func safeFileStem(_ input: String) -> String {
        let allowed = input.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        return String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Absolute path with symlinks resolved, even when the tail does not exist yet.
    /// Uses realpath(3) on the deepest existing ancestor so /tmp and /private/tmp compare equal.
    public static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved: String = existing.path
        if let pointer = realpath(existing.path, nil) {
            resolved = String(cString: pointer)
            free(pointer)
        }
        // Join missing components as plain path text. URL.standardized rewrites
        // an existing /private/var path back to /var and leaves a not-yet-created
        // tail under /private/var, so the two forms would no longer compare equal.
        for component in missing {
            resolved = resolved == "/" ? "/" + component : resolved + "/" + component
        }
        return resolved
    }

    private static func validateOutput(source: URL, output: URL) throws {
        let sourcePath = Self.canonicalPath(source)
        let outputPath = Self.canonicalPath(output)
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        if outputPath == sourcePath || outputPath.hasPrefix(sourcePrefix) {
            throw PhotoEngineError.unsafeOutputDirectory(source: source, output: output)
        }
    }

    /// Written into every run directory at creation. Pruning refuses folders without it.
    public static let runMarkerFileName = ".photocore-run"

    private static func makeRunDirectory(root: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8).lowercased()
        return root.appendingPathComponent("runs", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    private static func checkCancellation(_ shouldCancel: @Sendable () -> Bool) throws {
        if shouldCancel() { throw CancellationError() }
    }
}

private final class ConcurrentAnalysisAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [AnalysisSignals?]
    private var completed = 0
    private var error: Error?

    init(count: Int) {
        results = Array(repeating: nil, count: count)
    }

    var hasError: Bool {
        lock.withLock { error != nil }
    }

    var firstError: Error? {
        lock.withLock { error }
    }

    func result(at index: Int) -> AnalysisSignals? {
        lock.withLock { results[index] }
    }

    func record(
        _ signals: AnalysisSignals,
        at index: Int,
        notify: @Sendable (Int) -> Void
    ) {
        lock.withLock {
            guard results[index] == nil else { return }
            results[index] = signals
            completed += 1
            // Serialize progress delivery with result insertion so concurrent
            // workers cannot publish a lower completed count after a higher one.
            notify(completed)
        }
    }

    func record(error: Error) {
        lock.withLock {
            if self.error == nil { self.error = error }
        }
    }

    func completeResults() throws -> [AnalysisSignals] {
        try lock.withLock {
            if let error { throw error }
            guard results.allSatisfy({ $0 != nil }) else { throw CancellationError() }
            return results.compactMap { $0 }
        }
    }
}

private enum SHA256Hasher {
    static func hash(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func quickSignature(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        hasher.update(data: Data(String(size).utf8))
        if let head = try handle.read(upToCount: 65_536) { hasher.update(data: head) }
        if size > 65_536 {
            try handle.seek(toOffset: max(0, size - 65_536))
            if let tail = try handle.read(upToCount: 65_536) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct SubjectFocusAssessment {
    let sharpness: Double?
    let confidence: Double
    let flags: [String]

    init(image: CGImage, faces: [FaceSignal]) {
        guard !faces.isEmpty else {
            sharpness = nil
            confidence = 0
            flags = []
            return
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let measurements: [(score: Double, area: Double)] = faces.compactMap { face in
            let box = face.boundingBox
            // Background faces in a crowd are a few pixels wide; measuring them just
            // measures upscaling blur. Require a face big enough to judge.
            guard box.width * Double(width) >= 64, box.height * Double(height) >= 64 else { return nil }
            let margin = 0.18
            let x = max(0, box.x - box.width * margin) * width
            let y = max(0, 1 - box.y - box.height * (1 + margin)) * height
            let cropWidth = min(width - x, box.width * (1 + margin * 2) * width)
            let cropHeight = min(height - y, box.height * (1 + margin * 2) * height)
            guard cropWidth >= 8, cropHeight >= 8,
                  let crop = image.cropping(to: CGRect(x: x, y: y, width: cropWidth, height: cropHeight)) else { return nil }
            return (PixelStatistics(image: crop).sharpness, box.width * box.height)
        }

        guard !measurements.isEmpty else {
            sharpness = nil
            confidence = 0.15
            flags = []
            return
        }

        let totalArea = measurements.reduce(0) { $0 + $1.area }
        let weightedAverage = measurements.reduce(0) { $0 + $1.score * $1.area } / max(totalArea, 0.0001)
        let weakest = measurements.map(\.score).min() ?? weightedAverage
        sharpness = weakest * 0.65 + weightedAverage * 0.35
        confidence = min(max(measurements.map(\.area).reduce(0, +) * 2.0, 0.25), 1)

        var computedFlags: [String] = []
        if let sharpness, sharpness < 0.30 {
            computedFlags.append("subject appears soft")
        }
        flags = computedFlags
    }
}

private struct PixelStatistics {
    let brightness: Double
    let exposureQuality: Double
    let sharpness: Double
    let perceptualHash: UInt64

    init(image: CGImage) {
        let sampleWidth = 128
        let sampleHeight = 128
        let pixels = Self.grayscalePixels(image: image, width: sampleWidth, height: sampleHeight)
        guard !pixels.isEmpty else {
            brightness = 0.5
            exposureQuality = 0.5
            sharpness = 0.5
            perceptualHash = 0
            return
        }

        let values = pixels.map { Double($0) / 255.0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let clippedLow = values.filter { $0 < 0.02 }.count
        let clippedHigh = values.filter { $0 > 0.98 }.count
        let clipping = Double(clippedLow + clippedHigh) / Double(values.count)
        let idealBrightness = 1 - min(abs(mean - 0.52) * 2.5, 1)
        let exposureQuality = max(0, idealBrightness * (1 - min(clipping * 2.2, 0.8)))

        // Variance of a Laplacian response is a substantially better blur
        // signal than average adjacent-pixel contrast: broad gradients and
        // exposure changes contribute little, while resolved fine detail does.
        var laplacianEnergy: Double = 0
        var laplacianCount = 0
        for y in 1..<(sampleHeight - 1) {
            for x in 1..<(sampleWidth - 1) {
                let index = y * sampleWidth + x
                let response =
                    4 * values[index] -
                    values[index - 1] - values[index + 1] -
                    values[index - sampleWidth] - values[index + sampleWidth]
                laplacianEnergy += response * response
                laplacianCount += 1
            }
        }
        let laplacianRMS = sqrt(laplacianEnergy / Double(max(laplacianCount, 1)))
        let sharpness = min(max((laplacianRMS - 0.008) / 0.11, 0), 1)

        brightness = mean
        self.exposureQuality = exposureQuality
        self.sharpness = sharpness
        self.perceptualHash = Self.dHash(image: image)
    }

    fileprivate static func grayscalePixels(image: CGImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private static func dHash(image: CGImage) -> UInt64 {
        let pixels = grayscalePixels(image: image, width: 9, height: 8)
        var hash: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 {
                hash <<= 1
                if pixels[row * 9 + column] > pixels[row * 9 + column + 1] {
                    hash |= 1
                }
            }
        }
        return hash
    }
}

/// Fine detail in the sharpest regions of the frame. Unlike the 128-px global
/// measure, this survives busy backgrounds and small in-focus subjects.
/// Raw units (Laplacian variance on 0…255 gray); compare only within a shoot.
fileprivate enum FocusMeasure {
    static func energy(image: CGImage) -> Double? {
        let longEdge = 768.0
        let scale = min(1, longEdge / Double(max(image.width, image.height)))
        let width = max(64, Int(Double(image.width) * scale))
        let height = max(64, Int(Double(image.height) * scale))
        let pixels = PixelStatistics.grayscalePixels(image: image, width: width, height: height)
        guard pixels.count == width * height else { return nil }
        let tiles = 4
        var energies: [Double] = []
        for ty in 0..<tiles {
            for tx in 0..<tiles {
                let x0 = max(1, tx * width / tiles), x1 = min(width - 1, (tx + 1) * width / tiles)
                let y0 = max(1, ty * height / tiles), y1 = min(height - 1, (ty + 1) * height / tiles)
                var sum = 0.0, sumSquares = 0.0, count = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = y * width + x
                        let response = 4 * Double(pixels[i]) - Double(pixels[i - 1]) - Double(pixels[i + 1])
                            - Double(pixels[i - width]) - Double(pixels[i + width])
                        sum += response
                        sumSquares += response * response
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                let mean = sum / count
                energies.append(sumSquares / count - mean * mean)
            }
        }
        let sorted = energies.sorted(by: >)
        // Second-sharpest tile: robust to one tile of noise or specular highlights.
        return sorted.count >= 2 ? sorted[1] : sorted.first
    }
}

private extension CGImagePropertyOrientation {
    init(exifOrientation: Int) {
        switch exifOrientation {
        case 2: self = .upMirrored
        case 3: self = .down
        case 4: self = .downMirrored
        case 5: self = .leftMirrored
        case 6: self = .right
        case 7: self = .rightMirrored
        case 8: self = .left
        default: self = .up
        }
    }
}
