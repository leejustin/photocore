import Foundation
import Observation
import Photos
import UIKit

/// Where the paid finish runs. In a test build this is a Photocore server the
/// owner runs (for example on a Mac mini over Tailscale). Launch arguments
/// `-PhotocoreServerURL` and `-PhotocoreServerToken` set it for the simulator.
struct FinishServer: Equatable {
    var baseURL: URL
    var token: String

    static var saved: FinishServer? {
        let defaults = UserDefaults.standard
        guard let text = defaults.string(forKey: "PhotocoreServerURL"), let url = URL(string: text),
              let token = defaults.string(forKey: "PhotocoreServerToken"), !token.isEmpty else { return nil }
        return FinishServer(baseURL: url, token: token)
    }

    static func save(url: String, token: String) {
        UserDefaults.standard.set(url.trimmingCharacters(in: .whitespaces), forKey: "PhotocoreServerURL")
        UserDefaults.standard.set(token.trimmingCharacters(in: .whitespaces), forKey: "PhotocoreServerToken")
    }
}

/// The paid finish for one trip: preview, upload keepers, finish, share.
@MainActor
@Observable
final class TripFinish {
    enum Stage: Equatable {
        case idle
        case uploading(done: Int, total: Int)
        case finishing(String)
        case done(book: URL, edit: URL)
        case failed(String)
    }

    private(set) var stage: Stage = .idle
    private(set) var before: UIImage?
    private(set) var after: UIImage?
    private(set) var previewFailed = false

    var isWorking: Bool {
        switch stage {
        case .uploading, .finishing: true
        default: false
        }
    }

    /// Renders one keeper with the hosted edit so the upsell is honest. Sends a
    /// 1280-pixel copy only.
    func loadPreview(identifier: String, server: FinishServer) async {
        guard after == nil else { return }
        guard let data = await Self.jpeg(identifier: identifier, maxPixel: 1280) else { previewFailed = true; return }
        before = UIImage(data: data)
        var request = URLRequest(url: server.baseURL.appendingPathComponent("v2/preview"))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        guard let (body, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { previewFailed = true; return }
        after = UIImage(data: body)
    }

    /// A book finished earlier for this trip, so the card opens on the link.
    func restore(tripID: String) {
        if let saved = BookStore.book(for: tripID) { stage = .done(book: saved.book, edit: saved.edit) }
    }

    func finish(tripID: String, title: String?, note: String, events: [String], identifiers: [String], server: FinishServer) async {
        do {
            var body: [String: Any] = ["calendarEvents": events]
            if let title { body["title"] = title }
            if !note.trimmingCharacters(in: .whitespaces).isEmpty { body["note"] = note }
            let created: Created = try await call(server, "v2/trips", method: "POST", json: body)
            for (index, identifier) in identifiers.enumerated() {
                stage = .uploading(done: index, total: identifiers.count)
                guard let original = await Self.original(identifier: identifier) else { continue }
                let name = "p\(index + 1)-" + String(identifier.prefix(8).filter { $0.isLetter || $0.isNumber })
                var request = URLRequest(url: server.baseURL.appendingPathComponent("v2/trips/\(created.id)/photos/\(name)"))
                request.httpMethod = "PUT"
                request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.upload(for: request, from: original)
                guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw FinishError.server("A photo didn't upload.") }
            }
            stage = .uploading(done: identifiers.count, total: identifiers.count)
            let job: Job = try await call(server, "v2/trips/\(created.id)/finish", method: "POST")
            stage = .finishing("Starting")
            while true {
                try await Task.sleep(for: .seconds(2))
                let current: Job = try await call(server, "v2/jobs/\(job.id)")
                switch current.state {
                case "succeeded":
                    let book = server.baseURL.appendingPathComponent(created.bookPath)
                    let edit = URL(string: book.absoluteString + "#edit=" + created.ownerToken) ?? book
                    BookStore.save(FinishedBook(book: book, edit: edit, finishedAt: Date()), for: tripID)
                    stage = .done(book: book, edit: edit)
                    return
                case "failed", "cancelled":
                    throw FinishError.server(current.error?.message ?? "The finish didn't complete.")
                default:
                    stage = .finishing(current.message ?? "Working")
                }
            }
        } catch {
            stage = .failed((error as? FinishError)?.message ?? error.localizedDescription)
        }
    }

    private struct Created: Decodable { var id: String; var slug: String; var ownerToken: String; var bookPath: String }
    private struct Job: Decodable {
        struct Failure: Decodable { var message: String }
        var id: String
        var state: String
        var message: String?
        var error: Failure?
    }

    enum FinishError: Error {
        case server(String)
        var message: String { if case .server(let text) = self { text } else { "" } }
    }

    private func call<T: Decodable>(_ server: FinishServer, _ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: server.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw FinishError.server("The Photocore server answered \(status).") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    /// The original file as stored in Photos (HEIC or JPEG with its metadata).
    nonisolated static func original(identifier: String) async -> Data? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    nonisolated static func jpeg(identifier: String, maxPixel: Int) async -> Data? {
        guard let data = await original(identifier: identifier),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.88)
    }
}
