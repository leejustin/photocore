import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PhotoEngineApple
import PhotoEngineCore
import UniformTypeIdentifiers

/// One photo in a trip, described without its pixels.
public struct TripPhotoItem: Sendable, Equatable {
    public var identifier: String
    public var creationDate: Date?
    public var modificationDate: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(identifier: String, creationDate: Date?, modificationDate: Date?, latitude: Double? = nil, longitude: Double? = nil, pixelWidth: Int, pixelHeight: Int) {
        self.identifier = identifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.latitude = latitude
        self.longitude = longitude
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Where a streamed cull gets photos from: Photos on the phone, a folder in tests.
public protocol TripPhotoSource: Sendable {
    var items: [TripPhotoItem] { get }
    /// An upright thumbnail about `maxPixel` on its long edge, held only in memory.
    func thumbnail(for item: TripPhotoItem, maxPixel: Int) async -> CGImage?
}

/// The only thing a streamed cull keeps on disk: about 5 KB of analysis per
/// photo, keyed by the Photos identifier and invalidated when the photo is edited.
public struct TripSignalStore: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var modificationDate: Date?
        public var signals: AnalysisSignals?
        public var utility: UtilityShotKind
    }

    public static let fileName = "signals.plist"
    public var schemaVersion = 1
    public var entries: [String: Entry] = [:]

    public init() {}

    public static func load(from folder: URL) -> TripSignalStore {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let store = try? PropertyListDecoder().decode(TripSignalStore.self, from: data),
              store.schemaVersion == 1 else { return TripSignalStore() }
        return store
    }

    public func save(to folder: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public func current(_ item: TripPhotoItem) -> Entry? {
        guard let entry = entries[item.identifier], entry.modificationDate == item.modificationDate else { return nil }
        return entry
    }
}

/// Conditions that should stop or slow a cull on a phone.
public struct DeviceConditions: Sendable, Equatable {
    public var freeBytes: Int64?
    public var thermal: ProcessInfo.ThermalState
    public var lowPower: Bool

    public init(freeBytes: Int64?, thermal: ProcessInfo.ThermalState, lowPower: Bool) {
        self.freeBytes = freeBytes
        self.thermal = thermal
        self.lowPower = lowPower
    }

    public static func current(volume: URL = FileManager.default.temporaryDirectory) -> DeviceConditions {
        let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return DeviceConditions(
            freeBytes: values?.volumeAvailableCapacityForImportantUsage,
            thermal: ProcessInfo.processInfo.thermalState,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
}

public enum CullGuard {
    /// Enough for the analysis store, one batch of in-memory thumbnails and
    /// SQLite headroom. Deliberately small: people cull because they are out of space.
    public static let minimumFreeBytes: Int64 = 200 * 1_024 * 1_024

    public enum Verdict: Equatable, Sendable {
        case go(batchSize: Int)
        case pause(reason: String)
        case refuse(reason: String)
    }

    public static func check(_ conditions: DeviceConditions, normalBatch: Int = 48) -> Verdict {
        if let free = conditions.freeBytes, free < minimumFreeBytes {
            return .refuse(reason: "Your iPhone needs about 200 MB free to cull. Free a little space and try again.")
        }
        switch conditions.thermal {
        case .serious, .critical:
            return .pause(reason: "Your iPhone is warm. Culling resumes when it cools down.")
        default:
            break
        }
        return .go(batchSize: conditions.lowPower ? max(normalBatch / 4, 8) : normalBatch)
    }
}

public enum StreamedCullStage: Sendable, Equatable {
    case analyzing(done: Int, total: Int)
    case paused(String)
    case deciding
}

public struct StreamedCullResult: Sendable {
    public var result: PipelineResult
    public var identifiers: [PhotoID: String]
    public var utilityCount: Int

    public func identifier(for id: PhotoID) -> String? { identifiers[id] }
    public func identifiers(for ids: some Sequence<PhotoID>) -> [String] { ids.compactMap { identifiers[$0] } }
}

public enum StreamedCullError: LocalizedError, Equatable {
    case notEnoughSpace(String)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let reason): reason
        }
    }
}

