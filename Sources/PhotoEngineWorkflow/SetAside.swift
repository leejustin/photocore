import Foundation
import Photos
import PhotoEngineCore

/// What Photocore knows about a library photo before it may set it aside.
public struct LibraryProtection: Sendable, Equatable {
    public var isFavorite: Bool
    public var isEdited: Bool
    public var isInOtherAlbum: Bool
    public var isShared: Bool

    public init(isFavorite: Bool = false, isEdited: Bool = false, isInOtherAlbum: Bool = false, isShared: Bool = false) {
        self.isFavorite = isFavorite
        self.isEdited = isEdited
        self.isInOtherAlbum = isInOtherAlbum
        self.isShared = isShared
    }

    /// Photos the person has already signalled they care about are never set aside.
    public var reason: String? {
        if isFavorite { return "favorite" }
        if isEdited { return "edited" }
        if isInOtherAlbum { return "in an album" }
        if isShared { return "shared" }
        return nil
    }
}

public struct SetAsidePlan: Sendable, Equatable {
    public var eligible: [String]
    public var protected: [String: String]
}

/// Decides which non-keepers may be set aside. Deletion is never part of a cull:
/// setting aside only gathers photos in an album, which one tap undoes. Deleting
/// is a separate, capped step that goes through the system's own confirmation
/// into Recently Deleted.
public enum SetAsidePlanner {
    /// Largest number of photos one delete request may include.
    public static let deleteBatchLimit = 500

    public static func plan(candidates: [String], keepers: Set<String>, protection: [String: LibraryProtection]) -> SetAsidePlan {
        var eligible: [String] = []
        var protected: [String: String] = [:]
        for identifier in candidates where !keepers.contains(identifier) {
            if let reason = protection[identifier]?.reason {
                protected[identifier] = reason
            } else {
                eligible.append(identifier)
            }
        }
        return SetAsidePlan(eligible: eligible, protected: protected)
    }

    /// Splits a delete into batches no larger than the limit; the first batch is
    /// what one tap may delete.
    public static func deleteBatches(_ identifiers: [String], limit: Int = deleteBatchLimit) -> [[String]] {
        stride(from: 0, to: identifiers.count, by: limit).map { Array(identifiers[$0..<min($0 + limit, identifiers.count)]) }
    }
}

/// A record of every set-aside, restore and delete, so nothing disappears
/// without a trace and the person can always find where a photo went.
public struct SetAsideLog: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Written before asking iOS to hide, so a photo is never hidden without
        /// a record even if the app is killed while the system prompt is up.
        case pending
        case setAside
        case restored
        case deleted
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var identifier: String
        public var tripID: String
        public var state: State
        public var date: Date
    }

    public var entries: [Entry] = []

    public init() {}

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photocore/set-aside-log.json")
    }

    public static func load(from url: URL = defaultURL()) -> SetAsideLog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let log = try? decoder.decode(SetAsideLog.self, from: data) else { return SetAsideLog() }
        return log
    }

    public func save(to url: URL = defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public mutating func record(_ identifiers: [String], tripID: String, state: State, at date: Date = Date()) {
        entries.append(contentsOf: identifiers.map { Entry(identifier: $0, tripID: tripID, state: state, date: date) })
    }

    /// Each photo's latest state.
    public var latest: [String: Entry] {
        var result: [String: Entry] = [:]
        for entry in entries where result[entry.identifier].map({ $0.date <= entry.date }) ?? true {
            result[entry.identifier] = entry
        }
        return result
    }

    public func currentlySetAside(tripID: String? = nil) -> [String] {
        latest.values
            .filter { ($0.state == .setAside || $0.state == .pending) && (tripID == nil || $0.tripID == tripID) }
            .sorted { $0.date < $1.date }
            .map(\.identifier)
    }

    public func deleted(tripID: String? = nil) -> [Entry] {
        latest.values.filter { $0.state == .deleted && (tripID == nil || $0.tripID == tripID) }.sorted { $0.date < $1.date }
    }
}

/// The Photos side of set aside, restore and delete.
public enum PhotoLibrarySafety {
    public static let albumTitle = "Photocore · Set aside"

    public static func protection(for identifiers: [String]) -> [String: LibraryProtection] {
        var result: [String: LibraryProtection] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).enumerateObjects { asset, _, _ in
            var inOtherAlbum = false
            PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).enumerateObjects { collection, _, stop in
                if collection.localizedTitle != albumTitle && !(collection.localizedTitle ?? "").hasPrefix("Photocore") {
                    inOtherAlbum = true
                    stop.pointee = true
                }
            }
            result[asset.localIdentifier] = LibraryProtection(
                isFavorite: asset.isFavorite,
                isEdited: asset.hasAdjustments,
                isInOtherAlbum: inOtherAlbum,
                isShared: asset.sourceType.contains(.typeCloudShared)
            )
        }
        return result
    }

    /// Gathers the photos in the set-aside album. Nothing else changes: the
    /// photos stay in the library and in every other album.
    ///
    /// Photocore never hides photos. iOS keeps hidden photos away from apps
    /// (the Hidden album is locked), so an app that hides a photo cannot unhide
    /// it; that was measured on 2026-10-01 and is why set aside is album-only.
    public static func setAside(_ identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        let album = existingAlbum()
        try await PHPhotoLibrary.shared().performChanges {
            let request = album.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            request.addAssets(assets)
        }
    }

    /// Takes the photos out of the set-aside album.
    public static func restore(_ identifiers: [String]) async throws {
        guard !identifiers.isEmpty, let album = existingAlbum() else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets)
        }
    }

    /// Deletes at most one batch. iOS shows its own confirmation, which apps
    /// cannot skip, and deleted photos stay in Recently Deleted for 30 days.
    /// Returns the identifiers actually deleted.
    public static func delete(_ identifiers: [String]) async throws -> [String] {
        guard let batch = SetAsidePlanner.deleteBatches(identifiers).first else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
        return batch
    }

    /// Everything in the set-aside album, whatever the log says. The album is the
    /// source of truth for restore.
    public static func albumContents() -> [String] {
        guard let album = existingAlbum() else { return [] }
        var identifiers: [String] = []
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
        return identifiers
    }

    /// Records, hides, then confirms. If the person declines the iOS prompt or
    /// the app dies first, the pending entry stays and restore still finds it.
    public static func setAside(_ identifiers: [String], tripID: String, logURL: URL = SetAsideLog.defaultURL()) async throws {
        var log = SetAsideLog.load(from: logURL)
        log.record(identifiers, tripID: tripID, state: .pending)
        try log.save(to: logURL)
        do {
            try await setAside(identifiers)
        } catch {
            log.record(identifiers, tripID: tripID, state: .restored)
            try? log.save(to: logURL)
            throw error
        }
        log.record(identifiers, tripID: tripID, state: .setAside)
        try log.save(to: logURL)
    }

    /// Restores everything in the album plus anything the log still lists.
    public static func restoreEverything(logURL: URL = SetAsideLog.defaultURL()) async throws -> Int {
        var log = SetAsideLog.load(from: logURL)
        let logged = log.currentlySetAside()
        let all = Array(Set(albumContents()).union(logged))
        guard !all.isEmpty else { return 0 }
        try await restore(all)
        for (trip, group) in Dictionary(grouping: all, by: { log.latest[$0]?.tripID ?? "" }) {
            log.record(group, tripID: trip, state: .restored)
        }
        try log.save(to: logURL)
        return all.count
    }

    private static func existingAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", albumTitle)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
    }
}
