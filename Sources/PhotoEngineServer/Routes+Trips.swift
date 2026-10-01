import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import PhotoEngineApple
import PhotoEngineCore
import PhotoEnginePersistence
import PhotoEngineWorkflow

struct CreateTripBody: Decodable, Sendable {
    var title: String?
    var tone: String?
    var theme: String?
}

struct TripCreatedDTO: Encodable, Sendable {
    var id: String
    var slug: String
    var ownerToken: String
    var bookPath: String
    var editPath: String
}

struct TripDTO: Encodable, Sendable {
    var id: String
    var slug: String
    var ownerPhotos: Int
    var guestPhotos: Int
    var finishedAt: Date?
    var lastJobID: String?
    var writer: String?
    var bookPath: String
}

struct UploadDTO: Encodable, Sendable {
    var stored: String
    var count: Int
}

struct EditBody: Decodable, Sendable {
    var key: String
    var value: String
}

struct HeartBody: Decodable, Sendable {
    var photo: String
}

struct NoteBody: Decodable, Sendable {
    var name: String
    var text: String
}

struct FinishResult: Codable, Sendable {
    var bookPath: String
    var photos: Int
    var chapters: Int
    var writer: String
    var guestKept: Int
    var guestDuplicates: Int
}

enum TripPaths {
    static func book(_ slug: String) -> String { "/b/\(slug)/" }
    static func options(_ slug: String) -> BookRenderer.Options {
        BookRenderer.Options(editEndpoint: "/b/\(slug)/edits", guestEndpoint: "/b/\(slug)/guest")
    }
}

