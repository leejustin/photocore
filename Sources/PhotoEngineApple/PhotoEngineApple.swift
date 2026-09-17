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

public final class PhotoFolderImporter: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func importFolder(_ folder: URL, thumbnailMaxPixelSize: Int = 512) throws -> [ImportedPhoto] {
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

        var imported: [ImportedPhoto] = []
        for case let url as URL in enumerator {
            guard Self.isSupportedImage(url) else { continue }
            do {
                let metadata = try ImageMetadataReader.read(url: url)
                let asset = PhotoAsset(
                    url: url,
                    relativePath: Self.relativePath(for: url, root: folder),
                    metadata: metadata,
                    sourceModifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                )
                let thumbnail = try ImageMetadataReader.thumbnailData(url: url, maxPixelSize: thumbnailMaxPixelSize)
                imported.append(ImportedPhoto(asset: asset, thumbnail: thumbnail))
            } catch {
                // A single corrupt file should not abort the complete import.
                continue
            }
        }

        imported.sort {
            let leftDate = $0.asset.metadata.captureDate ?? .distantPast
            let rightDate = $1.asset.metadata.captureDate ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            return $0.asset.relativePath.localizedStandardCompare($1.asset.relativePath) == .orderedAscending
        }

        guard !imported.isEmpty else { throw PhotoEngineError.noPhotos(folder) }
        return imported
    }

    public static func isSupportedImage(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "heic", "heif": true
        default: false
        }
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
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

        var captureDate: Date?
        if let dateString = (exif?.object(forKey: kCGImagePropertyExifDateTimeOriginal) as? String) ?? (tiff?.object(forKey: kCGImagePropertyTIFFDateTime) as? String) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            captureDate = formatter.date(from: dateString)
        }

        let format: PhotoFormat
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": format = .jpeg
        case "heic": format = .heic
        case "heif": format = .heif
        default: format = .unknown
        }

        return PhotoMetadata(
            pixelWidth: width,
            pixelHeight: height,
            orientation: orientation,
            captureDate: captureDate,
            cameraMake: tiff?.object(forKey: kCGImagePropertyTIFFMake) as? String,
            cameraModel: tiff?.object(forKey: kCGImagePropertyTIFFModel) as? String,
            lensModel: exif?.object(forKey: kCGImagePropertyExifLensModel) as? String,
            fileSize: size,
            format: format
        )
    }

    static func thumbnailData(url: URL, maxPixelSize: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoEngineError.unreadableImage(url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoEngineError.unreadableImage(url)
        }
        return try jpegData(image: image, quality: 0.82)
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
}

public struct AppleAnalysisEngine: Sendable {
    public init() {}

    public func analyze(asset: PhotoAsset, thumbnailData: Data? = nil) throws -> AnalysisSignals {
        let thumbnail = try thumbnailData ?? ImageMetadataReader.thumbnailData(url: asset.url, maxPixelSize: 768)
        guard let imageSource = CGImageSourceCreateWithData(thumbnail as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw PhotoEngineError.unreadableImage(asset.url)
        }

        let contentHash = try SHA256Hasher.hash(url: asset.url)
        let pixels = PixelStatistics(image: image)
        let vision = try visionSignals(url: asset.url, orientation: asset.metadata.orientation)
        let fingerprint = PhotoFingerprint(contentHash: contentHash, perceptualHash: pixels.perceptualHash)

        return AnalysisSignals(
            fingerprint: fingerprint,
            brightness: pixels.brightness,
            exposureQuality: pixels.exposureQuality,
            sharpness: pixels.sharpness,
            faceQuality: vision.faceQuality,
            faceCount: vision.faces.count,
            aestheticScore: vision.aestheticScore,
            aestheticUtility: vision.aestheticUtility,
            featureVector: vision.featureVector,
            faces: vision.faces
        )
    }

    private func visionSignals(url: URL, orientation: Int) throws -> (featureVector: [Float]?, faces: [FaceSignal], faceQuality: Double, aestheticScore: Double?, aestheticUtility: Bool?) {
        let featureRequest = VNGenerateImageFeaturePrintRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(url: url, orientation: CGImagePropertyOrientation(exifOrientation: orientation), options: [:])

        var requests: [VNRequest] = [featureRequest, faceRequest]
        var aestheticsRequest: VNCalculateImageAestheticsScoresRequest?
        if #available(macOS 15.0, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            aestheticsRequest = request
            requests.append(request)
        }
        try handler.perform(requests)

        let featureVector: [Float]?
        if let observation = featureRequest.results?.first, observation.elementType == .float {
            let data = observation.data
            let count = observation.elementCount
            featureVector = data.withUnsafeBytes { rawBuffer in
                let values = rawBuffer.bindMemory(to: Float.self)
                guard values.count >= count else { return nil }
                return Array(values.prefix(count))
            }
        } else {
            featureVector = nil
        }

