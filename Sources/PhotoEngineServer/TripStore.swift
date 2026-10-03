import CryptoKit
import Foundation
import PhotoEngineCore
import PhotoEngineWorkflow

/// One paid "finish the trip" order: keepers uploaded by the owner, photos
/// added by guests, and the published book.
struct TripRecord: Codable, Sendable {
    var id: String
    var slug: String
    var ownerTokenHash: String
    var title: String?
    var context: TripContext?
    var tone: DiaryTone
    var theme: BookTheme
    var createdAt: Date
    var finishedAt: Date?
    var lastJobID: String?
    var bookWriter: String?
    /// The owner's name for photo credits, when they gave one.
    var ownerName: String?
    /// The secret in the invite link that lets people who were there add photos.
    var inviteCode: String?
    var inviteClosed: Bool?
    /// What the owner paid for; nil is the free plan.
    var plan: Plan?
    /// The pass spent on this book, or the Plus subscription's original transaction.
    var planTransactionID: String?
    var subscriptionExpires: Date?
    /// When the book stops being served; nil for never.
    var hostedUntil: Date?
    /// SHA-256 of the phone's install ID, for the one free book per phone.
    var installHash: String?
    /// Visitors who tapped "I'd love a printed copy".
    var printInterest: Int?
    /// Where to send the owner reminders and updates, if they gave an address.
    var ownerEmail: String?
    /// The owner's one-click unsubscribe token (`<trip id>.<secret>`).
    var ownerMailToken: String?
    var ownerUnsubscribed: Bool?
    /// Which of `PlanPolicy.reminders` have gone out.
    var remindersSent: [Int]?
    /// When an offline free book's photos were deleted.
    var purgedAt: Date?
    /// The first name of whoever kept the book on the web, for the thank-you.
    var keptBy: String?
    /// When the latest finish began reading photos.
    var finishStartedAt: Date?

    var inviteOpen: Bool { inviteCode != nil && inviteClosed != true }
    var currentPlan: Plan { plan ?? .free }
    var limits: PlanLimits { currentPlan.limits }

    func isHosted(at date: Date = Date()) -> Bool { hostedUntil.map { date < $0 } ?? true }
}

/// Which purchases have been spent, so a pass covers one book and Yearly
/// covers twelve a year.
struct EntitlementLedger: Codable, Sendable {
    /// Pass transaction ID to the trip it was spent on.
    var passes: [String: String] = [:]
    /// Plus original transaction ID to trip IDs and when each was started.
    var plusBooks: [String: [String: Date]] = [:]
    /// Web checkout sessions already applied, to the trip they were for, so a
    /// repeated webhook never applies twice.
    var webSessions: [String: String]? = [:]
    /// Install hash to the trip that used the free book, from when each phone
    /// had one free book. No longer enforced; kept so old ledgers still load.
    var freeBooks: [String: String] = [:]
}

/// Someone who joined through the invite link. Their token lets them add and
/// remove their own photos and nothing else.
struct Contributor: Codable, Sendable {
    var id: String
    var name: String
    var tokenHash: String
    var joinedAt: Date
    /// Where to send "the book is ready" and reminders, if they gave an address.
    var email: String?
    /// Their one-click unsubscribe token (`<trip id>.<secret>`).
    var mailToken: String?
    var unsubscribed: Bool?
    /// Embeddings of the faces they tapped as theirs, so the taps survive a
    /// refinish. Only used inside this book.
    var tappedFaces: [Data]?
    /// Book photo file names they said they're not in.
    var notMe: [String]?
}

/// Someone to email about a book.
struct Recipient: Sendable, Equatable {
    var email: String
    var name: String?
    var unsubscribeToken: String
    /// Nil for the owner.
    var contributorID: String?
}

/// Guest activity on a published book.
struct GuestActivity: Codable, Sendable {
    struct Note: Codable, Sendable {
        var name: String
        var text: String
        var date: Date
    }

    var notes: [Note] = []
    var hearts: [String: Int] = [:]
}

enum TripLimits {
    /// The phone culls first, so a paid order is keepers only.
    static let ownerPhotos = 400
    static let guestPhotos = 200
    static let uploadBytes = 60 * 1_024 * 1_024
    static let notes = 500
    static let noteLength = 500
    static let nameLength = 40
    /// The most any plan allows; each plan's own limits are lower or equal.
    static let contributors = 100
    static let photosPerContributor = 300
}

