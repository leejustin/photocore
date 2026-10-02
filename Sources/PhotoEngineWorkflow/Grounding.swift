import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import NaturalLanguage
import PhotoEngineApple
import PhotoEngineCore
import Vision

/// One thing the book may say, with where it came from. Writers get only these.
public struct GroundFact: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case location      // reverse geocoding of the photo's GPS
        case nearby        // a landmark within walking distance; "near", never "visited"
        case sun           // sunrise and sunset computed from date and place
        case photoText     // words legible in the photo itself
        case scene         // Vision scene labels
        case people        // how many faces, never who
        case calendar      // an event on the owner's calendar during the trip
        case owner         // something the owner told us
        case time          // local date and time of day
    }

    public var id: String
    public var source: Source
    public var text: String
    /// The chapter or photo key this fact belongs to; nil for the whole trip.
    public var scope: String?

    public init(id: String, source: Source, text: String, scope: String? = nil) {
        self.id = id
        self.source = source
        self.text = text
        self.scope = scope
    }
}

/// What the owner may add, all optional: a one-line note and calendar events.
public struct TripContext: Codable, Sendable, Equatable {
    public var note: String?
    public var calendarEvents: [String]

    public init(note: String? = nil, calendarEvents: [String] = []) {
        self.note = note
        self.calendarEvents = calendarEvents
    }

    public static let empty = TripContext()
}

/// Per-photo enrichment gathered after the cull, only for keepers.
public struct PhotoEnrichment: Codable, Sendable, Equatable {
    public var nearby: [String]
    public var text: [String]

    public init(nearby: [String] = [], text: [String] = []) {
        self.nearby = nearby
        self.text = text
    }
}

// MARK: - Sources

/// Sunrise and sunset from the NOAA solar position approximation, accurate to a
/// minute or two away from the poles. Pure and offline.
public enum SunTimes {
    public static func compute(date: Date, latitude: Double, longitude: Double) -> (sunrise: Date, sunset: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let gamma = 2 * Double.pi / 365 * (day - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma) - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma) - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma) - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let lat = latitude * .pi / 180
        let zenith = 90.833 * Double.pi / 180
        let cosHA = cos(zenith) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)
        guard (-1...1).contains(cosHA) else { return nil }
        let ha = acos(cosHA) * 180 / .pi
        let noonMinutes = 720 - 4 * longitude - eqTime
        let start = calendar.startOfDay(for: date)
        return (start.addingTimeInterval((noonMinutes - 4 * ha) * 60), start.addingTimeInterval((noonMinutes + 4 * ha) * 60))
    }

    /// "around sunset" when a photo falls within 40 minutes of it.
    public static func phrase(for date: Date, latitude: Double, longitude: Double) -> String? {
        guard let times = compute(date: date, latitude: latitude, longitude: longitude) else { return nil }
        if abs(date.timeIntervalSince(times.sunset)) <= 40 * 60 { return "around sunset" }
        if abs(date.timeIntervalSince(times.sunrise)) <= 40 * 60 { return "around sunrise" }
        if date > times.sunset.addingTimeInterval(40 * 60) || date < times.sunrise { return "after dark" }
        return nil
    }
}

public enum PhotoTextReader {
    /// Short, confidently read lines such as a shop sign or a menu heading.
    /// Long paragraphs and noise are dropped; at most `limit` lines per photo.
    public static func lines(in image: CGImage, limit: Int = 2) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        VisionCompute.prepare([request])
        let performed = VisionCompute.exclusive {
            (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil
        }
        guard performed else { return [] }
        let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.8 }
            .map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Array(candidates.filter(isSignLike).prefix(limit))
    }

    public static func isSignLike(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count
        return (3...32).contains(text.count) && letters >= 3 && Double(letters) / Double(text.count) >= 0.6
    }
}

/// Landmarks near a coordinate, from MapKit's points of interest. Cached per
/// 100-meter cell. Only well-known categories, so a pharmacy never becomes the
/// headline of a chapter.
public actor NearbyPlaces {
    public static let shared = NearbyPlaces()
    private var cache: [String: [String]] = [:]

    static let categories: [MKPointOfInterestCategory] = [
        .museum, .park, .nationalPark, .beach, .castle, .landmark, .amusementPark, .aquarium,
        .zoo, .stadium, .theater, .university, .marina, .winery, .fortress, .nationalMonument, .planetarium
    ]

    public func names(latitude: Double, longitude: Double, radius: Double = 150) async -> [String] {
        let key = String(format: "%.3f,%.3f", latitude, longitude)
        if let hit = cache[key] { return hit }
        let request = MKLocalPointsOfInterestRequest(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: Self.categories)
        let response = try? await MKLocalSearch(request: request).start()
        let origin = CLLocation(latitude: latitude, longitude: longitude)
        let names = (response?.mapItems ?? [])
            .compactMap { item -> (String, Double)? in
                guard let name = item.name else { return nil }
                let location: CLLocation?
                if #available(macOS 26, iOS 26, *) { location = item.location } else { location = item.placemark.location }
                guard let location else { return nil }
                return (name, origin.distance(from: location))
            }
            .sorted { $0.1 < $1.1 }
            .prefix(2)
            .map(\.0)
        cache[key] = names
        return names
    }
}

