import CryptoKit
import Foundation
import PhotoEngineCore

public final class AnalysisCache: @unchecked Sendable {
    private struct Entry: Codable {
        var sourcePath: String
        var fileSize: Int64
        var modifiedAt: Date?
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
    private let analyzerVersion = "apple-analysis-0.1.0"

    public init(sourceFolder: URL, fileManager: FileManager = .default) {
        self.sourceFolder = sourceFolder.standardizedFileURL
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let digest = SHA256.hash(data: Data(self.sourceFolder.path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.cacheURL = cacheRoot
            .appendingPathComponent("PhotoEngine", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
            .appendingPathComponent("analysis.json")
        self.entries = [:]

        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? JSONDecoder.photoEngine.decode(File.self, from: data),
              file.schemaVersion == 1,
              file.sourceFolder == self.sourceFolder.path else { return }
        self.entries = Dictionary(uniqueKeysWithValues: file.entries.map { ($0.sourcePath, $0) })
    }

    public func signals(for asset: PhotoAsset) -> AnalysisSignals? {
        guard let entry = entries[asset.url.standardizedFileURL.path],
              entry.analyzerVersion == analyzerVersion,
              entry.fileSize == asset.metadata.fileSize,
              entry.modifiedAt == asset.sourceModifiedAt else {
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
            analyzerVersion: analyzerVersion,
            signals: signals
        )
    }

    public func save() throws {
        let file = File(schemaVersion: 1, sourceFolder: sourceFolder.path, entries: Array(entries.values))
        let encoder = JSONEncoder.photoEngine
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var photoEngine: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var photoEngine: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