/// Trips live on disk under the worker's output root, one folder each:
/// `trip.json`, `owner/`, `guests/`, `book/`, `guest.json`, and for group
/// trips `contributors.json` with one `contributors/<id>/` folder per person.
actor TripStore {
    let root: URL
    private var records: [String: TripRecord] = [:]
    private var slugs: [String: String] = [:]
    private var guest: [String: GuestActivity] = [:]
    private var invites: [String: String] = [:]
    private var people: [String: [Contributor]] = [:]
    private var ledger = EntitlementLedger()

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("trip.json")),
                  let record = try? decoder.decode(TripRecord.self, from: data) else { continue }
            records[record.id] = record
            slugs[record.slug] = record.id
            if let code = record.inviteCode { invites[code] = record.id }
        }
        let decoder2 = JSONDecoder()
        decoder2.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: root.appendingPathComponent("entitlements.json")),
           let saved = try? decoder2.decode(EntitlementLedger.self, from: data) {
            ledger = saved
        }
    }

    private func saveLedger() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: root.appendingPathComponent("entitlements.json"), options: .atomic)
    }

    // MARK: Plans

    /// Puts a verified purchase on a trip. A pass is spent on this trip only;
    /// Plus counts the trip toward its twelve books a year. A book never moves
    /// to a lower plan.
    func apply(_ transaction: SignedTransaction, to id: String, now: Date = Date()) throws -> TripRecord {
        guard var record = records[id], let product = PlanProduct(rawValue: transaction.productId) else {
            throw APIError.notFound("No trip \(id)")
        }
        if product.isPass {
            if let spent = ledger.passes[transaction.transactionId], spent != id {
                throw APIError.conflict("That pass was already used for another book.")
            }
        } else {
            guard let expires = transaction.expires, expires > now else { throw APIError.paymentRequired(StoreKitError.expired.description) }
            var books = ledger.plusBooks[transaction.originalTransactionId] ?? [:]
            if books[id] == nil, PlanPolicy.plusBooksUsed(Array(books.values), now: now) >= PlanPolicy.plusBooksPerYear {
                throw APIError.paymentRequired("Yearly keeps \(PlanPolicy.plusBooksPerYear) books a year, and this year's are used. A Trip Pass keeps this one.")
            }
            books[id] = books[id] ?? now
            ledger.plusBooks[transaction.originalTransactionId] = books
        }
        if product.plan.rank < record.currentPlan.rank { return record }
        if product.isPass {
            // Free a pass this trip held before, if it moves to a better one.
            if let previous = record.planTransactionID, ledger.passes[previous] == id, previous != transaction.transactionId {
                ledger.passes[previous] = nil
            }
            ledger.passes[transaction.transactionId] = id
            record.planTransactionID = transaction.transactionId
            record.subscriptionExpires = nil
        } else {
            record.planTransactionID = transaction.originalTransactionId
            record.subscriptionExpires = transaction.expires
        }
        record.plan = product.plan
        if let finished = record.finishedAt {
            record.hostedUntil = PlanPolicy.hostedUntil(plan: product.plan, firstFinished: finished, subscriptionExpires: record.subscriptionExpires)
        }
        try saveLedger()
        try save(record)
        return record
    }

    /// Every book is free to make, so a trip can always be finished on the
    /// free plan. Kept for apps that still read the field.
    func freeBookAvailable(_ record: TripRecord) -> Bool { true }

    // MARK: Web purchases

    /// Applies a paid web checkout once. Returns the trip and whether anything
    /// changed (false for a repeated webhook).
    func applyWeb(_ completion: CheckoutCompletion) throws -> (TripRecord, Bool) {
        guard var record = records[completion.tripID] else { throw APIError.notFound("No trip \(completion.tripID)") }
        if ledger.webSessions?[completion.sessionID] != nil { return (record, false) }
        switch completion.kind {
        case .keep, .event:
            let plan: Plan = completion.kind == .keep ? .tripPass : .eventPass
            if plan.rank > record.currentPlan.rank {
                record.plan = plan
                record.planTransactionID = completion.sessionID
                record.subscriptionExpires = nil
                record.hostedUntil = nil
            }
            if record.keptBy == nil, let name = completion.name?.split(separator: " ").first { record.keptBy = String(name.prefix(TripLimits.nameLength)) }
            try save(record)
        case .print:
            guard let product = completion.product, let shipping = completion.shipping else {
                throw APIError.invalid("A print order needs a product and an address.")
            }
            let order = PrintOrder(
                id: Self.randomToken(length: 12), tripID: record.id, slug: record.slug, product: product,
                sessionID: completion.sessionID, email: completion.email, shipping: shipping,
                status: .paid, createdAt: Date(), updatedAt: Date(), cents: completion.cents, phone: completion.phone
            )
            try saveOrder(order)
        }
        if ledger.webSessions == nil { ledger.webSessions = [:] }
        ledger.webSessions?[completion.sessionID] = record.id
        try saveLedger()
        return (record, true)
    }

    // MARK: Print orders

    var ordersFolder: URL { root.appendingPathComponent("orders", isDirectory: true) }

    func saveOrder(_ order: PrintOrder) throws {
        try FileManager.default.createDirectory(at: ordersFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(order).write(to: ordersFolder.appendingPathComponent(order.id + ".json"), options: .atomic)
    }

    func orders() -> [PrintOrder] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: ordersFolder.path)) ?? []).filter { $0.hasSuffix(".json") }
        return names.compactMap { try? decoder.decode(PrintOrder.self, from: Data(contentsOf: ordersFolder.appendingPathComponent($0))) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func order(_ id: String) -> PrintOrder? { orders().first { $0.id == id } }

    func changeOrder(_ id: String, _ change: (inout PrintOrder) -> Void) throws -> PrintOrder? {
        guard var order = order(id) else { return nil }
        change(&order)
        order.updatedAt = Date()
        try saveOrder(order)
        return order
    }

    // MARK: Sources, downloads and unpicked photos

    /// The original behind each photo in the book, relative to the trip folder.
    struct Source: Codable, Sendable {
        var photo: String
        var path: String
        var credit: String?
    }

    func saveSources(_ id: String, _ sources: [(id: PhotoID, url: URL, credit: String?)]) throws {
        let base = folder(id).resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let list = sources.compactMap { item -> Source? in
            let path = item.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(base) else { return nil }
            return Source(photo: item.id.description, path: String(path.dropFirst(base.count)), credit: item.credit)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: folder(id).appendingPathComponent("sources.json"), options: .atomic)
    }

    func sources(_ id: String) -> [Source] {
        (try? JSONDecoder().decode([Source].self, from: Data(contentsOf: folder(id).appendingPathComponent("sources.json")))) ?? []
    }

    /// Everyone's full-size photos in the book as one zip, made once per
    /// version of the book. Names run in book order with who took each photo.
    func download(_ id: String) throws -> URL {
        let list = sources(id)
        guard !list.isEmpty else { throw APIError.notFound("This book has no photos to download yet.") }
        let key = Self.hash(list.map { $0.photo + $0.path }.joined(separator: "|")).prefix(16)
        let work = folder(id).appendingPathComponent("work", isDirectory: true)
        let url = work.appendingPathComponent("photos-\(key).zip")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        for old in ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []) where old.hasPrefix("photos-") && old.hasSuffix(".zip") {
            try? FileManager.default.removeItem(at: work.appendingPathComponent(old))
        }
        var entries: [ZipWriter.Entry] = []
        for (index, source) in list.enumerated() {
            let file = folder(id).appendingPathComponent(source.path)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let who = (source.credit ?? "").filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }.trimmingCharacters(in: .whitespaces)
            let ext = file.pathExtension.lowercased().isEmpty ? "jpg" : file.pathExtension.lowercased()
            entries.append(.init(name: String(format: "%03d", index + 1) + (who.isEmpty ? "" : " " + who) + "." + ext, source: file))
        }
        let partial = work.appendingPathComponent("photos-\(key).partial")
        try ZipWriter.write(entries, to: partial)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }

    /// Deletes friends' uploads a finish read but didn't pick. Only files in
    /// friends' folders (and the owner's, when the owner's photos were culled
    /// on the server) that the finish read are touched, so photos added while
    /// it ran wait for the next one. Matching is by file name, which is unique
    /// in a trip, so a path spelled two ways can never delete a picked photo.
    @discardableResult
    func deleteUnpicked(_ id: String, considered: [URL], picked: [URL]) -> Int {
        let keep = Set(picked.map(\.lastPathComponent))
        let allowed = [folder(id).appendingPathComponent("contributors"), guestFolder(id), folder(id).appendingPathComponent("owner")]
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
        var deleted = 0
        for file in considered where !keep.contains(file.lastPathComponent) {
            let path = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard allowed.contains(where: { path.hasPrefix($0) }) else { continue }
            if (try? FileManager.default.removeItem(atPath: path)) != nil { deleted += 1 }
        }
        return deleted
    }

    /// Friends' photos added since the book was last made.
    func newSinceFinish(_ id: String) -> Int {
        guard let finished = records[id]?.finishStartedAt ?? records[id]?.finishedAt else { return contributedCount(id) }
        var count = 0
        let folders = contributors(id).map { contributorFolder(id, $0.id) } + [guestFolder(id)]
        for folder in folders {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []) where !name.hasPrefix(".") {
                let date = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.creationDate] as? Date) ?? .distantPast
                if date > finished { count += 1 }
            }
        }
        return count
    }

    // MARK: Growth

    /// Taps on "Make one for your trip", by platform and month. The direction
    /// doc's trigger for building the Android web flow is this split.
    func noteMakeOne(platform: String, now: Date = Date()) throws {
        let url = root.appendingPathComponent("growth.json")
        var counts = (try? JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: url))) ?? [:]
        let month = String(ISO8601DateFormatter.string(from: now, timeZone: .gmt, formatOptions: [.withFullDate]).prefix(7))
        counts[month, default: [:]][platform, default: 0] += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(counts).write(to: url, options: .atomic)
    }

    func growth() -> [String: [String: Int]] {
        (try? JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: root.appendingPathComponent("growth.json")))) ?? [:]
    }

    /// The platform a request came from, from its User-Agent.
    static func platform(userAgent: String?) -> String {
        let agent = (userAgent ?? "").lowercased()
        if agent.contains("android") { return "android" }
        if agent.contains("iphone") || agent.contains("ipad") || agent.contains("ipod") { return "ios" }
        return "other"
    }

    func notePrintInterest(_ id: String) throws -> Int {
        guard var record = records[id] else { return 0 }
        record.printInterest = (record.printInterest ?? 0) + 1
        try save(record)
        return record.printInterest ?? 0
    }

    static func randomToken(length: Int) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func ownerFolder(_ id: String) -> URL { folder(id).appendingPathComponent("owner", isDirectory: true) }
    func guestFolder(_ id: String) -> URL { folder(id).appendingPathComponent("guests", isDirectory: true) }
    func bookFolder(_ id: String) -> URL { folder(id).appendingPathComponent("book", isDirectory: true) }
    func contributorFolder(_ id: String, _ contributor: String) -> URL {
        folder(id).appendingPathComponent("contributors", isDirectory: true).appendingPathComponent(contributor, isDirectory: true)
    }

    /// Creates a trip and returns it with the owner token, which is shown once.
    func create(title: String?, context: TripContext, tone: DiaryTone, theme: BookTheme, ownerName: String? = nil, installID: String? = nil) throws -> (TripRecord, String) {
        let token = Self.randomToken(length: 32)
        let record = TripRecord(
            id: UUID().uuidString.lowercased(),
            slug: Self.randomToken(length: 12),
            ownerTokenHash: Self.hash(token),
            title: title,
            context: context,
            tone: tone,
            theme: theme,
            createdAt: Date(),
            ownerName: ownerName,
            inviteCode: Self.randomToken(length: 14),
            installHash: installID.flatMap { $0.isEmpty ? nil : Self.hash("install:" + $0) }
        )
        for url in [ownerFolder(record.id), guestFolder(record.id), bookFolder(record.id)] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try save(record)
        return (record, token)
    }

    func record(id: String) -> TripRecord? { records[id] }

    func record(slug: String) -> TripRecord? { slugs[slug].flatMap { records[$0] } }

    func record(invite code: String) -> TripRecord? { invites[code].flatMap { records[$0] } }

    // MARK: Contributors

    func contributors(_ id: String) -> [Contributor] {
        if let cached = people[id] { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? decoder.decode([Contributor].self, from: Data(contentsOf: folder(id).appendingPathComponent("contributors.json")))) ?? []
        people[id] = loaded
        return loaded
    }

    private func saveContributors(_ id: String, _ list: [Contributor]) throws {
        people[id] = list
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: folder(id).appendingPathComponent("contributors.json"), options: .atomic)
    }

    /// Adds a person to a trip and returns them with their token, shown once.
    func join(_ id: String, name: String, email: String? = nil) throws -> (Contributor, String) {
        var list = contributors(id)
        guard list.count < TripLimits.contributors else { throw APIError.conflict("This trip already has as many people as it can take.") }
        let token = Self.randomToken(length: 32)
        let person = Contributor(
            id: Self.randomToken(length: 10), name: name, tokenHash: Self.hash(token), joinedAt: Date(),
            email: email, mailToken: email == nil ? nil : Self.mailToken(id)
        )
        try FileManager.default.createDirectory(at: contributorFolder(id, person.id), withIntermediateDirectories: true)
        list.append(person)
        try saveContributors(id, list)
        return (person, token)
    }

    static func mailToken(_ tripID: String) -> String { tripID + "." + randomToken(length: 24) }

    /// Sets or clears a person's email.
    func setEmail(_ id: String, contributor: String, email: String?) throws {
        var list = contributors(id)
        guard let index = list.firstIndex(where: { $0.id == contributor }) else { return }
        list[index].email = email
        if email != nil, list[index].mailToken == nil { list[index].mailToken = Self.mailToken(id) }
        if email != nil { list[index].unsubscribed = nil }
        try saveContributors(id, list)
    }

    func setOwnerEmail(_ id: String, email: String?) throws {
        try update(id) { record in
            record.ownerEmail = email
            if email != nil, record.ownerMailToken == nil { record.ownerMailToken = Self.mailToken(id) }
            if email != nil { record.ownerUnsubscribed = nil }
        }
    }

    /// Everyone who gave an address for this book and hasn't stopped emails.
    func recipients(_ id: String) -> [Recipient] {
        guard let record = records[id] else { return [] }
        var list: [Recipient] = []
        if let email = record.ownerEmail, let token = record.ownerMailToken, record.ownerUnsubscribed != true {
            list.append(Recipient(email: email, name: record.ownerName, unsubscribeToken: token, contributorID: nil))
        }
        for person in contributors(id) {
            guard let email = person.email, let token = person.mailToken, person.unsubscribed != true else { continue }
            if list.contains(where: { $0.email.lowercased() == email.lowercased() }) { continue }
            list.append(Recipient(email: email, name: person.name, unsubscribeToken: token, contributorID: person.id))
        }
        return list
    }

    /// The book an unsubscribe token belongs to, if the token is real.
    func unsubscribeTarget(_ token: String) -> TripRecord? {
        guard let id = token.split(separator: ".").first.map(String.init), let record = records[id] else { return nil }
        if let own = record.ownerMailToken, Self.constantTimeEqual(own, token) { return record }
        return contributors(id).contains { $0.mailToken.map { Self.constantTimeEqual($0, token) } ?? false } ? record : nil
    }

    /// Stops emails for whoever holds this token. Returns the book, or nil.
    @discardableResult
    func unsubscribe(_ token: String) throws -> TripRecord? {
        guard let record = unsubscribeTarget(token) else { return nil }
        if let own = record.ownerMailToken, Self.constantTimeEqual(own, token) {
            try update(record.id) { $0.ownerUnsubscribed = true }
        } else {
            var list = contributors(record.id)
            for index in list.indices where list[index].mailToken.map({ Self.constantTimeEqual($0, token) }) ?? false {
                list[index].unsubscribed = true
            }
            try saveContributors(record.id, list)
        }
        return record
    }

    func allRecords() -> [TripRecord] { Array(records.values) }

    // MARK: Photos of you

    func facesFolder(_ id: String) -> URL { folder(id).appendingPathComponent("faces", isDirectory: true) }

    func changeContributor(_ id: String, _ person: String, _ change: (inout Contributor) -> Void) throws -> Contributor? {
        var list = contributors(id)
        guard let index = list.firstIndex(where: { $0.id == person }) else { return nil }
        change(&list[index])
        try saveContributors(id, list)
        return list[index]
    }

    /// Deletes an offline book's photos, uploads, notes and friends' details,
    /// keeping only the trip record so its links say what happened.
    func purge(_ id: String, now: Date = Date()) throws {
        let fm = FileManager.default
        for name in ["owner", "guests", "book", "contributors", "work", "offers", "faces"] {
            try? fm.removeItem(at: folder(id).appendingPathComponent(name, isDirectory: true))
        }
        for name in ["guest.json", "contributors.json"] {
            try? fm.removeItem(at: folder(id).appendingPathComponent(name))
        }
        people[id] = []
        guest[id] = GuestActivity()
        try update(id) { record in
            record.purgedAt = now
            record.inviteClosed = true
            record.ownerEmail = nil
        }
    }

    /// Moves a trip's dates back, so the checks can see a book age. Only
    /// reachable when the server allows it.
    func shift(_ id: String, by interval: TimeInterval) throws {
        try update(id) { record in
            record.createdAt -= interval
            record.finishedAt = record.finishedAt.map { $0 - interval }
            record.hostedUntil = record.hostedUntil.map { $0 - interval }
        }
    }

    func contributor(_ id: String, token: String?) -> Contributor? {
        guard let token, !token.isEmpty else { return nil }
        let hashed = Self.hash(token)
        return contributors(id).first { Self.constantTimeEqual($0.tokenHash, hashed) }
    }

    func photoCount(_ folder: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }

    func contributedCount(_ id: String) -> Int {
        contributors(id).reduce(0) { $0 + photoCount(contributorFolder(id, $1.id)) }
    }

    /// Stores one contributor photo, within that person's limit on this book's plan.
    func store(photo data: Data, name: String, id: String, contributor: Contributor) throws -> URL {
        let folder = contributorFolder(id, contributor.id)
        let limit = min(records[id]?.limits.photosPerFriend ?? TripLimits.photosPerContributor, TripLimits.photosPerContributor)
        guard photoCount(folder) < limit else {
            throw APIError.conflict("You've added as many photos as one person can (\(limit)).")
        }
        guard Self.isImage(data) else { throw APIError.invalid("Add JPEG or HEIC photos.") }
        let safe = String(name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(48))
        let ext = data.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic"
        // The person's id in the name keeps every file name unique in the book.
        let url = folder.appendingPathComponent("c\(contributor.id)-" + (safe.isEmpty ? UUID().uuidString : safe) + "." + ext)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Removes everything one person added.
    func removePhotos(_ id: String, contributor: Contributor) throws -> Int {
        let folder = contributorFolder(id, contributor.id)
        let count = photoCount(folder)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return count
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Data(a.utf8), y = Data(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func isOwner(_ record: TripRecord, token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        return Self.constantTimeEqual(record.ownerTokenHash, Self.hash(token))
    }

    func update(_ id: String, _ change: (inout TripRecord) -> Void) throws {
        guard var record = records[id] else { return }
        change(&record)
        try save(record)
    }

    private func save(_ record: TripRecord) throws {
        records[record.id] = record
        slugs[record.slug] = record.id
        if let code = record.inviteCode { invites[code] = record.id }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: folder(record.id).appendingPathComponent("trip.json"), options: .atomic)
    }

    /// Stores an uploaded photo under a safe name. Returns the stored file.
    func store(photo data: Data, name: String, id: String, guest: Bool) throws -> URL {
        let folder = guest ? guestFolder(id) : ownerFolder(id)
        let count = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0
        if count >= (guest ? TripLimits.guestPhotos : TripLimits.ownerPhotos) {
            throw APIError.conflict(guest ? "This book already has as many guest photos as it can take." : "This trip already has the most photos a finish can take.")
        }
        guard Self.isImage(data) else { throw APIError.invalid("Upload a JPEG or HEIC photo.") }
        let safe = String(name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(64))
        let ext = data.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic"
        // Guest files get a prefix so they never collide with the owner's names in the book.
        let base = (guest ? "guest-" : "") + (safe.isEmpty ? UUID().uuidString : safe)
        let url = folder.appendingPathComponent(base + "." + ext)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func isImage(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        // HEIC: an ISO-BMFF "ftyp" box with a HEIF brand.
        guard data.count > 12, String(decoding: data[4..<8], as: UTF8.self) == "ftyp" else { return false }
        let brand = String(decoding: data[8..<12], as: UTF8.self)
        return ["heic", "heix", "mif1", "msf1", "hevc"].contains(brand)
    }

    func activity(_ id: String) -> GuestActivity {
        if let cached = guest[id] { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? decoder.decode(GuestActivity.self, from: Data(contentsOf: folder(id).appendingPathComponent("guest.json")))) ?? GuestActivity()
        guest[id] = loaded
        return loaded
    }

    func changeActivity(_ id: String, _ change: (inout GuestActivity) throws -> Void) throws -> GuestActivity {
        var current = activity(id)
        try change(&current)
        guest[id] = current
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(current).write(to: folder(id).appendingPathComponent("guest.json"), options: .atomic)
        return current
    }
}