public enum TripEnricher {
    /// Reads signs and nearby landmarks for each keeper. Network is used only for
    /// MapKit; pass `lookUpNearby: false` offline.
    public static func enrich(facts: TripFacts, source: (PhotoFacts) -> URL?, lookUpNearby: Bool = true) async -> [PhotoID: PhotoEnrichment] {
        var result: [PhotoID: PhotoEnrichment] = [:]
        for photo in facts.photos {
            var enrichment = PhotoEnrichment()
            if let url = source(photo), let image = CGImage.photocoreThumbnail(url: url, maxPixel: 1600) {
                enrichment.text = PhotoTextReader.lines(in: image)
            }
            if lookUpNearby, let lat = photo.latitude, let lon = photo.longitude {
                enrichment.nearby = await NearbyPlaces.shared.names(latitude: lat, longitude: lon)
            }
            result[photo.id] = enrichment
        }
        return result
    }
}

// MARK: - Checker

/// Rejects generated text that claims something the facts don't support.
///
/// Three checks, all against the fact list:
/// - names: a capitalized word that isn't the start of a sentence;
/// - numbers;
/// - things and events: nouns, and verbs that assert something happened
///   ("arrived", "ate", "flew"), compared by lemma, so "stars" needs "star".
/// A short list of generic words ("moment", "evening", "friends", "light") is
/// always allowed. Failing fields fall back to plain text from the facts.
public struct GroundingCheck: Sendable {
    public let vocabulary: Set<String>

    static let everyday: Set<String> = [
        "i", "we", "our", "us", "my", "the", "a", "an",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"
    ]

    /// Nouns that describe a photo or a moment without asserting new facts.
    static let genericNouns: Set<String> = [
        "moment", "day", "night", "evening", "morning", "afternoon", "trip", "time", "photo", "picture", "shot",
        "view", "scene", "light", "color", "colour", "detail", "friend", "people", "person", "group", "memory",
        "way", "place", "spot", "city", "town", "street", "side", "corner", "end", "start", "beginning", "highlight",
        "glimpse", "look", "mood", "atmosphere", "energy", "favorite", "favourite", "few", "one", "lot", "bit",
        "today", "tonight", "chapter", "story", "journey", "adventure", "us", "we", "everyone", "something", "thing"
    ]

    /// Verbs that assert an event happened. Ordinary verbs ("see", "be", "share")
    /// are not checked.
    static let eventVerbs: Set<String> = [
        "arrive", "fly", "land", "drive", "ride", "eat", "drink", "dine", "cook", "swim", "hike", "climb", "dance",
        "sing", "buy", "shop", "order", "taste", "visit", "explore", "tour", "attend", "celebrate", "marry", "win",
        "lose", "sleep", "wake", "rest", "travel", "board", "check", "camp", "surf", "ski", "run", "race", "play",
        "light", "watch", "admire", "meet", "join", "settle", "stay", "leave", "return"
    ]

    /// Irregular past tenses of event verbs, for systems without lemma data
    /// (the iOS simulator has none).
    static let irregular: [String: String] = [
        "ate": "eat", "eaten": "eat", "flew": "fly", "flown": "fly", "drove": "drive", "driven": "drive", "rode": "ride",
        "ridden": "ride", "drank": "drink", "drunk": "drink", "swam": "swim", "swum": "swim", "sang": "sing", "sung": "sing",
        "bought": "buy", "won": "win", "lost": "lose", "slept": "sleep", "woke": "wake", "woken": "wake", "ran": "run",
        "met": "meet", "left": "leave", "lit": "light", "stayed": "stay", "arrived": "arrive", "visited": "visit",
        "landed": "land", "danced": "dance", "climbed": "climb", "hiked": "hike", "explored": "explore", "watched": "watch",
        "joined": "join", "tasted": "taste", "ordered": "order", "cooked": "cook", "celebrated": "celebrate"
    ]

