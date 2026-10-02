import Foundation
import Observation
import PhotoEngineWorkflow
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

/// The trip on the server, remembered per local trip so the invite link, the
/// uploads and the book survive a relaunch.
struct RemoteTrip: Codable, Equatable {
    var id: String
    var slug: String
    var ownerToken: String
    var bookPath: String
    var invitePath: String?
    var keepersUploaded = false
}

/// Server trips per local trip. They hold the owner token, so they live in the
/// Keychain; anything an older build left in UserDefaults moves over once.
enum RemoteTripStore {
    private static let key = "PhotocoreRemoteTrips"

    private static func all() -> [String: RemoteTrip] {
        if let data = Keychain.data(key), let trips = try? JSONDecoder().decode([String: RemoteTrip].self, from: data) { return trips }
        if let legacy = UserDefaults.standard.data(forKey: key), let trips = try? JSONDecoder().decode([String: RemoteTrip].self, from: legacy) {
            if Keychain.set(legacy, for: key) { UserDefaults.standard.removeObject(forKey: key) }
            return trips
        }
        return [:]
    }

    static func trip(for tripID: String) -> RemoteTrip? { all()[tripID] }

    static func save(_ trip: RemoteTrip, for tripID: String) {
        var trips = all()
        trips[tripID] = trip
        if let data = try? JSONEncoder().encode(trips) { Keychain.set(data, for: key) }
    }
}

/// The owner's first name for photo credits on group books, remembered once.
enum OwnerName {
    static var saved: String {
        get { UserDefaults.standard.string(forKey: "PhotocoreOwnerName") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "PhotocoreOwnerName") }
    }
}

/// The paid finish for one trip: preview, invite friends, upload keepers,
/// finish, share.
@MainActor
@Observable
final class TripFinish {
    struct Person: Decodable, Equatable, Identifiable {
        var name: String
        var photos: Int
        var id: String { name }
    }
    enum Stage: Equatable {
        case idle
        case uploading(done: Int, total: Int)
        case finishing(String)
        case done(book: URL, edit: URL)
        /// The plan doesn't cover this; the card offers the plans.
        case needsPlan(String)
        case failed(String)
    }

    private(set) var stage: Stage = .idle
    private(set) var before: UIImage?
    private(set) var after: UIImage?
    private(set) var previewFailed = false
    private(set) var remote: RemoteTrip?
    private(set) var people: [Person] = []
    private(set) var inviteOpen = true
    private(set) var inviting = false
    private(set) var inviteError: String?
    /// Friends' photos when the book was last made, to tell when there's more.
    private(set) var photosAtLastFinish: Int?
    private(set) var plan: Plan = .free
    private(set) var limits: PlanLimits = Plan.free.limits
    /// Whether this trip can still be this phone's free book.
    private(set) var freeBookAvailable = true
    private(set) var printing = false

    var friendsPhotos: Int { people.reduce(0) { $0 + $1.photos } }

    func inviteURL(_ server: FinishServer) -> URL? {
        remote?.invitePath.map { server.baseURL.appendingPathComponent($0) }
    }

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

    /// Leaves the plan prompt without changing anything.
    func reset() {
        if case .needsPlan = stage { stage = .idle }
    }

    /// A book finished earlier for this trip, so the card opens on the link.
    func restore(tripID: String) {
        remote = RemoteTripStore.trip(for: tripID)
        photosAtLastFinish = UserDefaults.standard.object(forKey: "PhotocoreFriendsAtFinish-" + tripID) as? Int
        if let saved = BookStore.book(for: tripID) { stage = .done(book: saved.book, edit: saved.edit) }
    }

    private func settings(title: String?, note: String, events: [String], theme: String) -> [String: Any] {
        var body: [String: Any] = ["calendarEvents": events, "theme": theme, "note": note.trimmingCharacters(in: .whitespaces), "ownerName": OwnerName.saved]
        if let title { body["title"] = title }
        return body
    }

