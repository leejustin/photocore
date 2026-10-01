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
}

/// Trips live on disk under the worker's output root, one folder each:
/// `trip.json`, `owner/`, `guests/`, `book/`, `guest.json`.
actor TripStore {
    let root: URL
    private var records: [String: TripRecord] = [:]
    private var slugs: [String: String] = [:]
    private var guest: [String: GuestActivity] = [:]

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
        }
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

    /// Creates a trip and returns it with the owner token, which is shown once.
    func create(title: String?, context: TripContext, tone: DiaryTone, theme: BookTheme) throws -> (TripRecord, String) {
        let token = Self.randomToken(length: 32)
        let record = TripRecord(
            id: UUID().uuidString.lowercased(),
            slug: Self.randomToken(length: 12),
            ownerTokenHash: Self.hash(token),
            title: title,
            context: context,
            tone: tone,
            theme: theme,
            createdAt: Date()
        )
        for url in [ownerFolder(record.id), guestFolder(record.id), bookFolder(record.id)] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try save(record)
        return (record, token)
    }

    func record(id: String) -> TripRecord? { records[id] }

    func record(slug: String) -> TripRecord? { slugs[slug].flatMap { records[$0] } }

    func isOwner(_ record: TripRecord, token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        let expected = Data(record.ownerTokenHash.utf8)
        let given = Data(Self.hash(token).utf8)
        guard expected.count == given.count else { return false }
        return zip(expected, given).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func update(_ id: String, _ change: (inout TripRecord) -> Void) throws {
        guard var record = records[id] else { return }
        change(&record)
        try save(record)
    }

    private func save(_ record: TripRecord) throws {
        records[record.id] = record
        slugs[record.slug] = record.id
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
