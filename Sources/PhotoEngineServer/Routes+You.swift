import Foundation
import HTTPTypes
import Hummingbird
import PhotoEngineApple
import PhotoEngineWorkflow

struct YouFaceDTO: Encodable, Sendable {
    var id: String
    var url: String
}

struct YouPhotoDTO: Encodable, Sendable {
    var file: String
    var url: String
    var credit: String?
}

/// What the "Photos of you" part of the invite page shows one person.
struct YouDTO: Encodable, Sendable {
    /// Whether the book has faces to pick from yet.
    var available: Bool
    var faces: [YouFaceDTO]
    var tapped: [String]
    var photos: [YouPhotoDTO]
}

struct TapBody: Decodable, Sendable { var face: String }
struct NotMeBody: Decodable, Sendable { var file: String }

enum YouIndex {
    /// Builds the face index for a finished book, replacing the last one.
    static func build(trips: TripStore, tripID: String, embedder: any FaceEmbedder) async throws {
        let bookFolder = await trips.bookFolder(tripID)
        let book = try TripBook.load(from: bookFolder)
        let photos = book.allPhotos.map { (id: $0.fileName, url: bookFolder.appendingPathComponent(BookRenderer.photoPath($0))) }
        let folder = await trips.facesFolder(tripID)
        let fresh = folder.deletingLastPathComponent().appendingPathComponent("faces-new", isDirectory: true)
        try? FileManager.default.removeItem(at: fresh)
        let index = try FaceIndexer.index(photos: photos, crops: fresh.appendingPathComponent("crops", isDirectory: true), embedder: embedder)
        try index.save(to: fresh)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: fresh, to: folder)
    }

    static func view(trips: TripStore, record: TripRecord, person: Contributor, embedder: any FaceEmbedder) async -> YouDTO {
        guard record.finishedAt != nil, record.isHosted(), let index = FaceIndex.load(from: await trips.facesFolder(record.id)), !index.faces.isEmpty,
              let code = record.inviteCode, let book = try? TripBook.load(from: await trips.bookFolder(record.id)) else {
            return YouDTO(available: false, faces: [], tapped: [], photos: [])
        }
        let taps = person.tappedFaces ?? []
        let tapped = index.tapped(embeddings: taps, embedder: embedder)
        let mine = index.matches(embeddings: taps, embedder: embedder).union(tapped)
        let files = Set(index.faces.filter { mine.contains($0.id) }.map(\.photo)).subtracting(person.notMe ?? [])
        let faces = index.pickerOrder().map { YouFaceDTO(id: $0.id, url: "/j/\(code)/faces/\($0.id).jpg") }
        let photos = book.allPhotos.filter { files.contains($0.fileName) }.map {
            YouPhotoDTO(file: $0.fileName, url: TripPaths.book(record.slug) + BookRenderer.photoPath($0), credit: $0.credit)
        }
        return YouDTO(available: true, faces: faces, tapped: Array(tapped), photos: photos)
    }

    /// The book photos a person is in, for their email.
    static func count(trips: TripStore, record: TripRecord, person: Contributor, embedder: any FaceEmbedder) async -> Int {
        await view(trips: trips, record: record, person: person, embedder: embedder).photos.count
    }
}

private func contributorToken(_ request: Request) -> String? {
    request.headers[HTTPField.Name("X-Photocore-Contributor")!]
}