/// Culls a trip without copying it. Thumbnails are requested in small batches,
/// analyzed in memory and dropped; only the analysis is saved, after every batch,
/// so a killed app resumes where it stopped. Selection is the same shared
/// decision the Mac runner uses.
public struct StreamedCuller: Sendable {
    public var analyzer = AppleAnalysisEngine()
    public var conditions: @Sendable () -> DeviceConditions = { DeviceConditions.current() }
    public var pauseInterval: Duration = .seconds(20)

    public init() {}

    public func cull(
        source: some TripPhotoSource,
        storeFolder: URL,
        profile: ScoringProfile,
        progress: @escaping @Sendable (StreamedCullStage) -> Void = { _ in }
    ) async throws -> StreamedCullResult {
        try FileManager.default.createDirectory(at: storeFolder, withIntermediateDirectories: true)
        if case .refuse(let reason) = CullGuard.check(conditions()) {
            throw StreamedCullError.notEnoughSpace(reason)
        }
        var store = TripSignalStore.load(from: storeFolder)
        let items = source.items
        var position = 0
        progress(.analyzing(done: 0, total: items.count))
        while position < items.count {
            try Task.checkCancellation()
            let batchSize: Int
            switch CullGuard.check(conditions()) {
            case .refuse(let reason):
                throw StreamedCullError.notEnoughSpace(reason)
            case .pause(let reason):
                progress(.paused(reason))
                try await Task.sleep(for: pauseInterval)
                continue
            case .go(let size):
                batchSize = size
            }
            let batch = items[position..<min(position + batchSize, items.count)]
            for item in batch where store.current(item) == nil {
                try Task.checkCancellation()
                guard let image = await source.thumbnail(for: item, maxPixel: AppleAnalysisEngine.analysisPixelSize) else { continue }
                let entry = try analyze(item: item, image: image)
                store.entries[item.identifier] = entry
            }
            position += batch.count
            try store.save(to: storeFolder)
            progress(.analyzing(done: position, total: items.count))
        }

        progress(.deciding)
        var identifiers: [PhotoID: String] = [:]
        var raw: [AnalyzedPhoto] = []
        var utility = 0
        for item in items {
            guard let entry = store.current(item) else { continue }
            if entry.utility != .none { utility += 1; continue }
            guard let signals = entry.signals else { continue }
            let asset = Self.asset(for: item)
            identifiers[asset.id] = item.identifier
            raw.append(AnalyzedPhoto(asset: asset, signals: signals))
        }
        let decision = PhotoPipelineRunner.decide(rawAnalyzed: raw, profile: profile)
        let result = PipelineResult(
            sessionID: SessionID(),
            imported: decision.analyzed.map(\.asset),
            analyzed: decision.analyzed,
            grouping: decision.grouping,
            scored: decision.scored,
            shortlist: decision.shortlist,
            exports: [],
            manifestURL: storeFolder.appendingPathComponent("manifest.json"),
            warnings: [],
            runDirectory: storeFolder,
            storageSummary: nil
        )
        return StreamedCullResult(result: result, identifiers: identifiers, utilityCount: utility)
    }

    private func analyze(item: TripPhotoItem, image: CGImage) throws -> TripSignalStore.Entry {
        let utility = UtilityShotDetector.classify(image)
        guard utility == .none else {
            return TripSignalStore.Entry(modificationDate: item.modificationDate, signals: nil, utility: utility)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let signals = try analyzer.analyze(asset: Self.asset(for: item), thumbnailData: data as Data)
        return TripSignalStore.Entry(modificationDate: item.modificationDate, signals: signals, utility: .none)
    }

    /// A file-less asset for a Photos item. The id and content hash are derived
    /// from the identifier and edit date, so they are stable across launches.
    public static func asset(for item: TripPhotoItem) -> PhotoAsset {
        let key = item.identifier + "|" + String(item.modificationDate?.timeIntervalSince1970 ?? 0)
        let digest = Array(SHA256.hash(data: Data(key.utf8)))
        let uuid = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                               digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        return PhotoAsset(
            id: PhotoID(uuid),
            url: URL(fileURLWithPath: "/photos-library/" + LibraryExportIndex.fileName(for: item.identifier)),
            relativePath: LibraryExportIndex.fileName(for: item.identifier),
            metadata: PhotoMetadata(
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight,
                captureDate: item.creationDate,
                format: .heic,
                latitude: item.latitude,
                longitude: item.longitude
            ),
            sourceModifiedAt: item.modificationDate,
            contentHash: digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        )
    }
}
