import Foundation
import Observation
import PhotoEngineWorkflow
import PhotosUI
import SwiftUI

/// The App Clip's one job: add a friend's best photos to a group book while
/// sending as little as possible. It culls their picks on this phone, offers
/// feature prints first, and uploads only the originals the book wants.
@MainActor
@Observable
final class ClipModel {
    enum Stage: Equatable {
        /// No invite yet (opened without a link).
        case waiting
        case loading
        case join
        case ready
        case looking(done: Int, total: Int)
        case asking
        case sending(done: Int, total: Int)
        case done(sent: Int, picked: Int, chosen: Int)
        case closed
        case failed(String)
    }

    private(set) var stage: Stage = .waiting
    private(set) var title: String?
    private(set) var owner: String?
    private(set) var name: String?
    private(set) var base: URL?
    private(set) var code: String?
    private var token: String?

    var bookLine: String {
        "\(owner ?? "Someone from the trip") is making a book of \(title ?? "the trip")."
    }

    /// Opens an invite link: `https://<host>/j/<code>`.
    func open(_ url: URL?) {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "j" else { stage = .failed("That link isn't an invite."); return }
        var root = components
        root.path = ""
        root.query = nil
        root.fragment = nil
        base = root.url
        code = String(parts[1])
        token = UserDefaults.standard.string(forKey: "BoundClipToken-" + String(parts[1]))
        Task { await refresh() }
    }

    func refresh() async {
        guard base != nil, code != nil else { return }
        stage = .loading
        do {
            let status: Status = try await call("status")
            title = status.title
            owner = status.ownerName
            guard status.open else { stage = .closed; return }
            if let me = status.me, token != nil {
                name = me
                stage = .ready
            } else {
                token = nil
                stage = .join
            }
        } catch {
            stage = .failed(message(error))
        }
    }

    func join(name: String, email: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            var body: [String: Any] = ["name": trimmed]
            if !email.trimmingCharacters(in: .whitespaces).isEmpty { body["email"] = email.trimmingCharacters(in: .whitespaces) }
            let joined: Joined = try await call("join", method: "POST", json: body)
            token = joined.token
            self.name = joined.name
            if let code { UserDefaults.standard.set(joined.token, forKey: "BoundClipToken-" + code) }
            stage = .ready
        } catch {
            stage = .failed(message(error))
        }
    }

    /// Copies the picks to a temporary folder, culls them here, offers the
    /// best and uploads what the book wants.
    func add(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("picks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var files: [URL] = []
            for (index, item) in items.enumerated() {
                stage = .looking(done: index, total: items.count)
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let heic = data.count > 12 && String(decoding: data[4..<8], as: UTF8.self) == "ftyp"
                let url = folder.appendingPathComponent(String(format: "p%04d.", index + 1) + (heic ? "heic" : "jpg"))
                try data.write(to: url)
                files.append(url)
            }
            stage = .looking(done: 0, total: files.count)
            let source = FilePhotoSource(files: files)
            let offers = try await GroupOffers.offers(source: source, storeFolder: folder.appendingPathComponent("analysis")) { progress in
                if case .analyzing(let done, let total) = progress {
                    Task { @MainActor in self.stage = .looking(done: done, total: total) }
                }
            }
            stage = .asking
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let wanted: Wanted = try await call("offers", method: "POST", body: try encoder.encode(["offers": offers]))
            let byName = Dictionary(files.map { (GroupOffers.offerName($0.lastPathComponent), $0) }, uniquingKeysWith: { a, _ in a })
            for (index, name) in wanted.wanted.enumerated() {
                stage = .sending(done: index, total: wanted.wanted.count)
                guard let file = byName[name] else { continue }
                let _: Uploaded = try await call("photos/" + name, method: "PUT", body: try Data(contentsOf: file))
            }
            stage = .done(sent: wanted.wanted.count, picked: files.count, chosen: offers.count)
        } catch {
            stage = .failed(message(error))
        }
    }

    func again() { stage = .ready }

    // MARK: Server

    private struct Status: Decodable {
        var title: String?
        var open: Bool
        var me: String?
        var ownerName: String?
    }
    private struct Joined: Decodable { var name: String; var token: String }
    private struct Wanted: Decodable { var wanted: [String]; var uploaded: Int; var offered: Int }
    private struct Uploaded: Decodable { var stored: String }
    private struct Failure: Decodable {
        struct Payload: Decodable { var message: String }
        var error: Payload
    }

    struct ClipError: LocalizedError {
        var errorDescription: String?
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Check your connection and try again."
    }

    private func call<T: Decodable>(_ path: String, method: String = "GET", json: [String: Any]? = nil, body: Data? = nil) async throws -> T {
        guard let base, let code else { throw ClipError(errorDescription: "Open an invite link first.") }
        var request = URLRequest(url: base.appendingPathComponent("j/\(code)/\(path)"))
        request.httpMethod = method
        if let token { request.setValue(token, forHTTPHeaderField: "X-Photocore-Contributor") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue(method == "PUT" ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClipError(errorDescription: (try? JSONDecoder().decode(Failure.self, from: data))?.error.message ?? "The book's server answered \(status).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