func registerYouRoutes(_ router: Router<BasicRequestContext>, trips: TripStore, embedder: any FaceEmbedder) {
    @Sendable func person(_ request: Request, _ context: BasicRequestContext) async throws -> (TripRecord, Contributor) {
        let code = try context.parameters.require("code")
        guard let record = await trips.record(invite: code) else { throw APIError.notFound("This invite link doesn't work.") }
        guard let person = await trips.contributor(record.id, token: contributorToken(request)) else { throw APIError.unauthorized("Join the book first.") }
        return (record, person)
    }

    router.get("j/{code}/you") { request, context in
        let (record, person) = try await person(request, context)
        return try APIJSON.response(await YouIndex.view(trips: trips, record: record, person: person, embedder: embedder))
    }

    /// Taps a face as yours, or untaps it.
    router.post("j/{code}/you") { request, context in
        let (record, person) = try await person(request, context)
        let body = try await request.decode(as: TapBody.self, context: context)
        guard let index = FaceIndex.load(from: await trips.facesFolder(record.id)), let face = index.faces.first(where: { $0.id == body.face }) else {
            throw APIError.notFound("That face isn't in the book any more.")
        }
        let updated = try await trips.changeContributor(record.id, person.id) { someone in
            var taps = someone.tappedFaces ?? []
            let before = taps.count
            taps.removeAll { embedder.distance($0, face.embedding).map { $0 < 0.12 } ?? false }
            if taps.count == before { taps.append(face.embedding) }
            someone.tappedFaces = Array(taps.suffix(20))
        } ?? person
        return try APIJSON.response(await YouIndex.view(trips: trips, record: record, person: updated, embedder: embedder))
    }

    /// "Not me" on a photo, or undo it.
    router.post("j/{code}/you/not") { request, context in
        let (record, person) = try await person(request, context)
        let body = try await request.decode(as: NotMeBody.self, context: context)
        let updated = try await trips.changeContributor(record.id, person.id) { someone in
            var list = someone.notMe ?? []
            if let i = list.firstIndex(of: body.file) { list.remove(at: i) } else { list.append(String(body.file.prefix(120))) }
            someone.notMe = list
        } ?? person
        return try APIJSON.response(await YouIndex.view(trips: trips, record: record, person: updated, embedder: embedder))
    }

    /// One face crop for the picker. Face ids are random; the photo it comes
    /// from is already on the book page for anyone with the link.
    router.get("j/{code}/faces/{file}") { _, context in
        let code = try context.parameters.require("code")
        let file = try context.parameters.require("file")
        guard let record = await trips.record(invite: code), record.isHosted() else { throw APIError.notFound("Not found.") }
        let id = file.hasSuffix(".jpg") ? String(file.dropLast(4)) : file
        guard id.count == 16, id.allSatisfy({ $0.isHexDigit }) else { throw APIError.notFound("Not found.") }
        let url = await trips.facesFolder(record.id).appendingPathComponent("crops/\(id).jpg")
        guard let data = try? Data(contentsOf: url) else { throw APIError.notFound("Not found.") }
        var headers = HTTPFields()
        headers[.contentType] = "image/jpeg"
        headers[.cacheControl] = "private, max-age=3600"
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        return APIJSON.bytes(data, headers: headers)
    }

    /// The book's photos of you, as one zip. Free for every friend.
    router.get("j/{code}/you.zip") { request, context in
        let (record, person) = try await person(request, context)
        let view = await YouIndex.view(trips: trips, record: record, person: person, embedder: embedder)
        guard !view.photos.isEmpty else { throw APIError.notFound("Tap your face first.") }
        let bookFolder = await trips.bookFolder(record.id)
        let entries = view.photos.enumerated().compactMap { index, photo -> ZipWriter.Entry? in
            let url = bookFolder.appendingPathComponent(String(photo.url.dropFirst(TripPaths.book(record.slug).count)))
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let who = (photo.credit ?? "").filter { $0.isLetter || $0.isNumber || $0 == " " }
            return ZipWriter.Entry(name: String(format: "%03d", index + 1) + (who.isEmpty ? "" : " " + who) + ".jpg", source: url)
        }
        let zip = await trips.folder(record.id).appendingPathComponent("work/you-\(person.id).zip")
        try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ZipWriter.write(entries, to: zip)
        defer { try? FileManager.default.removeItem(at: zip) }
        var headers = HTTPFields()
        headers[.contentType] = "application/zip"
        headers[.contentDisposition] = "attachment; filename=\"Photos of \(person.name.filter { $0.isLetter || $0.isNumber || $0 == " " }).zip\""
        headers[.cacheControl] = "private, no-store"
        return APIJSON.bytes(try Data(contentsOf: zip), headers: headers)
    }
}