func registerTripRoutes(_ router: Router<BasicRequestContext>, env: ServerEnvironment, trips: TripStore) {
    // MARK: Owner API (server token)

    router.post("v2/trips") { request, context in
        let body = try await request.decode(as: CreateTripBody.self, context: context)
        let tone = DiaryTone(rawValue: body.tone ?? "warm") ?? .warm
        let theme = BookTheme(rawValue: body.theme ?? "book") ?? .book
        let title = body.title.map { String($0.prefix(120)) }
        let (record, token) = try await trips.create(title: title, tone: tone, theme: theme)
        let dto = TripCreatedDTO(id: record.id, slug: record.slug, ownerToken: token, bookPath: TripPaths.book(record.slug), editPath: TripPaths.book(record.slug) + "#edit=" + token)
        return try APIJSON.response(dto, status: .created)
    }

    router.get("v2/trips/{tid}") { _, context in
        let tid = try context.parameters.require("tid")
        guard let record = await trips.record(id: tid) else { throw APIError.notFound("No trip \(tid)") }
        let owner = (try? FileManager.default.contentsOfDirectory(atPath: await trips.ownerFolder(tid).path).count) ?? 0
        let guests = (try? FileManager.default.contentsOfDirectory(atPath: await trips.guestFolder(tid).path).count) ?? 0
        return try APIJSON.response(TripDTO(id: record.id, slug: record.slug, ownerPhotos: owner, guestPhotos: guests, finishedAt: record.finishedAt, lastJobID: record.lastJobID, writer: record.bookWriter, bookPath: TripPaths.book(record.slug)))
    }

    router.put("v2/trips/{tid}/photos/{name}") { request, context in
        let tid = try context.parameters.require("tid")
        let name = try context.parameters.require("name")
        guard await trips.record(id: tid) != nil else { throw APIError.notFound("No trip \(tid)") }
        let buffer = try await request.body.collect(upTo: TripLimits.uploadBytes)
        let url = try await trips.store(photo: Data(buffer: buffer), name: name, id: tid, guest: false)
        let count = (try? FileManager.default.contentsOfDirectory(atPath: await trips.ownerFolder(tid).path).count) ?? 0
        return try APIJSON.response(UploadDTO(stored: url.lastPathComponent, count: count), status: .created)
    }

    router.post("v2/trips/{tid}/finish") { _, context in
        let tid = try context.parameters.require("tid")
        guard let record = await trips.record(id: tid) else { throw APIError.notFound("No trip \(tid)") }
        let ownerFolder = await trips.ownerFolder(tid)
        guard ((try? FileManager.default.contentsOfDirectory(atPath: ownerFolder.path).count) ?? 0) > 0 else {
            throw APIError.precondition("Upload the trip's keepers before finishing.")
        }
        let job = JobRecord(id: UUID().uuidString, kind: "finish-trip", sessionID: nil, state: "queued", request: Data("{\"trip\":\"\(tid)\"}".utf8), createdAt: Date())
        let folders = TripFinisher.Folders(
            owner: ownerFolder,
            guests: await trips.guestFolder(tid),
            book: await trips.bookFolder(tid),
            work: await trips.folder(tid).appendingPathComponent("work", isDirectory: true)
        )
        let jobs = env.jobs
        let stored = try await env.jobs.enqueue(job) {
            let writer: any DiaryWriter = ClaudeDiaryWriter.fromEnvironment() ?? TemplateDiaryWriter()
            let outcome = try await TripFinisher.finish(
                folders: folders,
                title: record.title,
                tone: record.tone,
                theme: record.theme,
                writer: writer,
                options: TripPaths.options(record.slug),
                lookUpPlaces: ProcessInfo.processInfo.environment["PHOTOCORE_OFFLINE"] != "1"
            ) { stage, done, total in
                Task { await jobs.noteProgress(id: job.id, stage: "finish", completed: done, total: total, message: stage) }
            }
            try await trips.update(tid) {
                $0.finishedAt = Date()
                $0.bookWriter = outcome.book.writer
            }
            return try APIJSON.data(FinishResult(
                bookPath: TripPaths.book(record.slug),
                photos: outcome.report.photoCount,
                chapters: outcome.book.sections.count,
                writer: outcome.book.writer,
                guestKept: outcome.guestKept,
                guestDuplicates: outcome.guestDuplicates
            ))
        }
        try await trips.update(tid) { $0.lastJobID = stored.id }
        return try APIJSON.response(JobDTO(stored), status: .accepted)
    }

    /// The upsell preview: one small photo in, the paid finish out. Cheap enough
    /// to run on thumbnails before anyone pays.
    router.post("v2/preview") { request, _ in
        let buffer = try await request.body.collect(upTo: 15 * 1_024 * 1_024)
        let data = Data(buffer: buffer)
        guard TripStore.isImage(data) else { throw APIError.invalid("Send a JPEG or HEIC photo.") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let rendered = try FinishRenderer.render(url: temp, maxPixel: 1280)
        var headers = HTTPFields()
        headers[.contentType] = "image/jpeg"
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("X-Photocore-Mask")!] = rendered.maskSource.rawValue
        return APIJSON.bytes(rendered.jpeg, headers: headers)
    }

    // MARK: Public book (no server token; owner token for edits)

    router.get("b/{slug}") { request, context in
        let slug = try context.parameters.require("slug")
        // The page uses relative image paths, so it must be served with a trailing slash.
        guard request.uri.path.hasSuffix("/") else {
            var headers = HTTPFields()
            headers[.location] = TripPaths.book(slug)
            return Response(status: .movedPermanently, headers: headers)
        }
        return try await bookFile(trips: trips, slug: slug, relative: "index.html")
    }

    router.get("b/{slug}/{part}") { _, context in
        let slug = try context.parameters.require("slug")
        let part = try context.parameters.require("part")
        return try await bookFile(trips: trips, slug: slug, relative: part)
    }

    router.get("b/{slug}/{part}/{file}") { _, context in
        let part = try context.parameters.require("part")
        guard part == "photos" || part == "instagram" else { throw APIError.notFound("Not found.") }
        return try await bookFile(trips: trips, slug: context.parameters.require("slug"), relative: part + "/" + context.parameters.require("file"))
    }

    router.post("b/{slug}/edits") { request, context in
        let slug = try context.parameters.require("slug")
        guard let record = await trips.record(slug: slug) else { throw APIError.notFound("No book.") }
        let bearer = request.headers[.authorization].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        guard await trips.isOwner(record, token: bearer) else { throw APIError.unauthorized("Only the book's owner can edit it.") }
        let body = try await request.decode(as: EditBody.self, context: context)
        do {
            try TripFinisher.applyEdit(key: body.key, value: body.value, bookFolder: await trips.bookFolder(record.id), options: TripPaths.options(slug))
        } catch TripFinisher.EditError.notEditable {
            throw APIError.invalid("That part of the book can't be edited.")
        } catch TripFinisher.EditError.tooLong {
            throw APIError.invalid("Keep it under \(BookEdits.maximumLength) characters.")
        }
        return try APIJSON.response(["ok": true])
    }

    // A literal route: the POST routes below put "guest" in the router tree,
    // which takes precedence over the {part} parameter.
    router.get("b/{slug}/guest") { _, context in
        let slug = try context.parameters.require("slug")
        guard let record = await trips.record(slug: slug) else { throw APIError.notFound("No book.") }
        return try APIJSON.response(await trips.activity(record.id))
    }

    router.post("b/{slug}/guest/hearts") { request, context in
        let slug = try context.parameters.require("slug")
        guard let record = await trips.record(slug: slug) else { throw APIError.notFound("No book.") }
        let body = try await request.decode(as: HeartBody.self, context: context)
        let book = try TripBook.load(from: await trips.bookFolder(record.id))
        guard book.allPhotos.contains(where: { $0.id.description == body.photo }) else { throw APIError.invalid("No such photo.") }
        let activity = try await trips.changeActivity(record.id) { $0.hearts[body.photo, default: 0] += 1 }
        return try APIJSON.response(activity)
    }

    router.post("b/{slug}/guest/notes") { request, context in
        let slug = try context.parameters.require("slug")
        guard let record = await trips.record(slug: slug) else { throw APIError.notFound("No book.") }
        let body = try await request.decode(as: NoteBody.self, context: context)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !text.isEmpty, name.count <= TripLimits.nameLength, text.count <= TripLimits.noteLength else {
            throw APIError.invalid("Add a name and a note under \(TripLimits.noteLength) characters.")
        }
        let activity = try await trips.changeActivity(record.id) { activity in
            guard activity.notes.count < TripLimits.notes else { throw APIError.conflict("This book's guestbook is full.") }
            activity.notes.append(.init(name: name, text: text, date: Date()))
        }
        return try APIJSON.response(activity, status: .created)
    }

    router.put("b/{slug}/guest/photos/{name}") { request, context in
        let slug = try context.parameters.require("slug")
        let name = try context.parameters.require("name")
        guard let record = await trips.record(slug: slug) else { throw APIError.notFound("No book.") }
        let buffer = try await request.body.collect(upTo: TripLimits.uploadBytes)
        let url = try await trips.store(photo: Data(buffer: buffer), name: name, id: record.id, guest: true)
        let count = (try? FileManager.default.contentsOfDirectory(atPath: await trips.guestFolder(record.id).path).count) ?? 0
        return try APIJSON.response(UploadDTO(stored: url.lastPathComponent, count: count), status: .created)
    }
}