    /// Hands a signed App Store transaction to the server for this book.
    /// Returns nil on success, or the reason it didn't apply.
    func applyPlan(jws: String, tripID: String, title: String?, server: FinishServer) async -> String? {
        do {
            var body = settings(title: title, note: "", events: [], theme: "book")
            body["installID"] = InstallIdentity.id.uuidString
            let trip = try await ensureRemote(tripID: tripID, body: body, server: server)
            let applied: PlanStatus = try await call(server, "v2/trips/\(trip.id)/plan", method: "POST", json: ["transaction": jws])
            plan = applied.plan
            limits = applied.limits
            if PlanProductFromJWS.isPass(jws) { await Store.shared.spent(jws: jws) }
            if case .needsPlan = stage { stage = .idle }
            return nil
        } catch {
            return (error as? FinishError)?.message ?? error.localizedDescription
        }
    }

    /// Fetches the print-ready PDF of the finished book into a temporary file.
    func printFile(server: FinishServer) async -> URL? {
        guard let remote else { return nil }
        printing = true
        defer { printing = false }
        var request = URLRequest(url: server.baseURL.appendingPathComponent("v2/trips/\(remote.id)/print.pdf"))
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Photocore book.pdf")
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Creates the trip on the server so friends can start adding photos
    /// before the owner finishes.
    func invite(tripID: String, title: String?, note: String, events: [String], theme: String, server: FinishServer) async {
        guard remote == nil else { return }
        inviting = true
        inviteError = nil
        defer { inviting = false }
        do {
            var body = settings(title: title, note: note, events: events, theme: theme)
            body["installID"] = InstallIdentity.id.uuidString
            _ = try await ensureRemote(tripID: tripID, body: body, server: server)
            await refreshPeople(server: server)
        } catch {
            inviteError = (error as? FinishError)?.message ?? error.localizedDescription
        }
    }

    private func ensureRemote(tripID: String, body: [String: Any], server: FinishServer) async throws -> RemoteTrip {
        if let remote { return remote }
        let created: Created = try await call(server, "v2/trips", method: "POST", json: body)
        let trip = RemoteTrip(id: created.id, slug: created.slug, ownerToken: created.ownerToken, bookPath: created.bookPath, invitePath: created.invitePath)
        RemoteTripStore.save(trip, for: tripID)
        remote = trip
        return trip
    }

    /// Who has added photos so far.
    func refreshPeople(server: FinishServer) async {
        guard let remote, let status: Status = try? await call(server, "v2/trips/\(remote.id)") else { return }
        people = status.contributors.filter { $0.photos > 0 }
        inviteOpen = status.inviteOpen
        if let plan = status.plan { self.plan = plan }
        if let limits = status.limits { self.limits = limits }
        freeBookAvailable = status.freeBookAvailable ?? true
    }

    func setInvite(open: Bool, server: FinishServer) async {
        guard let remote else { return }
        let _: [String: Bool]? = try? await call(server, "v2/trips/\(remote.id)/invite", method: "POST", json: ["open": open])
        await refreshPeople(server: server)
    }

    func finish(tripID: String, title: String?, note: String, events: [String], theme: String, identifiers: [String], server: FinishServer) async {
        do {
            var body = settings(title: title, note: note, events: events, theme: theme)
            body["installID"] = InstallIdentity.id.uuidString
            var trip = try await ensureRemote(tripID: tripID, body: body, server: server)
            await refreshPeople(server: server)
            // A Plus subscriber's books are covered without asking.
            if plan == .free, let plus = Store.shared.plus {
                _ = await applyPlan(jws: plus, tripID: tripID, title: title, server: server)
            }
            // Ask before uploading anything the plan won't cover.
            if plan == .free && !freeBookAvailable {
                stage = .needsPlan("Your free book is already made. Plus or a Trip Pass covers this one.")
                return
            }
            if let style = BookTheme(name: theme), !limits.allows(style) {
                stage = .needsPlan("\(style.displayName) is part of Plus and the passes.")
                return
            }
            let _: [String: Bool] = try await call(server, "v2/trips/\(trip.id)/settings", method: "POST", json: body)
            if !trip.keepersUploaded {
                for (index, identifier) in identifiers.enumerated() {
                    stage = .uploading(done: index, total: identifiers.count)
                    guard let original = await Self.original(identifier: identifier) else { continue }
                    let name = "p\(index + 1)-" + String(identifier.prefix(8).filter { $0.isLetter || $0.isNumber })
                    var request = URLRequest(url: server.baseURL.appendingPathComponent("v2/trips/\(trip.id)/photos/\(name)"))
                    request.httpMethod = "PUT"
                    request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
                    let (_, response) = try await URLSession.shared.upload(for: request, from: original)
                    guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw FinishError.server("A photo didn't upload.") }
                }
                stage = .uploading(done: identifiers.count, total: identifiers.count)
                trip.keepersUploaded = true
                RemoteTripStore.save(trip, for: tripID)
                remote = trip
            }
            await refreshPeople(server: server)
            let friends = friendsPhotos
            let created = trip
            let job: Job = try await call(server, "v2/trips/\(trip.id)/finish", method: "POST")
            stage = .finishing("Starting")
            while true {
                try await Task.sleep(for: .seconds(2))
                let current: Job = try await call(server, "v2/jobs/\(job.id)")
                switch current.state {
                case "succeeded":
                    let book = server.baseURL.appendingPathComponent(created.bookPath)
                    let edit = URL(string: book.absoluteString + "#edit=" + created.ownerToken) ?? book
                    BookStore.save(FinishedBook(book: book, edit: edit, finishedAt: Date()), for: tripID)
                    UserDefaults.standard.set(friends, forKey: "PhotocoreFriendsAtFinish-" + tripID)
                    photosAtLastFinish = friends
                    stage = .done(book: book, edit: edit)
                    return
                case "failed", "cancelled":
                    throw FinishError.server(current.error?.message ?? "The finish didn't complete.")
                default:
                    stage = .finishing(current.message ?? "Working")
                }
            }
        } catch FinishError.payment(let message) {
            stage = .needsPlan(message)
        } catch {
            stage = .failed((error as? FinishError)?.message ?? error.localizedDescription)
        }
    }