        let observations = faceRequest.results ?? []
        var faceSignals = observations.map {
            FaceSignal(
                boundingBox: CGRectCodable(x: $0.boundingBox.origin.x, y: $0.boundingBox.origin.y, width: $0.boundingBox.size.width, height: $0.boundingBox.size.height),
                captureQuality: nil
            )
        }
        var faceQuality: Double = observations.isEmpty ? 0.5 : 0
        if !observations.isEmpty {
            // The legacy VN request returns face observations without the newer
            // capture-quality payload on this SDK. Use a conservative geometric
            // quality proxy here; the newer Swift Vision request can replace it
            // without changing the domain contract.
            let averageArea = observations.map { Double($0.boundingBox.width * $0.boundingBox.height) }.reduce(0, +) / Double(observations.count)
            faceQuality = min(max(averageArea * 3.0, 0.35), 0.85)
            for index in faceSignals.indices {
                faceSignals[index].captureQuality = faceQuality
            }
        }

        let aestheticScore = aestheticsRequest?.results?.first.map {
            min(max((Double($0.overallScore) + 1.0) / 2.0, 0), 1)
        }
        let aestheticUtility = aestheticsRequest?.results?.first?.isUtility
        return (featureVector, faceSignals, min(max(faceQuality, 0), 1), aestheticScore, aestheticUtility)
    }

}

public final class ApplePhotoRenderer: @unchecked Sendable {
    private let context: CIContext

    public init() {
        context = CIContext(options: [CIContextOption.cacheIntermediates: false])
    }

    public func render(photo: AnalyzedPhoto, outputURL: URL) throws -> ExportedPhoto {
        let recipe = Self.recipe(for: photo)
        guard let input = CIImage(contentsOf: photo.asset.url, options: [.applyOrientationProperty: true]) else {
            throw PhotoEngineError.exportFailed(photo.asset.url, "Could not create Core Image input")
        }

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
        if abs(recipe.highlights) > 0.01 || abs(recipe.shadows) > 0.01 {
            let filter = CIFilter(name: "CIHighlightShadowAdjust")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(recipe.shadows, forKey: "inputShadowAmount")
            filter.setValue(recipe.highlights, forKey: "inputHighlightAmount")
            image = filter.outputImage ?? image
        }
        if abs(recipe.sharpening) > 0.01 {
            let filter = CIFilter(name: "CISharpenLuminance")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(recipe.sharpening, forKey: "inputSharpness")
            image = filter.outputImage ?? image
        }

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let outputImage = context.createCGImage(image, from: image.extent) else {
            throw PhotoEngineError.exportFailed(photo.asset.url, "Could not render edited image")
        }
        let data = try ImageMetadataReader.jpegData(image: outputImage, quality: 0.92)
        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw PhotoEngineError.exportFailed(outputURL, error.localizedDescription)
        }

        return ExportedPhoto(photoID: photo.id, sourcePath: photo.asset.url.path, outputPath: outputURL.path, recipe: recipe)
    }

    public static func recipe(for photo: AnalyzedPhoto) -> EditRecipe {
        let brightnessDelta = 0.5 - photo.signals.brightness
        let exposure = min(max(brightnessDelta * 1.2, -0.45), 0.45)
        let highlights = photo.signals.exposureQuality < 0.45 ? -0.10 : 0
        let shadows = photo.signals.brightness < 0.38 ? 0.14 : 0
        let saturation = photo.signals.aestheticScore.map { $0 < 0.48 ? 0.04 : 0.015 } ?? 0.02
        let contrast = photo.signals.exposureQuality > 0.60 ? 0.025 : 0
        let sharpening = photo.signals.sharpness < 0.55 ? 0.16 : 0.08
        return EditRecipe(exposure: exposure, contrast: contrast, saturation: saturation, highlights: highlights, shadows: shadows, sharpening: sharpening)
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
    public let imported: [ImportedPhoto]
    public let analyzed: [AnalyzedPhoto]
    public let grouping: PhotoGrouping
    public let scored: [ScoredPhoto]
    public let shortlist: Shortlist
    public let exports: [ExportedPhoto]
    public let manifestURL: URL

    public init(imported: [ImportedPhoto], analyzed: [AnalyzedPhoto], grouping: PhotoGrouping, scored: [ScoredPhoto], shortlist: Shortlist, exports: [ExportedPhoto], manifestURL: URL) {
        self.imported = imported
        self.analyzed = analyzed
        self.grouping = grouping
        self.scored = scored
        self.shortlist = shortlist
        self.exports = exports
        self.manifestURL = manifestURL
    }
}

public final class PhotoPipelineRunner: @unchecked Sendable {
    private let importer: PhotoFolderImporter
    private let analyzer: AppleAnalysisEngine
    private let renderer: ApplePhotoRenderer

