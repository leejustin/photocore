import CryptoKit
import Foundation
import PhotoEngineApple
import PhotoEngineCore
import PhotoEngineWorkflow

actor MediaCache {
    private let directory: URL
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(directory: URL) {
        self.directory = directory
    }

    func thumbnail(session: CurationSession, photoID: PhotoID) throws -> (data: Data, etag: String) {
        guard let photo = session.result.analyzed.first(where: { $0.id == photoID }) else {
            throw APIError.notFound("No photo \(photoID.description)")
        }
        let etag = quoted(sha256(Data((photo.signals.fingerprint.contentHash + "|thumb").utf8)))
        let file = cacheFile(sessionID: session.result.sessionID.description, name: etag)
        if let cached = try? Data(contentsOf: file) { return (cached, etag) }
        let data = try PreviewDiskCache.shared.jpegPreview(for: photo.asset.url, maxPixelSize: 512)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return (data, etag)
    }

    func preview(session: CurationSession, photoID: PhotoID, size: Int) async throws -> (data: Data, etag: String) {
        guard let photo = session.result.analyzed.first(where: { $0.id == photoID }) else {
            throw APIError.notFound("No photo \(photoID.description)")
        }
        let custom = session.customRecipes[photoID]
        let recipe = custom ?? LookComposer.recipe(for: photo, look: look(session), settings: session.lookSettings, horizon: nil)
        let recipeData = (try? APIJSON.data(recipe)) ?? Data()
        var identity = Data(photo.signals.fingerprint.contentHash.utf8)
        identity.append(recipeData)
        identity.append(Data("\(size)".utf8))
        let etag = quoted(sha256(identity))
        let file = cacheFile(sessionID: session.result.sessionID.description, name: etag)
        if let cached = try? Data(contentsOf: file) { return (cached, etag) }
        await acquire()
        defer { release() }
        if let cached = try? Data(contentsOf: file) { return (cached, etag) }
        let data = try ApplePhotoRenderer().previewJPEG(photo: photo, recipe: recipe, maxLongEdge: size)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return (data, etag)
    }

    private func look(_ session: CurationSession) -> AlbumLook {
        AlbumLookLibrary.shared.allLooks().first { $0.id == session.lookSettings.lookID } ?? AlbumLook.builtins[0]
    }

    private func cacheFile(sessionID: String, name: String) -> URL {
        let safe = name.filter { $0.isHexDigit }
        return directory.appendingPathComponent(sessionID, isDirectory: true).appendingPathComponent(safe + ".jpg")
    }

    private func acquire() async {
        if inFlight < 2 {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            inFlight = max(0, inFlight - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func quoted(_ value: String) -> String { "\"\(value)\"" }
}
