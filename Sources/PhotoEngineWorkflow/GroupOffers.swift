import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PhotoEngineApple
import PhotoEngineCore

/// Analysis first, originals second: how a friend's iPhone joins a group book
/// without sending photos that won't be used.
///
/// 1. The phone culls the friend's picks with the same engine as the app.
/// 2. It sends an offer for each of its best: a name, the capture time, the
///    cull's score and the Vision feature print (about 2 KB).
/// 3. The server runs `GroupCuration` over the owner's photos and everyone's
///    offers, and answers with the names it wants.
/// 4. The phone uploads only those originals. The rest never leave it.
///
/// Feature prints from the same Vision revision compare across devices, so the
/// thresholds measured on the Mac hold (see the README calibration).
public struct PhotoOffer: Codable, Sendable, Equatable {
    /// The name the original will be uploaded under.
    public var name: String
    public var captured: Date?
    /// The phone's cull score; higher is better.
    public var score: Double
    /// A JSON-encoded revision-2 Vision feature print.
    public var featurePrint: Data?

    public init(name: String, captured: Date?, score: Double, featurePrint: Data?) {
        self.name = name
        self.captured = captured
        self.score = score
        self.featurePrint = featurePrint
    }
}

/// Photos chosen in a picker and copied to a folder, for the streamed culler.
public struct FilePhotoSource: TripPhotoSource {
    public let items: [TripPhotoItem]
    private let urls: [String: URL]

    public init(files: [URL]) {
        var items: [TripPhotoItem] = []
        var urls: [String: URL] = [:]
        for url in files {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { continue }
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let date = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(Self.exifDate)
            let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            var latitude = gps?[kCGImagePropertyGPSLatitude] as? Double
            var longitude = gps?[kCGImagePropertyGPSLongitude] as? Double
            if gps?[kCGImagePropertyGPSLatitudeRef] as? String == "S" { latitude = latitude.map { -$0 } }
            if gps?[kCGImagePropertyGPSLongitudeRef] as? String == "W" { longitude = longitude.map { -$0 } }
            let identifier = url.lastPathComponent
            items.append(TripPhotoItem(identifier: identifier, creationDate: date, modificationDate: nil, latitude: latitude, longitude: longitude, pixelWidth: width, pixelHeight: height))
            urls[identifier] = url
        }
        self.items = items
        self.urls = urls
    }

    public func thumbnail(for item: TripPhotoItem, maxPixel: Int) async -> CGImage? {
        guard let url = urls[item.identifier], let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary)
    }

    public func url(for identifier: String) -> URL? { urls[identifier] }

    /// EXIF wall-clock time ("2026:10:03 10:00:01"), read as UTC so times
    /// compare with each other; only differences matter for moments.
    static func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

public enum GroupOffers {
    /// The share of a friend's picks they offer: the same as the server's cull
    /// of a friend's uploads.
    public static let keepPercent: Double = 30

    /// Culls a friend's picks on their phone and returns offers for their best.
    public static func offers(source: FilePhotoSource, storeFolder: URL, progress: @escaping @Sendable (StreamedCullStage) -> Void = { _ in }) async throws -> [PhotoOffer] {
        var profile = ScoringProfile.default(for: .trip)
        profile.sizingMode = .percentage
        profile.keepPercentage = keepPercent
        let cull = try await StreamedCuller().cull(source: source, storeFolder: storeFolder, profile: profile, progress: progress)
        let scores = Dictionary(cull.result.shortlist.decisions.map { ($0.photoID, $0.score) }, uniquingKeysWith: max)
        let picked = KeeperSelection(result: cull.result).ordered(in: cull.result)
        // Very small sets keep everything: there's nothing to compare.
        let chosen = source.items.count < 4 ? cull.result.analyzed : picked
        return chosen.compactMap { photo in
            guard let identifier = cull.identifier(for: photo.id) else { return nil }
            return PhotoOffer(name: offerName(identifier), captured: photo.asset.metadata.captureDate, score: scores[photo.id] ?? 0, featurePrint: photo.signals.featurePrint)
        }
    }

    /// The name a file is offered and uploaded under: its name without the
    /// extension, letters, digits, "-" and "_" only. Name picked files so these
    /// are unique (the App Clip uses p0001, p0002, ...).
    public static func offerName(_ fileName: String) -> String {
        String((fileName as NSString).deletingPathExtension.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(48))
    }

    /// One candidate for the server's decision.
    public struct Candidate: Sendable {
        public var person: String
        public var offer: PhotoOffer

        public init(person: String, offer: PhotoOffer) {
            self.person = person
            self.offer = offer
        }

        var key: String { person + "\u{1F}" + offer.name }
    }

    /// Which offers the book wants: the owner's photos always stay, and among
    /// everyone else's offers the best shot of each moment wins, shared out
    /// in turns. Returns "person, name" pairs.
    public static func wanted(owner: [PhotoOffer], offers: [Candidate], budget: Int? = nil) -> Set<[String]> {
        func id(_ key: String) -> PhotoID {
            let digest = Array(SHA256.hash(data: Data(key.utf8)))
            return PhotoID(UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                                       digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15])))
        }
        var prints: [PhotoID: Data] = [:]
        var keys: [PhotoID: Candidate] = [:]
        let ownerCandidates = owner.map { offer -> GroupCuration.Candidate in
            let pid = id("owner\u{1F}" + offer.name)
            prints[pid] = offer.featurePrint
            return GroupCuration.Candidate(id: pid, contributor: nil, score: .infinity, captureDate: offer.captured)
        }
        let others = offers.map { candidate -> GroupCuration.Candidate in
            let pid = id(candidate.key)
            prints[pid] = candidate.offer.featurePrint
            keys[pid] = candidate
            return GroupCuration.Candidate(id: pid, contributor: candidate.person, score: candidate.offer.score, captureDate: candidate.offer.captured)
        }
        let outcome = GroupCuration.curate(owner: ownerCandidates, contributors: others, distance: { a, b in
            guard let x = prints[a], let y = prints[b] else { return nil }
            return AppleVisualDistance.distance(x, y)
        }, budget: budget)
        return Set(outcome.kept.compactMap { keys[$0].map { [$0.person, $0.offer.name] } })
    }
}
