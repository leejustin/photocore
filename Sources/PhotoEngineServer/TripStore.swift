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

    var inviteOpen: Bool { inviteCode != nil && inviteClosed != true }
    var currentPlan: Plan { plan ?? .free }
    var limits: PlanLimits { currentPlan.limits }

    func isHosted(at date: Date = Date()) -> Bool { hostedUntil.map { date < $0 } ?? true }
}

/// Which purchases and free books have been spent, so a pass covers one book,
/// Plus covers twelve a year and each phone gets one free book.
struct EntitlementLedger: Codable, Sendable {
    /// Pass transaction ID to the trip it was spent on.
    var passes: [String: String] = [:]
    /// Plus original transaction ID to trip IDs and when each was started.
    var plusBooks: [String: [String: Date]] = [:]
    /// Install hash to the trip that used the free book.
    var freeBooks: [String: String] = [:]
}

/// Someone who joined through the invite link. Their token lets them add and
/// remove their own photos and nothing else.
struct Contributor: Codable, Sendable {
    var id: String
    var name: String
    var tokenHash: String
    var joinedAt: Date
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
    /// The most any plan allows; each plan's own limit is lower or equal.
    static let contributors = 100
    static let photosPerContributor = 150
    static let contributedPhotos = 1_000
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
                throw APIError.paymentRequired("Plus covers \(PlanPolicy.plusBooksPerYear) books a year, and this year's are used. A Trip Pass covers this one.")
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
        // A free book that becomes paid gives the phone its free book back.
        if let hash = record.installHash, ledger.freeBooks[hash] == id { ledger.freeBooks[hash] = nil }
        try saveLedger()
        try save(record)
        return record
    }

    /// Whether this trip's phone can still make its free book with this trip.
    func freeBookAvailable(_ record: TripRecord) -> Bool {
        guard let hash = record.installHash else { return false }
        return ledger.freeBooks[hash].map { $0 == record.id } ?? true
    }

    /// Spends the phone's free book on this trip, or refuses if it went elsewhere.
    func claimFreeBook(_ id: String) throws {
        guard let record = records[id] else { throw APIError.notFound("No trip \(id)") }
        guard record.currentPlan == .free else { return }
        guard let hash = record.installHash else {
            throw APIError.paymentRequired("Update the app to make your free book.")
        }
        if let used = ledger.freeBooks[hash], used != id {
            throw APIError.paymentRequired("Your free book is already made. Plus or a Trip Pass covers this one.")
        }
        ledger.freeBooks[hash] = id
        try saveLedger()
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
    func join(_ id: String, name: String) throws -> (Contributor, String) {
        var list = contributors(id)
        guard list.count < TripLimits.contributors else { throw APIError.conflict("This trip already has as many people as it can take.") }
        let token = Self.randomToken(length: 32)
        let person = Contributor(id: Self.randomToken(length: 10), name: name, tokenHash: Self.hash(token), joinedAt: Date())
        try FileManager.default.createDirectory(at: contributorFolder(id, person.id), withIntermediateDirectories: true)
        list.append(person)
        try saveContributors(id, list)
        return (person, token)
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

    /// Stores one contributor photo, within that person's and the trip's limits.
    func store(photo data: Data, name: String, id: String, contributor: Contributor) throws -> URL {
        let folder = contributorFolder(id, contributor.id)
        guard photoCount(folder) < TripLimits.photosPerContributor else {
            throw APIError.conflict("You've added as many photos as one person can (\(TripLimits.photosPerContributor)).")
        }
        guard contributedCount(id) < TripLimits.contributedPhotos else { throw APIError.conflict("This trip has all the photos it can take.") }
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
