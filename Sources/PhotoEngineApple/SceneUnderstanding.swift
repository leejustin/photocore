import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import Vision

/// One scene label from Vision's image classifier, such as "beach" or "food".
public struct SceneLabel: Codable, Sendable, Equatable, Hashable {
    public var identifier: String
    public var confidence: Double

    public init(identifier: String, confidence: Double) {
        self.identifier = identifier
        self.confidence = confidence
    }

    /// "outdoor_scene" reads as "outdoor scene" in a caption prompt or a header.
    /// A few classifier names read oddly in a caption and are renamed.
    public var readable: String {
        if let renamed = Self.renamed[identifier] { return renamed }
        return identifier.replacingOccurrences(of: "_", with: " ")
    }

    static let renamed: [String: String] = [
        "portal": "doorway", "optical_equipment": "glasses", "conveyance": "vehicle", "water_body": "water",
        "wood_processed": "wood", "sunset_sunrise": "sunset", "foodstuff": "food", "dragon_parade": "dragon parade"
    ]

    /// Confident enough to name in a caption.
    public var isConfident: Bool { confidence >= 0.45 }
}

/// What a photo is of. Runs only on keepers, so its cost does not grow with the roll.
public enum SceneLabeler {
    /// Labels too generic to say anything about a trip.
    static let ignored: Set<String> = [
        "structure", "material", "textile", "document", "people", "adult", "consumer_electronics",
        // Too vague to say anything in a caption ("outdoor and cloudy").
        "outdoor", "indoor", "sky", "cloudy", "liquid", "water_body", "conveyance", "optical_equipment", "land", "wood_processed"
    ]

    public static func labels(for image: CGImage, limit: Int = 5, minimumConfidence: Double = 0.25) -> [SceneLabel] {
        let request = VNClassifyImageRequest()
        VisionCompute.prepare([request])
        VisionCompute.gate.wait()
        defer { VisionCompute.gate.signal() }
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let observations = request.results else { return [] }
        return observations
            .filter { Double($0.confidence) >= minimumConfidence && !ignored.contains($0.identifier) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)
            .map { SceneLabel(identifier: $0.identifier, confidence: Double($0.confidence)) }
    }
}

/// A crop in normalized image coordinates, origin top-left, 0...1 on both axes.
public struct NormalizedCrop: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedCrop(x: 0, y: 0, width: 1, height: 1)

    public func pixelRect(width imageWidth: Int, height imageHeight: Int) -> CGRect {
        CGRect(x: x * Double(imageWidth), y: y * Double(imageHeight), width: width * Double(imageWidth), height: height * Double(imageHeight)).integral
    }
}

/// Social crop shapes the Instagram pack needs.
public enum CropAspect: String, Codable, Sendable, CaseIterable {
    case portrait = "4:5"
    case story = "9:16"
    case square = "1:1"

    public var ratio: Double {
        switch self {
        case .portrait: 4.0 / 5.0
        case .story: 9.0 / 16.0
        case .square: 1
        }
    }
}

/// Places a crop of a target shape over the part of the frame people look at.
public enum SaliencyCropper {
    /// The attention-salient region, top-left normalized, or nil when Vision finds none.
    public static func salientRegion(in image: CGImage) -> NormalizedCrop? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        VisionCompute.prepare([request])
        VisionCompute.gate.wait()
        defer { VisionCompute.gate.signal() }
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let objects = request.results?.first?.salientObjects, !objects.isEmpty else { return nil }
        let union = objects.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        // Vision boxes are bottom-left origin.
        return NormalizedCrop(x: union.minX, y: 1 - union.maxY, width: union.width, height: union.height)
    }

    /// The largest crop of `aspect` that fits the image, centered on the salient
    /// region and clamped to the frame. Pure, so it is testable without Vision.
    public static func crop(imageWidth: Int, imageHeight: Int, aspect: Double, focus: NormalizedCrop?) -> NormalizedCrop {
        let width = Double(max(imageWidth, 1)), height = Double(max(imageHeight, 1))
        var cropW = width, cropH = width / aspect
        if cropH > height {
            cropH = height
            cropW = height * aspect
        }
        let focus = focus ?? .full
        let centerX = (focus.x + focus.width / 2) * width
        // Bias slightly upward: faces and horizons sit in the upper part of a subject box.
        let centerY = (focus.y + focus.height * 0.45) * height
        let originX = min(max(centerX - cropW / 2, 0), width - cropW)
        let originY = min(max(centerY - cropH / 2, 0), height - cropH)
        return NormalizedCrop(x: originX / width, y: originY / height, width: cropW / width, height: cropH / height)
    }

    public static func crops(for image: CGImage, aspects: [CropAspect] = CropAspect.allCases) -> [CropAspect: NormalizedCrop] {
        let focus = salientRegion(in: image)
        var result: [CropAspect: NormalizedCrop] = [:]
        for aspect in aspects {
            result[aspect] = crop(imageWidth: image.width, imageHeight: image.height, aspect: aspect.ratio, focus: focus)
        }
        return result
    }
}

