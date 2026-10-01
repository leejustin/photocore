import Foundation
import PhotoEngineApple
import PhotoEngineCore

/// One photo on a book page, with the three caption lengths the book, the grid
/// and the Instagram pack use.
public struct BookPhoto: Codable, Sendable, Equatable, Identifiable {
    public var id: PhotoID
    public var fileName: String
    public var label: String
    public var caption: String
    public var instagramCaption: String
    public var altText: String
    public var isPortrait: Bool

    public init(id: PhotoID, fileName: String, label: String = "", caption: String = "", instagramCaption: String = "", altText: String = "", isPortrait: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.label = label
        self.caption = caption
        self.instagramCaption = instagramCaption
        self.altText = altText
        self.isPortrait = isPortrait
    }
}

/// A chapter of the book: one stretch of the trip in one place.
public struct BookSection: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var heading: String
    public var dateLine: String
    public var place: String?
    public var diary: String
    public var photos: [BookPhoto]

    public init(id: String, heading: String, dateLine: String, place: String?, diary: String, photos: [BookPhoto]) {
        self.id = id
        self.heading = heading
        self.dateLine = dateLine
        self.place = place
        self.diary = diary
        self.photos = photos
    }
}

public struct TripBook: Codable, Sendable, Equatable {
    public static let fileName = "book.json"
    public var schemaVersion = 1
    public var title: String
    public var intro: String
    public var dateRange: String
    public var coverPhotoID: PhotoID?
    public var sections: [BookSection]
    /// Which writer produced the text, for regenerating later ("template", or a model id).
    public var writer: String
    public var theme: BookTheme

    public init(title: String, intro: String, dateRange: String, coverPhotoID: PhotoID?, sections: [BookSection], writer: String, theme: BookTheme) {
        self.title = title
        self.intro = intro
        self.dateRange = dateRange
        self.coverPhotoID = coverPhotoID
        self.sections = sections
        self.writer = writer
        self.theme = theme
    }

    public var allPhotos: [BookPhoto] { sections.flatMap(\.photos) }

    public func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func load(from folder: URL) throws -> TripBook {
        try JSONDecoder().decode(TripBook.self, from: Data(contentsOf: folder.appendingPathComponent(fileName)))
    }
}

public enum BookTheme: String, Codable, Sendable, CaseIterable {
    /// A clean online photobook: the default.
    case book
    /// Polaroid frames and handwritten captions, opt-in.
    case scrapbook
}

/// Edits the owner made on the page. Kept apart from generated text so that a
/// regenerate never overwrites what a person wrote.
public struct BookEdits: Codable, Sendable, Equatable {
    public static let fileName = "edits.json"
    /// Keys: "title", "intro", "section.<id>.heading", "section.<id>.diary",
    /// "photo.<photoID>.caption".
    public var values: [String: String] = [:]
    public var hiddenPhotoIDs: Set<PhotoID> = []

    public init() {}

    public static func load(from folder: URL) -> BookEdits {
        (try? JSONDecoder().decode(BookEdits.self, from: Data(contentsOf: folder.appendingPathComponent(fileName)))) ?? BookEdits()
    }

    public func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Only these keys may be edited, and values are plain text with a length cap.
    public static func isAllowed(key: String) -> Bool {
        if key == "title" || key == "intro" { return true }
        let parts = key.split(separator: ".")
        guard parts.count == 3 else { return false }
        return (parts[0] == "section" && (parts[2] == "heading" || parts[2] == "diary"))
            || (parts[0] == "photo" && parts[2] == "caption")
    }

    public static let maximumLength = 2_000

    public func applied(to book: TripBook) -> TripBook {
        var book = book
        if let title = values["title"] { book.title = title }
        if let intro = values["intro"] { book.intro = intro }
        for s in book.sections.indices {
            let id = book.sections[s].id
            if let heading = values["section.\(id).heading"] { book.sections[s].heading = heading }
            if let diary = values["section.\(id).diary"] { book.sections[s].diary = diary }
            book.sections[s].photos.removeAll { hiddenPhotoIDs.contains($0.id) }
            for p in book.sections[s].photos.indices {
                if let caption = values["photo.\(book.sections[s].photos[p].id.description).caption"] {
                    book.sections[s].photos[p].caption = caption
                }
            }
        }
        book.sections.removeAll { $0.photos.isEmpty }
        return book
    }
}

/// Splits a trip's keepers into chapters by day, place and time of day.
public enum BookSectioner {
    public struct Chapter: Sendable, Equatable {
        public var id: String
        public var photos: [PhotoFacts]
        public var place: PlaceName?
        public var start: Date?
        public var timeZone: TimeZone
    }

    /// A new chapter starts on a new day, after a pause longer than `gap`, or
    /// when the named place changes. Chapters stay between 1 and `maximumPhotos`.
    public static func chapters(for facts: TripFacts, gap: TimeInterval = 3 * 3600, maximumPhotos: Int = 12) -> [Chapter] {
        let ordered = facts.photos.sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }
        var chapters: [[PhotoFacts]] = []
        for photo in ordered {
            guard var current = chapters.last, let last = current.last else {
                chapters.append([photo])
                continue
            }
            var split = current.count >= maximumPhotos
            if let a = last.captureDate, let b = photo.captureDate {
                let calendar = localCalendar(photo.localTimeZone)
                if !calendar.isDate(a, inSameDayAs: b) || b.timeIntervalSince(a) > gap { split = true }
            }
            if let p1 = last.place?.display, let p2 = photo.place?.display, p1 != p2 { split = true }
            if split {
                chapters.append([photo])
            } else {
                current.append(photo)
                chapters[chapters.count - 1] = current
            }
        }
        return chapters.enumerated().map { index, photos in
            Chapter(id: "s\(index + 1)", photos: photos, place: photos.compactMap(\.place).first, start: photos.first?.captureDate, timeZone: photos.first?.localTimeZone ?? .current)
        }
    }

    static func localCalendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// "Friday, Oct 11", in the photo's local time.
    public static func dayLine(for date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "Friday evening", in the photo's local time.
    public static func momentLine(for date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.timeZone = timeZone
        return date.formatted(style) + " " + partOfDay(date, calendar: localCalendar(timeZone))
    }

    public static func dateLine(for date: Date?, timeZone: TimeZone = .current) -> String {
        dayLine(for: date, timeZone: timeZone)
    }

    public static func partOfDay(_ date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<21: "evening"
        default: "night"
        }
    }

    public static func dateRange(for facts: TripFacts) -> String {
        let dates = facts.photos.compactMap(\.captureDate).sorted()
        guard let first = dates.first, let last = dates.last else { return "" }
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: first, to: last)
    }
}
