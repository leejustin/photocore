import CryptoKit
import Foundation
import PhotoEngineCore

public final class AnalysisCache: @unchecked Sendable {
    private struct Entry: Codable {
        var sourcePath: String
        var fileSize: Int64
        var modifiedAt: Date?
        var sourceSignature: String?
        var contentHash: String?
        var analyzerVersion: String
        var signals: AnalysisSignals
    }

    private struct File: Codable {
        var schemaVersion: Int
        var sourceFolder: String
        var entries: [Entry]
    }

    private let sourceFolder: URL
    private let cacheURL: URL
    private var entries: [String: Entry]
    private let analyzerVersion: String

    public init(sourceFolder: URL, fileManager: FileManager = .default) {
        self.sourceFolder = sourceFolder.standardizedFileURL
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let digest = SHA256.hash(data: Data(self.sourceFolder.path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.cacheURL = cacheRoot
            .appendingPathComponent("PhotoEngine", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
            .appendingPathComponent("analysis-v2.plist")
        self.entries = [:]
        self.analyzerVersion = [
            "apple-analysis-0.5.0",
            "feature-print-revision-2",
            "face-quality-revision-3",
            "subject-crop-v2-min64",
            "thumbnail-1024-vision-on-thumbnail",
            ProcessInfo.processInfo.operatingSystemVersionString
        ].joined(separator: "|")

        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? PropertyListDecoder().decode(File.self, from: data),
              file.schemaVersion == 2,
              file.sourceFolder == self.sourceFolder.path else { return }
        self.entries = Dictionary(uniqueKeysWithValues: file.entries.map { ($0.sourcePath, $0) })
    }

    public func signals(for asset: PhotoAsset) -> AnalysisSignals? {
        guard let entry = entries[asset.url.standardizedFileURL.path],
              entry.analyzerVersion == analyzerVersion,
              entry.fileSize == asset.metadata.fileSize,
              entry.modifiedAt == asset.sourceModifiedAt,
              entry.sourceSignature == asset.sourceSignature,
              entry.contentHash == asset.contentHash else {
            return nil
        }
        return entry.signals
    }

    public func update(asset: PhotoAsset, signals: AnalysisSignals) {
        let path = asset.url.standardizedFileURL.path
        entries[path] = Entry(
            sourcePath: path,
            fileSize: asset.metadata.fileSize,
            modifiedAt: asset.sourceModifiedAt,
            sourceSignature: asset.sourceSignature,
            contentHash: asset.contentHash,
            analyzerVersion: analyzerVersion,
            signals: signals
        )
    }

    public func retainAssets(_ assets: [PhotoAsset]) {
        let currentPaths = Set(assets.map { $0.url.standardizedFileURL.path })
        entries = entries.filter { currentPaths.contains($0.key) }
    }

    public func save() throws {
        let file = File(schemaVersion: 2, sourceFolder: sourceFolder.path, entries: Array(entries.values))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
    }

    /// The cache is recreatable and may be evicted, but exposing its current
    /// size lets the UI explain where local storage is going.
    public var fileSize: Int64 {
        (try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