    public init(facts: [GroundFact], extra: [String] = []) {
        var words = Set<String>()
        for text in facts.map(\.text) + extra {
            for word in Self.words(in: text) { words.insert(word.lowercased()) }
            for lemma in Self.lemmas(in: text) { words.insert(lemma) }
        }
        vocabulary = words
    }

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }).map(String.init)
    }

    static func lemmas(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        var out: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            out.append((tag?.rawValue ?? String(text[range])).lowercased())
            return true
        }
        return out
    }

    func known(_ word: String, lemma: String?) -> Bool {
        let lower = word.lowercased()
        if Self.everyday.contains(lower) || vocabulary.contains(lower) { return true }
        if let lemma, vocabulary.contains(lemma) { return true }
        if lower.hasSuffix("s"), vocabulary.contains(String(lower.dropLast())) { return true }
        return false
    }

    /// Words that would need support from the facts.
    public func unsupported(in text: String) -> [String] {
        var flagged: [String] = []
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        var sentenceStart = true
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace]) { tag, range in
            let word = String(text[range])
            if tag == .punctuation || tag == .sentenceTerminator {
                if ".!?".contains(word) { sentenceStart = true }
                return true
            }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue.lowercased()
            defer { sentenceStart = false }
            if word.contains(where: \.isNumber) {
                if !known(word, lemma: lemma) { flagged.append(word) }
                return true
            }
            if !sentenceStart, word.first?.isUppercase == true, !known(word, lemma: lemma) {
                flagged.append(word)
                return true
            }
            let base = Self.irregular[word.lowercased()] ?? lemma ?? word.lowercased()
            if Self.eventVerbs.contains(base), base != word.lowercased() || tag == .verb, !known(word, lemma: base) {
                flagged.append(word)
                return true
            }
            if tag == .noun, !Self.genericNouns.contains(base), !known(word, lemma: lemma) {
                flagged.append(word)
            } else if tag == .verb, Self.eventVerbs.contains(base), !known(word, lemma: lemma) {
                flagged.append(word)
            }
            return true
        }
        return flagged
    }

    public func accepts(_ text: String) -> Bool {
        if Self.taggerAvailable(text) { return unsupported(in: text).isEmpty }
        return strictUnsupported(in: text).isEmpty
    }

    /// Words with no tagger behind them are not common function words.
    static let functionWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "in", "on", "at", "to", "for", "with", "by", "from", "over", "under",
        "into", "out", "up", "down", "near", "after", "before", "around", "through", "then", "this", "that", "these",
        "those", "it", "its", "is", "was", "were", "are", "be", "been", "being", "had", "has", "have", "so", "very",
        "just", "all", "some", "more", "most", "came", "come", "went", "go", "got", "get", "made", "make", "there",
        "here", "what", "when", "where", "who", "how", "not", "no", "yes", "our", "we", "us", "you", "your", "they",
        "their", "them", "one", "two", "few", "many", "much", "still", "again", "also", "too", "good", "great", "nice",
        "little", "big", "long", "warm", "quiet", "bright", "dark", "late", "early", "together", "photos", "photo"
    ]

    /// Some systems (the iOS simulator) can lack the tagger's models; then no
    /// word gets a lexical class.
    static func taggerAvailable(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var tagged = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if let tag, tag != .otherWord { tagged = true; return false }
            return true
        }
        return tagged
    }

    /// Without word classes: any word of four or more letters outside the facts,
    /// the generic nouns and common function words needs support.
    func strictUnsupported(in text: String) -> [String] {
        var flagged = unsupportedNamesAndNumbers(in: text)
        for word in Self.words(in: text) {
            let lower = word.lowercased()
            let base = Self.irregular[lower] ?? (lower.hasSuffix("s") ? String(lower.dropLast()) : lower)
            guard lower.count >= 4, word.allSatisfy(\.isLetter) else { continue }
            if Self.functionWords.contains(lower) || Self.genericNouns.contains(base) || known(word, lemma: base) { continue }
            flagged.append(word)
        }
        return flagged
    }

    func unsupportedNamesAndNumbers(in text: String) -> [String] {
        var flagged: [String] = []
        for sentence in text.split(whereSeparator: { ".!?\n".contains($0) }) {
            for (index, word) in Self.words(in: String(sentence)).enumerated() {
                let isNumber = word.contains(where: \.isNumber)
                let isName = index > 0 && word.first?.isUppercase == true
                if (isNumber || isName) && !known(word, lemma: nil) { flagged.append(word) }
            }
        }
        return flagged
    }
}
