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
    var note: String?
    var calendarEvents: [String]?
    var tone: String?
    var theme: String?
    var ownerName: String?
    /// The phone's install ID, kept for counting phones.
    var installID: String?
    /// Where to send the owner reminders and the book link; empty clears it.
    var ownerEmail: String?
}

struct PlanBody: Decodable, Sendable {
    /// A StoreKit 2 signed transaction (JWS).
    var transaction: String
}

struct PlanDTO: Encodable, Sendable {
    var plan: Plan
    var limits: PlanLimits
    var hostedUntil: Date?
    var subscriptionExpires: Date?
}

struct InviteBody: Decodable, Sendable {
    var open: Bool
}

struct JoinBody: Decodable, Sendable {
    var name: String
    /// Optional: to hear when the book is ready, and before it goes offline.
    var email: String?
}

struct EmailBody: Decodable, Sendable {
    var email: String?
}

struct ShiftBody: Decodable, Sendable {
    var days: Double
}

struct JoinedDTO: Encodable, Sendable {
    var name: String
    var token: String
}

struct ContributorDTO: Encodable, Sendable {
    var name: String
    var photos: Int
}

/// What the invite page shows. `me` and `mine` are present only for the person
/// whose token came with the request.
struct InviteStatusDTO: Encodable, Sendable {
    var title: String?
    var open: Bool
    var people: Int
    var photos: Int
    var bookPath: String?
    var me: String?
    var mine: Int?
    /// Whether this person gave an email.
    var emailSet: Bool?
}

struct TripCreatedDTO: Encodable, Sendable {
    var id: String
    var slug: String
    var ownerToken: String
    var bookPath: String
    var editPath: String
    var invitePath: String?
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
    var invitePath: String?
    var inviteOpen: Bool
    var contributors: [ContributorDTO]
    var plan: Plan
    var limits: PlanLimits
    var hostedUntil: Date?
    /// Always true: every book is free to make. Kept for older apps.
    var freeBookAvailable: Bool
    var printInterest: Int
    /// Friends' photos added since the book was last made.
    var newSinceFinish: Int
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
    var guestOverBudget: Int?
    var contributors: [String: Int]?
}

/// What this server can sell from a book page.
struct PageFeatures: Sendable {
    /// Keeping a book from its page (needs web payments).
    var keep: Bool
    /// Ordering printed copies (needs web payments and a printer).
    var prints: Bool

    static let none = PageFeatures(keep: false, prints: false)
}

enum TripPaths {
    static func book(_ slug: String) -> String { "/b/\(slug)/" }
    static func invite(_ record: TripRecord) -> String? { record.inviteCode.map { "/j/\($0)" } }
    /// What the page offers follows the plan: editing, downloads and no footer
    /// are paid; a free book shows when it goes offline and how to keep it.
    static func options(_ record: TripRecord, siteURL: String?, features: PageFeatures = .none, now: Date = Date()) -> BookRenderer.Options {
        let limits = record.limits
        let free = record.currentPlan == .free
        return BookRenderer.Options(
            editEndpoint: limits.editing ? "/b/\(record.slug)/edits" : nil,
            guestEndpoint: "/b/\(record.slug)/guest",
            invitePath: record.inviteOpen ? invite(record) : nil,
            printInterestEndpoint: features.prints ? nil : "/b/\(record.slug)/print-interest",
            footer: limits.branded ? BookRenderer.Options.freeFooter : "",
            footerLink: limits.branded ? siteURL : nil,
            keepEndpoint: features.keep && free && record.purgedAt == nil ? "/b/\(record.slug)/keep" : nil,
            hostedUntil: free ? (record.hostedUntil ?? now.addingTimeInterval(PlanPolicy.freeHosting)) : nil,
            downloadPath: limits.download ? "/b/\(record.slug)/photos.zip" : nil,
            printOrderEndpoint: features.prints ? "/b/\(record.slug)/print" : nil,
            makeOnePath: "/b/\(record.slug)/make"
        )
    }