private func bookFile(trips: TripStore, slug: String, relative: String) async throws -> Response {
    guard let record = await trips.record(slug: slug) else { throw APIError.notFound("No book.") }
    let parts = relative.split(separator: "/")
    guard !parts.isEmpty, parts.allSatisfy({ $0 != ".." && $0 != "." && !$0.hasPrefix(".") }) else { throw APIError.notFound("Not found.") }
    let allowed = ["html", "jpg", "txt"]
    let ext = (relative as NSString).pathExtension.lowercased()
    guard allowed.contains(ext) else { throw APIError.notFound("Not found.") }
    let root = await trips.bookFolder(record.id).standardizedFileURL
    let url = root.appendingPathComponent(relative).standardizedFileURL
    guard url.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: url) else { throw APIError.notFound("Not found.") }
    var headers = HTTPFields()
    headers[.contentType] = ext == "html" ? "text/html; charset=utf-8" : (ext == "jpg" ? "image/jpeg" : "text/plain; charset=utf-8")
    headers[.cacheControl] = ext == "jpg" ? "public, max-age=86400" : "no-cache"
    headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
    if ext == "html" {
        headers[HTTPField.Name("Content-Security-Policy")!] = "default-src 'self'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'"
    }
    return APIJSON.bytes(data, headers: headers)
}