/// A named place for a cluster of photos: "Alfama, Lisbon".
public struct PlaceName: Codable, Sendable, Equatable {
    public var name: String
    public var locality: String?
    public var country: String?
    /// The place's time zone, used for local time when a photo has no offset.
    public var timeZoneIdentifier: String?

    public init(name: String, locality: String? = nil, country: String? = nil, timeZoneIdentifier: String? = nil) {
        self.name = name
        self.locality = locality
        self.country = country
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// The short form used in section headers.
    public var display: String {
        if let locality, locality != name { return "\(name), \(locality)" }
        return name
    }
}

/// Turns photo coordinates into place names with as few lookups as possible.
/// Coordinates are snapped to a grid (about 1 km), each cell is looked up once,
/// and results are cached on disk so a trip never asks twice.
public actor PlaceNamer {
    public static let shared = PlaceNamer()

    private var cache: [String: PlaceName]
    private let cacheURL: URL

    public init(cacheURL: URL? = nil) {
        let url = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photocore/places-v1.json")
        self.cacheURL = url
        self.cache = (try? JSONDecoder().decode([String: PlaceName].self, from: Data(contentsOf: url))) ?? [:]
    }

    /// Grid key for a coordinate, about 1.1 km of latitude per step.
    public static func cellKey(latitude: Double, longitude: Double, step: Double = 0.01) -> String {
        let lat = (latitude / step).rounded() * step
        let lon = (longitude / step).rounded() * step
        return String(format: "%.2f,%.2f", lat, lon)
    }

    public func cached(latitude: Double, longitude: Double) -> PlaceName? {
        cache[Self.cellKey(latitude: latitude, longitude: longitude)]
    }

    public func store(_ place: PlaceName, latitude: Double, longitude: Double) {
        cache[Self.cellKey(latitude: latitude, longitude: longitude)] = place
        persist()
    }

    /// Looks up each distinct cell once. Cells that fail stay unnamed; the book
    /// falls back to dates for those sections.
    public func names(for coordinates: [(latitude: Double, longitude: Double)]) async -> [String: PlaceName] {
        var cells: [String: (Double, Double)] = [:]
        for coordinate in coordinates {
            cells[Self.cellKey(latitude: coordinate.latitude, longitude: coordinate.longitude)] = (coordinate.latitude, coordinate.longitude)
        }
        var result: [String: PlaceName] = [:]
        for (key, coordinate) in cells.sorted(by: { $0.key < $1.key }) {
            if let hit = cache[key] {
                result[key] = hit
                continue
            }
            guard let place = await Self.reverseGeocode(latitude: coordinate.0, longitude: coordinate.1) else { continue }
            cache[key] = place
            result[key] = place
        }
        persist()
        return result
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
    }

    private static func reverseGeocode(latitude: Double, longitude: Double) async -> PlaceName? {
        let geocoder = CLGeocoder()
        guard let placemark = try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)).first else {
            return nil
        }
        var found = place(
            areasOfInterest: placemark.areasOfInterest ?? [],
            subLocality: placemark.subLocality,
            locality: placemark.locality,
            administrativeArea: placemark.administrativeArea,
            country: placemark.country
        )
        found?.timeZoneIdentifier = placemark.timeZone?.identifier
        return found
    }

    /// Picks the most specific readable name: a landmark, then a neighborhood,
    /// then a town. Pure, so it is testable without a network.
    public static func place(areasOfInterest: [String], subLocality: String?, locality: String?, administrativeArea: String?, country: String?) -> PlaceName? {
        let name = areasOfInterest.first ?? subLocality ?? locality ?? administrativeArea ?? country
        guard let name, !name.isEmpty else { return nil }
        return PlaceName(name: name, locality: locality ?? administrativeArea, country: country)
    }
}

public extension CGImage {
    /// Loads an upright, downsampled image for the keeper-only Vision passes.
    static func photocoreThumbnail(url: URL, maxPixel: Int = 1024) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary)
    }
}