    /// Writes a finished book's page again, for a new plan or setting.
    static func rerender(_ record: TripRecord, trips: TripStore, options: BookRenderer.Options) async {
        guard record.finishedAt != nil, record.purgedAt == nil else { return }
        let folder = await trips.bookFolder(record.id)
        guard let book = try? TripBook.load(from: folder) else { return }
        let edits = BookEdits.load(from: folder)
        try? Data(BookRenderer.html(edits.applied(to: book), options: options).utf8)
            .write(to: folder.appendingPathComponent("index.html"), options: .atomic)
    }
}

/// An optional email from a form: nil when empty, refused when it isn't an address.
private func optionalEmail(_ raw: String?) throws -> String?? {
    guard let raw else { return .none }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .some(nil) }
    guard Mailers.isAddress(trimmed) else { throw APIError.invalid("That email doesn't look right.") }
    return .some(trimmed)
}

private func ensureHosted(_ record: TripRecord) throws {
    guard record.isHosted() else { throw APIError.gone("This book is no longer online.") }
}

/// The contributor token sent by the invite page.
private func contributorToken(_ request: Request) -> String? {
    request.headers[HTTPField.Name("X-Photocore-Contributor")!]
}

func registerTripRoutes(
    _ router: Router<BasicRequestContext>,
    env: ServerEnvironment,
    trips: TripStore,
    storeKit: StoreKitVerifier,
    lifecycle: BookLifecycle,
    address: PublicAddress,
    payments: (any PaymentProvider)?,
    printing: PrintFulfillment?
) {
    let printsEnabled = printing != nil
    let siteURL = env.configuration.siteURL
    let features = PageFeatures(keep: payments != nil, prints: payments != nil && printsEnabled)
    @Sendable func pageOptions(_ record: TripRecord) -> BookRenderer.Options {
        TripPaths.options(record, siteURL: siteURL, features: features)
    }
    // MARK: Owner API (server token)

    router.post("v2/trips") { request, context in
        let body = try await request.decode(as: CreateTripBody.self, context: context)
        let tone = DiaryTone(rawValue: body.tone ?? "warm") ?? .warm
        let theme = BookTheme(name: body.theme ?? "book") ?? .book
        let title = body.title.map { String($0.prefix(120)) }
        let ownerName = body.ownerName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : String($0.prefix(TripLimits.nameLength)) }
        let context = TripContext(
            note: body.note.map { String($0.prefix(280)) },
            calendarEvents: (body.calendarEvents ?? []).prefix(5).map { String($0.prefix(120)) }
        )
        let installID = body.installID.map { String($0.prefix(64)) }
        let ownerEmail = try optionalEmail(body.ownerEmail)
        let (record, token) = try await trips.create(title: title, context: context, tone: tone, theme: theme, ownerName: ownerName, installID: installID)
        if case .some(let email?) = ownerEmail { try await trips.setOwnerEmail(record.id, email: email) }
        let dto = TripCreatedDTO(id: record.id, slug: record.slug, ownerToken: token, bookPath: TripPaths.book(record.slug), editPath: TripPaths.book(record.slug) + "#edit=" + token, invitePath: TripPaths.invite(record))
        return try APIJSON.response(dto, status: .created)
    }

    router.get("v2/trips/{tid}") { _, context in
        let tid = try context.parameters.require("tid")
        guard let record = await trips.record(id: tid) else { throw APIError.notFound("No trip \(tid)") }
        let owner = await trips.photoCount(await trips.ownerFolder(tid))
        let guests = await trips.photoCount(await trips.guestFolder(tid)) + (await trips.contributedCount(tid))
        var people: [ContributorDTO] = []
        for person in await trips.contributors(tid) {
            people.append(ContributorDTO(name: person.name, photos: await trips.photoCount(await trips.contributorFolder(tid, person.id))))
        }
        return try APIJSON.response(TripDTO(
            id: record.id, slug: record.slug, ownerPhotos: owner, guestPhotos: guests,
            finishedAt: record.finishedAt, lastJobID: record.lastJobID, writer: record.bookWriter,
            bookPath: TripPaths.book(record.slug), invitePath: TripPaths.invite(record),
            inviteOpen: record.inviteOpen, contributors: people,
            plan: record.currentPlan, limits: record.limits, hostedUntil: record.hostedUntil,
            freeBookAvailable: await trips.freeBookAvailable(record), printInterest: record.printInterest ?? 0,
            newSinceFinish: await trips.newSinceFinish(tid)
        ))
    }

    /// Puts a verified App Store purchase on the trip: Plus, a Trip Pass or an Event Pass.
    router.post("v2/trips/{tid}/plan") { request, context in
        let tid = try context.parameters.require("tid")
        guard await trips.record(id: tid) != nil else { throw APIError.notFound("No trip \(tid)") }
        let body = try await request.decode(as: PlanBody.self, context: context)
        let transaction: SignedTransaction
        do {
            transaction = try storeKit.verify(body.transaction)
        } catch let error as StoreKitError {
            throw error == .expired ? APIError.paymentRequired(error.description) : APIError.invalid(error.description)
        }
        let record = try await trips.apply(transaction, to: tid)
        // Re-render a finished book so its page matches the plan at once.
        await TripPaths.rerender(record, trips: trips, options: pageOptions(record))
        return try APIJSON.response(PlanDTO(plan: record.currentPlan, limits: record.limits, hostedUntil: record.hostedUntil, subscriptionExpires: record.subscriptionExpires))
    }

    /// The finished book as a print-ready PDF (8 x 8 inch pages with bleed).
    router.get("v2/trips/{tid}/print.pdf") { _, context in
        let tid = try context.parameters.require("tid")
        guard let record = await trips.record(id: tid), record.finishedAt != nil else { throw APIError.notFound("Finish the book first.") }
        let folder = await trips.bookFolder(tid)
        let book = BookEdits.load(from: folder).applied(to: try TripBook.load(from: folder))
        let output = await trips.folder(tid).appendingPathComponent("work/print.pdf")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try BookPrinter.pdf(book: book, folder: folder, to: output, options: .init(footer: record.limits.branded ? BookRenderer.Options.freeFooter : nil))
        var headers = HTTPFields()
        headers[.contentType] = "application/pdf"
        headers[.contentDisposition] = "attachment; filename=\"book.pdf\""
        headers[.cacheControl] = "no-store"
        return APIJSON.bytes(try Data(contentsOf: output), headers: headers)
    }

    /// Updates what the owner chose after inviting people: title, note, tone,
    /// style and name. Only fields that are present change.
    router.post("v2/trips/{tid}/settings") { request, context in
        let tid = try context.parameters.require("tid")
        guard await trips.record(id: tid) != nil else { throw APIError.notFound("No trip \(tid)") }
        let body = try await request.decode(as: CreateTripBody.self, context: context)
        if case .some(let email) = try optionalEmail(body.ownerEmail) { try await trips.setOwnerEmail(tid, email: email) }
        if let theme = body.theme.flatMap({ BookTheme(name: $0) }), let record = await trips.record(id: tid), !record.limits.allows(theme) {
            throw APIError.paymentRequired("\(theme.displayName) comes with a Trip Pass.")
        }
        try await trips.update(tid) { record in
            if let title = body.title { record.title = String(title.prefix(120)) }
            if let tone = body.tone.flatMap(DiaryTone.init(rawValue:)) { record.tone = tone }
            if let theme = body.theme.flatMap({ BookTheme(name: $0) }) { record.theme = theme }
            if let name = body.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines) {
                record.ownerName = name.isEmpty ? nil : String(name.prefix(TripLimits.nameLength))
            }
            if body.note != nil || body.calendarEvents != nil {
                var context = record.context ?? .empty
                if let note = body.note { context.note = note.isEmpty ? nil : String(note.prefix(280)) }
                if let events = body.calendarEvents { context.calendarEvents = events.prefix(5).map { String($0.prefix(120)) } }
                record.context = context
            }
        }
        return try APIJSON.response(["ok": true])
    }

    /// Opens or closes the invite link. Photos already added stay.
    router.post("v2/trips/{tid}/invite") { request, context in
        let tid = try context.parameters.require("tid")
        guard await trips.record(id: tid)?.inviteCode != nil else { throw APIError.notFound("No invite for trip \(tid)") }
        let body = try await request.decode(as: InviteBody.self, context: context)
        try await trips.update(tid) { $0.inviteClosed = !body.open }
        return try APIJSON.response(["open": body.open])
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
        let total = await trips.photoCount(ownerFolder) + (await trips.photoCount(await trips.guestFolder(tid))) + (await trips.contributedCount(tid))
        guard total > 0 else {
            throw APIError.precondition("Add some photos before finishing.")
        }
        try ensureHosted(record)
        let limits = record.limits
        let theme = limits.allows(record.theme) ? record.theme : .book
        var contributors = [TripFinisher.Contributor(name: nil, folder: await trips.guestFolder(tid))]
        for person in await trips.contributors(tid) {
            contributors.append(TripFinisher.Contributor(name: person.name, folder: await trips.contributorFolder(tid, person.id)))
        }
        let job = JobRecord(id: UUID().uuidString, kind: "finish-trip", sessionID: nil, state: "queued", request: Data("{\"trip\":\"\(tid)\"}".utf8), createdAt: Date())
        let folders = TripFinisher.Folders(
            owner: ownerFolder,
            contributors: contributors,
            book: await trips.bookFolder(tid),
            work: await trips.folder(tid).appendingPathComponent("work", isDirectory: true)
        )
        let jobs = env.jobs
        let stored = try await env.jobs.enqueue(job) {
            try await trips.update(tid) { $0.finishStartedAt = Date() }
            let writer = DiaryWriters.make()
            let outcome = try await TripFinisher.finish(
                folders: folders,
                title: record.title,
                context: record.context ?? .empty,
                tone: record.tone,
                theme: theme,
                ownerName: record.ownerName,
                writer: writer,
                options: pageOptions(record),
                lookUpPlaces: ProcessInfo.processInfo.environment["PHOTOCORE_OFFLINE"] != "1",
                instagram: limits.instagram
            ) { stage, done, total in
                Task { await jobs.noteProgress(id: job.id, stage: "finish", completed: done, total: total, message: stage) }
            }
            try await trips.saveSources(tid, outcome.sources)
            // Friends' photos that weren't picked are deleted now; only the book's stay.
            await trips.deleteUnpicked(tid, considered: outcome.considered, picked: outcome.sources.map(\.url))
            let firstFinish = await trips.record(id: tid)?.finishedAt == nil
            try await trips.update(tid) {
                let first = $0.finishedAt ?? Date()
                $0.finishedAt = Date()
                $0.bookWriter = outcome.book.writer
                $0.hostedUntil = PlanPolicy.hostedUntil(plan: $0.currentPlan, firstFinished: first, subscriptionExpires: $0.subscriptionExpires)
            }
            if firstFinish {
                // Friends who gave an email hear the book is ready, once.
                let title = record.title.flatMap { $0.isEmpty ? nil : $0 } ?? outcome.book.title
                let bookURL = address.base + TripPaths.book(record.slug)
                let friends = await trips.recipients(tid).filter { $0.contributorID != nil }
                _ = await lifecycle.send({ recipient in
                    MailTemplates.bookReady(to: recipient.email, name: recipient.name, title: title, yours: recipient.name.flatMap { outcome.keptPerContributor[$0] } ?? 0, bookURL: bookURL, youURL: nil, unsubscribe: address.base + "/u/" + recipient.unsubscribeToken)
                }, to: friends)
            }
            return try APIJSON.data(FinishResult(
                bookPath: TripPaths.book(record.slug),
                photos: outcome.report.photoCount,
                chapters: outcome.book.sections.count,
                writer: outcome.book.writer,
                guestKept: outcome.guestKept,
                guestDuplicates: outcome.guestDuplicates,
                guestOverBudget: outcome.guestOverBudget,
                contributors: outcome.keptPerContributor
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
        guard record.limits.editing else { throw APIError.paymentRequired("Editing the words comes with a Trip Pass.") }
        let body = try await request.decode(as: EditBody.self, context: context)
        do {
            try TripFinisher.applyEdit(key: body.key, value: body.value, bookFolder: await trips.bookFolder(record.id), options: pageOptions(record))
        } catch TripFinisher.EditError.notEditable {
            throw APIError.invalid("That part of the book can't be edited.")
        } catch TripFinisher.EditError.tooLong {
            throw APIError.invalid("Keep it under \(BookEdits.maximumLength) characters.")
        }
        return try APIJSON.response(["ok": true])
    }

    /// "Make one for your trip": counts the tap by platform, then sends iPhone
    /// visitors to the App Store and everyone else to the web.
    router.get("b/{slug}/make") { request, context in
        let slug = try context.parameters.require("slug")
        guard await trips.record(slug: slug) != nil else { throw APIError.notFound("No book.") }
        let platform = TripStore.platform(userAgent: request.headers[.userAgent])
        try? await trips.noteMakeOne(platform: platform)
        var headers = HTTPFields()
        headers[.location] = platform == "ios" ? (env.configuration.appStoreURL ?? "/new") : "/new"
        headers[.cacheControl] = "no-store"
        return Response(status: .found, headers: headers)
    }

    /// Make-one taps by platform and month.
    router.get("v2/metrics/growth") { _, _ in
        try APIJSON.response(await trips.growth())
    }

    /// Everyone's full-size photos in a kept book, as one zip.
    router.get("b/{slug}/photos.zip") { _, context in
        let slug = try context.parameters.require("slug")
        guard let record = await trips.record(slug: slug) else { throw APIError.notFound("No book.") }
        try ensureHosted(record)
        guard record.limits.download else { throw APIError.paymentRequired("Downloading everyone's photos comes with keeping the book.") }
        let zip = try await trips.download(record.id)
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        let title = (record.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Bound").filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
        var headers = HTTPFields()
        headers[.contentType] = "application/zip"
        headers[.contentLength] = String(size)
        headers[.contentDisposition] = "attachment; filename=\"\(title) photos.zip\""
        headers[.cacheControl] = "private, no-store"
        return Response(status: .ok, headers: headers, body: try await FileIO().loadFile(path: zip.path, context: context))
    }

    router.post("b/{slug}/print-interest") { _, context in
        let slug = try context.parameters.require("slug")
        guard let record = await trips.record(slug: slug) else { throw APIError.notFound("No book.") }
        try ensureHosted(record)
        return try APIJSON.response(["count": try await trips.notePrintInterest(record.id)])
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

    // MARK: Web purchases (Stripe, or the test checkout)

    /// Applies a paid checkout: the plan and a fresh page for passes, an order
    /// for prints. Safe to call twice for the same checkout.
    @Sendable func complete(_ completion: CheckoutCompletion) async throws {
        let (record, changed) = try await trips.applyWeb(completion)
        guard changed else { return }
        switch completion.kind {
        case .keep, .event:
            await TripPaths.rerender(record, trips: trips, options: pageOptions(record))
            let title = record.title.flatMap { $0.isEmpty ? nil : $0 } ?? "your trip"
            let bookURL = address.base + TripPaths.book(record.slug)
            let buyer = completion.email?.lowercased()
            let others = await trips.recipients(record.id).filter { $0.email.lowercased() != buyer }
            _ = await lifecycle.send({ MailTemplates.kept(to: $0.email, title: title, bookURL: bookURL, keptBy: record.keptBy) }, to: others)
        case .print:
            await lifecycle.printOrdersChanged()
        }
    }

    /// Starts a checkout for something on a book's page.
    @Sendable func checkout(_ kind: CheckoutKind, record: TripRecord, product: PrintProduct? = nil, returnTo: String? = nil) async throws -> Response {
        guard let payments else { throw APIError.busy("Payments aren't set up on this server yet.") }
        let cents: Int
        switch kind {
        case .keep: cents = WebPrice.tripPass
        case .event: cents = WebPrice.eventPass
        case .print: cents = product?.cents ?? 0
        }
        let book = address.base + TripPaths.book(record.slug)
        let request = CheckoutRequest(
            kind: kind, tripID: record.id, slug: record.slug,
            title: record.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Our trip",
            cents: cents, product: product,
            successURL: address.base + "/b/\(record.slug)/thanks?kind=\(kind.rawValue)",
            cancelURL: returnTo.map { address.base + $0 } ?? book
        )
        let session = try await payments.createCheckout(request)
        return try APIJSON.response(["url": session.url, "id": session.id])
    }

    /// "Keep it for $4.99": anyone with the book link can keep a free book,
    /// including after it went offline, until its photos are deleted.
    router.post("b/{slug}/keep") { _, context in
        let slug = try context.parameters.require("slug")
        guard let record = await trips.record(slug: slug) else { throw APIError.notFound("No book.") }
        guard record.purgedAt == nil else { throw APIError.gone("This book's photos have been deleted.") }
        guard record.currentPlan == .free else { throw APIError.conflict("This book is already kept.") }
        return try await checkout(.keep, record: record)
    }

    struct PrintBody: Decodable { var product: String }

    /// A printed copy for whoever asks, shipped to them.
    router.post("b/{slug}/print") { request, context in
        let slug = try context.parameters.require("slug")
        guard let record = await trips.record(slug: slug), record.finishedAt != nil else { throw APIError.notFound("No book.") }
        try ensureHosted(record)
        guard features.prints else { throw APIError.busy("Printed copies aren't available yet.") }
        let body = try await request.decode(as: PrintBody.self, context: context)
        guard let product = PrintProduct(rawValue: body.product) else { throw APIError.invalid("Pick softcover or hardcover.") }
        return try await checkout(.print, record: record, product: product)
    }

    router.get("b/{slug}/thanks") { request, context in
        let slug = try context.parameters.require("slug")
        guard let record = await trips.record(slug: slug) else { throw APIError.notFound("No book.") }
        let kind = queryValue(request, "kind").flatMap(CheckoutKind.init(rawValue:)) ?? .keep
        return Pages.response(Pages.thanks(kind: kind, title: record.title, bookPath: TripPaths.book(record.slug)))
    }

    /// Stripe's webhook. Only signed events are read; anything but a paid
    /// checkout is acknowledged and ignored.
    router.post("stripe/webhook") { request, _ in
        guard let secret = env.configuration.stripeWebhookSecret, !secret.isEmpty else { throw APIError.notFound("Not found.") }
        let payload = Data(buffer: try await request.body.collect(upTo: 1_024 * 1_024))
        guard StripeWebhook.verify(payload: payload, header: request.headers[HTTPField.Name("Stripe-Signature")!], secret: secret) else {
            throw APIError.invalid("Bad signature.")
        }
        if let completion = StripeWebhook.completion(from: payload) {
            try await complete(completion)
        }
        return try APIJSON.response(["received": true])
    }

    /// The test checkout's page: no card, one button, and an address for prints.
    router.get("checkout/dev/{id}") { _, context in
        guard let dev = payments as? DevPayments else { throw APIError.notFound("Not found.") }
        let id = try context.parameters.require("id")
        guard let pending = await dev.request(id) else { throw APIError.notFound("This checkout has ended.") }
        return Pages.response(Pages.devCheckout(pending))
    }

    router.post("checkout/dev/{id}") { request, context in
        guard let dev = payments as? DevPayments else { throw APIError.notFound("Not found.") }
        let id = try context.parameters.require("id")
        let form = FormFields(Data(buffer: try await request.body.collect(upTo: 64 * 1_024)))
        guard let pending = await dev.take(id) else { throw APIError.notFound("This checkout has ended.") }
        var shipping: ShippingAddress?
        if pending.kind == .print {
            shipping = ShippingAddress(
                name: form["name"] ?? "", line1: form["line1"] ?? "", line2: form["line2"], city: form["city"] ?? "",
                state: form["state"], postalCode: form["postal"] ?? "", country: (form["country"] ?? "US").uppercased()
            )
        }
        try await complete(CheckoutCompletion(
            sessionID: id, kind: pending.kind, tripID: pending.tripID, product: pending.product,
            email: form["email"].flatMap { $0.isEmpty ? nil : $0 }, name: form["name"], shipping: shipping, cents: pending.cents,
            phone: form["phone"].flatMap { $0.isEmpty ? nil : $0 }
        ))
        var headers = HTTPFields()
        headers[.location] = pending.successURL
        return Response(status: .seeOther, headers: headers)
    }

    /// The interior and cover PDFs, for the printer to fetch by their secret link.
    router.get("p/{token}/{name}") { _, context in
        guard let printing else { throw APIError.notFound("Not found.") }
        let token = try context.parameters.require("token")
        let name = try context.parameters.require("name")
        guard let url = await printing.file(token: token, name: name) else { throw APIError.notFound("Not found.") }
        var headers = HTTPFields()
        headers[.contentType] = "application/pdf"
        headers[.cacheControl] = "private, no-store"
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        return APIJSON.bytes(try Data(contentsOf: url), headers: headers)
    }

    // MARK: Emails (one-click unsubscribe, no account)

    router.get("u/{token}") { _, context in
        let token = try context.parameters.require("token")
        guard let record = await trips.unsubscribeTarget(token) else { throw APIError.notFound("This link doesn't work.") }
        return Pages.response(Pages.unsubscribe(title: record.title, done: false))
    }

    router.post("u/{token}") { _, context in
        let token = try context.parameters.require("token")
        guard let record = try await trips.unsubscribe(token) else { throw APIError.notFound("This link doesn't work.") }
        return Pages.response(Pages.unsubscribe(title: record.title, done: true))
    }

    // MARK: Operations (server token)

    /// Runs the lifecycle now: reminders, purges and the rest.
    router.post("v2/admin/lifecycle") { _, _ in
        try APIJSON.response(await lifecycle.tick())
    }

    /// Every print order, newest last.
    router.get("v2/admin/orders") { _, _ in
        try APIJSON.response(await trips.orders())
    }

    /// Moves a trip back in time, only when the server allows it (the checks).
    router.post("v2/admin/trips/{tid}/shift") { request, context in
        guard env.configuration.allowClockShift else { throw APIError.notFound("Not found.") }
        let tid = try context.parameters.require("tid")
        let body = try await request.decode(as: ShiftBody.self, context: context)
        try await trips.shift(tid, by: body.days * 86_400)
        return try APIJSON.response(["ok": true])
    }

    // MARK: Invite link (no server token; each person gets their own token)

    router.get("j/{code}") { _, context in
        let code = try context.parameters.require("code")
        guard let record = await trips.record(invite: code) else { throw APIError.notFound("This invite link doesn't work.") }
        var headers = HTTPFields()
        headers[.contentType] = "text/html; charset=utf-8"
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        headers[HTTPField.Name("Referrer-Policy")!] = "no-referrer"
        headers[HTTPField.Name("Content-Security-Policy")!] = "default-src 'self'; img-src 'self' data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'"
        var cover: String?
        if record.finishedAt != nil, record.isHosted(), let book = try? TripBook.load(from: await trips.bookFolder(record.id)),
           let photo = book.allPhotos.first(where: { $0.id == book.coverPhotoID }) ?? book.allPhotos.first {
            cover = TripPaths.book(record.slug) + BookRenderer.photoPath(photo)
        }
        return APIJSON.bytes(Data(InvitePage.html(code: code, title: record.title, ownerName: record.ownerName, cover: cover).utf8), headers: headers)
    }

    router.get("j/{code}/status") { request, context in
        let code = try context.parameters.require("code")
        guard let record = await trips.record(invite: code) else { throw APIError.notFound("This invite link doesn't work.") }
        let person = await trips.contributor(record.id, token: contributorToken(request))
        var mine: Int?
        if let person { mine = await trips.photoCount(await trips.contributorFolder(record.id, person.id)) }
        let status = InviteStatusDTO(
            title: record.title,
            open: record.inviteOpen,
            people: await trips.contributors(record.id).count,
            photos: await trips.contributedCount(record.id),
            bookPath: record.finishedAt == nil ? nil : TripPaths.book(record.slug),
            me: person?.name,
            mine: mine,
            emailSet: person.map { $0.email != nil }
        )
        return try APIJSON.response(status)
    }

    router.post("j/{code}/join") { request, context in
        let code = try context.parameters.require("code")
        guard let record = await trips.record(invite: code) else { throw APIError.notFound("This invite link doesn't work.") }
        guard record.inviteOpen else { throw APIError.forbidden("This trip isn't taking photos any more.") }
        let body = try await request.decode(as: JoinBody.self, context: context)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= TripLimits.nameLength else { throw APIError.invalid("Add a name under \(TripLimits.nameLength) characters.") }
        guard await trips.contributors(record.id).count < record.limits.friends else {
            throw APIError.conflict("This book is full: it has room for \(record.limits.friends) people. Ask the person who invited you to make room.")
        }
        let email = try optionalEmail(body.email) ?? nil
        let (person, token) = try await trips.join(record.id, name: name, email: email)
        return try APIJSON.response(JoinedDTO(name: person.name, token: token), status: .created)
    }

    /// A person adds, changes or removes their email.
    router.post("j/{code}/email") { request, context in
        let code = try context.parameters.require("code")
        guard let record = await trips.record(invite: code) else { throw APIError.notFound("This invite link doesn't work.") }
        guard let person = await trips.contributor(record.id, token: contributorToken(request)) else {
            throw APIError.unauthorized("Join the trip first.")
        }
        let body = try await request.decode(as: EmailBody.self, context: context)
        let email = try optionalEmail(body.email ?? "") ?? nil
        try await trips.setEmail(record.id, contributor: person.id, email: email)
        return try APIJSON.response(["emailSet": email != nil])
    }

    router.put("j/{code}/photos/{name}") { request, context in
        let code = try context.parameters.require("code")
        let name = try context.parameters.require("name")
        guard let record = await trips.record(invite: code) else { throw APIError.notFound("This invite link doesn't work.") }
        guard record.inviteOpen else { throw APIError.forbidden("This trip isn't taking photos any more.") }
        guard let person = await trips.contributor(record.id, token: contributorToken(request)) else {
            throw APIError.unauthorized("Join the trip before adding photos.")
        }
        let buffer = try await request.body.collect(upTo: TripLimits.uploadBytes)
        let url = try await trips.store(photo: Data(buffer: buffer), name: name, id: record.id, contributor: person)
        let count = await trips.photoCount(await trips.contributorFolder(record.id, person.id))
        return try APIJSON.response(UploadDTO(stored: url.lastPathComponent, count: count), status: .created)
    }

    router.delete("j/{code}/photos") { request, context in
        let code = try context.parameters.require("code")
        guard let record = await trips.record(invite: code) else { throw APIError.notFound("This invite link doesn't work.") }
        guard let person = await trips.contributor(record.id, token: contributorToken(request)) else {
            throw APIError.unauthorized("Only the person who added these photos can remove them.")
        }
        let removed = try await trips.removePhotos(record.id, contributor: person)
        return try APIJSON.response(["removed": removed])
    }
}

private func bookFile(trips: TripStore, slug: String, relative: String) async throws -> Response {
    guard let record = await trips.record(slug: slug) else { throw APIError.notFound("No book.") }
    if !record.isHosted() {
        guard relative == "index.html" else { throw APIError.gone("This book is no longer online.") }
        let book = try? TripBook.load(from: await trips.bookFolder(record.id))
        let title = record.title.flatMap { $0.isEmpty ? nil : $0 } ?? book?.title ?? "This book"
        let canKeep = record.purgedAt == nil && record.currentPlan == .free
        return Pages.response(Pages.offline(title: title, credit: book?.creditLine, keepEndpoint: canKeep ? "/b/\(record.slug)/keep" : nil), status: .gone)
    }
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
        headers[HTTPField.Name("Content-Security-Policy")!] = "default-src 'self'; img-src 'self' data: blob:; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; script-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'"
    }
    return APIJSON.bytes(data, headers: headers)
}