    public init(importer: PhotoFolderImporter = PhotoFolderImporter(), analyzer: AppleAnalysisEngine = AppleAnalysisEngine(), renderer: ApplePhotoRenderer = ApplePhotoRenderer()) {
        self.importer = importer
        self.analyzer = analyzer
        self.renderer = renderer
    }

    public func run(
        folder: URL,
        outputDirectory: URL,
        profile: ScoringProfile,
        progress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }
    ) throws -> PipelineResult {
        progress(PipelineProgress(stage: .discovering, completed: 0, total: 1, message: "Discovering photos"))
        let imported = try importer.importFolder(folder)
        progress(PipelineProgress(stage: .discovering, completed: 1, total: 1, message: "Found \(imported.count) photos"))

        let cache = AnalysisCache(sourceFolder: folder)
        var analyzed: [AnalyzedPhoto] = []
        analyzed.reserveCapacity(imported.count)
        for (index, item) in imported.enumerated() {
            let cached = cache.signals(for: item.asset)
            let signals = try cached ?? analyzer.analyze(asset: item.asset, thumbnailData: item.thumbnail)
            if cached == nil {
                cache.update(asset: item.asset, signals: signals)
            }
            analyzed.append(AnalyzedPhoto(asset: item.asset, signals: signals))
            let suffix = cached == nil ? "" : " (cached)"
            progress(PipelineProgress(stage: .analyzing, completed: index + 1, total: imported.count, message: item.asset.relativePath + suffix))
        }
        try cache.save()

        progress(PipelineProgress(stage: .grouping, completed: 0, total: 1, message: "Grouping duplicates and bursts"))
        let grouping = PhotoGroupingEngine.group(analyzed, profile: profile)
        progress(PipelineProgress(stage: .grouping, completed: 1, total: 1, message: "Found \(grouping.groups.count) groups"))

        let scored = analyzed.map { ScoredPhoto(photo: $0, score: PhotoScoring.score($0, profile: profile)) }
        progress(PipelineProgress(stage: .selecting, completed: 0, total: 1, message: "Building shortlist"))
        let shortlist = PhotoSelectionEngine.select(scored, grouping: grouping, profile: profile)
        progress(PipelineProgress(stage: .selecting, completed: 1, total: 1, message: "Selected \(shortlist.selectedIDs.count) photos"))

        let exportDirectory = outputDirectory.appendingPathComponent("shortlist", isDirectory: true)
        var exports: [ExportedPhoto] = []
        for (index, photoID) in shortlist.selectedIDs.enumerated() {
            guard let analyzedPhoto = analyzed.first(where: { $0.id == photoID }) else { continue }
            let fileName = String(format: "%03d-%@.jpg", index + 1, safeFileStem(analyzedPhoto.asset.url.deletingPathExtension().lastPathComponent))
            let outputURL = exportDirectory.appendingPathComponent(fileName)
            let exported = try renderer.render(photo: analyzedPhoto, outputURL: outputURL)
            exports.append(exported)
            progress(PipelineProgress(stage: .exporting, completed: index + 1, total: shortlist.selectedIDs.count, message: fileName))
        }

        let manifest = PipelineManifest(
            sourceFolder: folder.path,
            mode: profile.mode,
            assets: imported.map(\.asset),
            analyzed: analyzed,
            grouping: grouping,
            shortlist: shortlist,
            exports: exports
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        progress(PipelineProgress(stage: .complete, completed: 1, total: 1, message: "Complete"))

        return PipelineResult(imported: imported, analyzed: analyzed, grouping: grouping, scored: scored, shortlist: shortlist, exports: exports, manifestURL: manifestURL)
    }

    private func safeFileStem(_ input: String) -> String {
        let allowed = input.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        return String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
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
}

private struct PixelStatistics {
    let brightness: Double
    let exposureQuality: Double
    let sharpness: Double
    let perceptualHash: UInt64

    init(image: CGImage) {
        let pixels = Self.grayscalePixels(image: image, width: 72, height: 72)
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

        var edgeDifference: Double = 0
        var edgeCount = 0
        for y in 0..<71 {
            for x in 0..<71 {
                let index = y * 72 + x
                edgeDifference += abs(values[index] - values[index + 1])
                edgeDifference += abs(values[index] - values[index + 72])
                edgeCount += 2
            }
        }
        let averageEdge = edgeDifference / Double(max(edgeCount, 1))
        let sharpness = min(max((averageEdge - 0.015) / 0.16, 0), 1)

        brightness = mean
        self.exposureQuality = exposureQuality
        self.sharpness = sharpness
        self.perceptualHash = Self.dHash(image: image)
    }

    private static func grayscalePixels(image: CGImage, width: Int, height: Int) -> [UInt8] {
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
