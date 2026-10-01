import CoreGraphics
import Foundation
import PhotoEngineApple
import PhotoEngineCore

/// Everything the trip book and the diary writer may say about one keeper. The
/// writer is only allowed to use these facts, which keeps captions grounded.
public struct PhotoFacts: Codable, Sendable, Equatable, Identifiable {
    public var id: PhotoID
    public var fileName: String
    public var captureDate: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var place: PlaceName?
    public var labels: [SceneLabel]
    public var faceCount: Int
    public var crops: [String: NormalizedCrop]
    public var pixelWidth: Int
    public var pixelHeight: Int

    public var isPortraitOrientation: Bool { pixelHeight > pixelWidth }
}

public struct TripFacts: Codable, Sendable, Equatable {
    public static let fileName = "trip-facts.json"
    public var schemaVersion = 1
    public var photos: [PhotoFacts]

    public init(photos: [PhotoFacts]) {
        self.photos = photos
    }

    public func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func load(from folder: URL) throws -> TripFacts {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TripFacts.self, from: Data(contentsOf: folder.appendingPathComponent(fileName)))
    }

    /// Distinct places in visiting order.
    public var places: [PlaceName] {
        var seen = Set<String>()
        return photos.compactMap(\.place).filter { seen.insert($0.display).inserted }
    }
}

public enum TripFactsBuilder {
    /// Labels, crops and place names for the keepers only, in capture order.
    /// Place names need a network lookup; pass `lookUpPlaces: false` offline.
    public static func build(
        keepers: [AnalyzedPhoto],
        lookUpPlaces: Bool = true,
        namer: PlaceNamer = .shared,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> TripFacts {
        let ordered = keepers.sorted { ($0.asset.metadata.captureDate ?? .distantPast) < ($1.asset.metadata.captureDate ?? .distantPast) }
        var photos: [PhotoFacts] = []
        for (index, photo) in ordered.enumerated() {
            let image = CGImage.photocoreThumbnail(url: photo.asset.url, maxPixel: 1024)
            let labels = image.map { SceneLabeler.labels(for: $0) } ?? []
            let crops = image.map { SaliencyCropper.crops(for: $0) } ?? [:]
            let metadata = photo.asset.metadata
            let upright = metadata.orientation >= 5
            photos.append(PhotoFacts(
                id: photo.id,
                fileName: URL(fileURLWithPath: photo.asset.relativePath).lastPathComponent,
                captureDate: metadata.captureDate,
                latitude: metadata.latitude,
                longitude: metadata.longitude,
                place: nil,
                labels: labels,
                faceCount: photo.signals.faceCount,
                crops: Dictionary(uniqueKeysWithValues: crops.map { ($0.key.rawValue, $0.value) }),
                pixelWidth: upright ? metadata.pixelHeight : metadata.pixelWidth,
                pixelHeight: upright ? metadata.pixelWidth : metadata.pixelHeight
            ))
            progress(index + 1, ordered.count)
        }
        guard lookUpPlaces else { return TripFacts(photos: photos) }
        let coordinates = photos.compactMap { photo -> (latitude: Double, longitude: Double)? in
            guard let lat = photo.latitude, let lon = photo.longitude else { return nil }
            return (lat, lon)
        }
        let names = await namer.names(for: coordinates)
        for index in photos.indices {
            guard let lat = photos[index].latitude, let lon = photos[index].longitude else { continue }
            photos[index].place = names[PlaceNamer.cellKey(latitude: lat, longitude: lon)]
        }
        return TripFacts(photos: photos)
    }
}