    private struct PlanStatus: Decodable { var plan: Plan; var limits: PlanLimits }
    private struct ServerError: Decodable {
        struct Payload: Decodable { var message: String }
        var error: Payload
    }

    private struct Created: Decodable { var id: String; var slug: String; var ownerToken: String; var bookPath: String; var invitePath: String? }
    private struct Status: Decodable {
        var inviteOpen: Bool
        var contributors: [Person]
        var plan: Plan?
        var limits: PlanLimits?
        var freeBookAvailable: Bool?
    }
    private struct Job: Decodable {
        struct Failure: Decodable { var message: String }
        var id: String
        var state: String
        var message: String?
        var error: Failure?
    }

    enum FinishError: Error {
        case server(String)
        /// The server said the plan doesn't cover this (HTTP 402).
        case payment(String)
        var message: String {
            switch self {
            case .server(let text), .payment(let text): text
            }
        }
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
        guard (200..<300).contains(status) else {
            let reason = (try? JSONDecoder().decode(ServerError.self, from: data))?.error.message
            if status == 402 { throw FinishError.payment(reason ?? "This needs Plus or a pass.") }
            throw FinishError.server(reason ?? "The Photocore server answered \(status).")
        }
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

/// Reads the product from a signed transaction's payload, to know whether a
/// purchase was a pass (spent on one book) without trusting it for anything else.
enum PlanProductFromJWS {
    static func isPass(_ jws: String) -> Bool {
        let parts = jws.split(separator: ".")
        guard parts.count == 3 else { return false }
        var base = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let data = Data(base64Encoded: base),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = payload["productId"] as? String else { return false }
        return PlanProduct(rawValue: id)?.isPass ?? false
    }
}
