import CoreGraphics
import Foundation
import ImageIO
import PhotoEngineApple
import PhotoEngineCore
import UniformTypeIdentifiers

public enum DiaryTone: String, Codable, Sendable, CaseIterable {
    case warm, dry, minimal
}

/// Everything a writer may use. Photos are referred to by short keys ("p1") so
/// the writer never sees file names or identifiers. `facts` is the only source
/// of names, places and numbers.
public struct DiaryRequest: Codable, Sendable {
    public struct Photo: Codable, Sendable {
        public var key: String
        public var time: String
        public var labels: [String]
        public var people: Int
        public var orientation: String
        public var text: [String]
    }

    public struct Chapter: Codable, Sendable {
        public var id: String
        public var place: String?
        public var when: String
        public var day: String
        public var nearby: [String]
        public var sun: String?
        public var photos: [Photo]
    }

    public var dateRange: String
    public var places: [String]
    public var chapters: [Chapter]
    public var facts: [GroundFact]
    public var tone: DiaryTone
    public var voiceExamples: [String]
}

/// What a writer returns. Field names are the JSON keys every provider is asked for.
public struct DiaryText: Codable, Sendable, Equatable {
    public struct Section: Codable, Sendable, Equatable {
        public var id: String
        public var heading: String
        public var diary: String

        public init(id: String, heading: String, diary: String) {
            self.id = id
            self.heading = heading
            self.diary = diary
        }
    }

    public struct Photo: Codable, Sendable, Equatable {
        public var key: String
        public var label: String
        public var caption: String
        public var instagram_caption: String
        public var alt_text: String

        public init(key: String, label: String, caption: String, instagram_caption: String, alt_text: String) {
            self.key = key
            self.label = label
            self.caption = caption
            self.instagram_caption = instagram_caption
            self.alt_text = alt_text
        }
    }

    public var title: String
    public var intro: String
    public var sections: [Section]
    public var photos: [Photo]

    public init(title: String, intro: String, sections: [Section], photos: [Photo]) {
        self.title = title
        self.intro = intro
        self.sections = sections
        self.photos = photos
    }
}

public protocol DiaryWriter: Sendable {
    var name: String { get }
    func write(_ request: DiaryRequest, thumbnails: [String: Data]) async throws -> DiaryText
}

/// The instructions every model gets, whichever provider runs it.
public enum DiaryInstructions {
    public static let system = """
    You write the words for a shared online photobook of someone's trip: a title, a short intro, a diary entry for each chapter, and captions for each photo.

    Use only the facts you are given. Every name of a place, landmark, business, event or person, every number, and every thing you mention must come from the facts list. Describe what the scene labels say the photos show. Do not invent travel, arrivals, flights, meals, weather, feelings, activities or objects that the facts do not list. If a photo has few facts, keep its caption short and plain. Landmarks marked "near" were close by; say "near", never that someone visited them. Never name or identify a person; say "friends" or "we", or describe what people are doing.

    Keep it light and specific. Diary entries are one to three sentences in first person plural. Captions are one short line. Grid labels are two to four words. Instagram captions are one line plus up to four hashtags. Alt text plainly describes what is visible.

    Match the requested tone: warm is affectionate, dry is understated with a little wit, minimal is sparse and factual. If voice examples are given, match their style without copying them.
    """

    public static let jsonShape = """
    Reply with JSON only, in this shape:
    {"title": string, "intro": string,
     "sections": [{"id": chapter id, "heading": string, "diary": string}],
     "photos": [{"key": photo key, "label": string, "caption": string, "instagram_caption": string, "alt_text": string}]}
    Include one section for every chapter id and one photo entry for every photo key.
    """
}

/// Builds the book: chapters and grounded facts, text from a writer, every field
/// checked against the facts, and the offline writer as the fallback.
public enum TripBookComposer {
    public static func request(
        chapters: [BookSectioner.Chapter],
        facts: TripFacts,
        enrichment: [PhotoID: PhotoEnrichment] = [:],
        context: TripContext = .empty,
        tone: DiaryTone = .warm,
        voiceExamples: [String] = []
    ) -> (DiaryRequest, [String: PhotoFacts]) {
        var byKey: [String: PhotoFacts] = [:]
        var grounded: [GroundFact] = []
        func add(_ source: GroundFact.Source, _ text: String, scope: String? = nil) {
            grounded.append(GroundFact(id: "f\(grounded.count + 1)", source: source, text: text, scope: scope))
        }
        let range = BookSectioner.dateRange(for: facts)
        if !range.isEmpty { add(.time, "Trip dates: \(range)") }
        if let note = context.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { add(.owner, "The owner says: \(note)") }
        for event in context.calendarEvents { add(.calendar, "On the owner's calendar: \(event)") }

        var counter = 0
        let requestChapters = chapters.map { chapter -> DiaryRequest.Chapter in
            var timeFormat = Date.FormatStyle().hour().minute()
            timeFormat.timeZone = chapter.timeZone
            let when = BookSectioner.momentLine(for: chapter.start, timeZone: chapter.timeZone)
            let day = BookSectioner.dayLine(for: chapter.start, timeZone: chapter.timeZone)
            add(.time, "\(day), \(when)", scope: chapter.id)
            if let place = chapter.place?.display { add(.location, "Place: \(place)", scope: chapter.id) }
            var nearby: [String] = []
            for photo in chapter.photos {
                for name in enrichment[photo.id]?.nearby ?? [] where !nearby.contains(name) { nearby.append(name) }
            }
            for name in nearby.prefix(3) { add(.nearby, "Near \(name)", scope: chapter.id) }
            var sun: String?
            if let first = chapter.photos.first(where: { $0.latitude != nil }), let date = first.captureDate,
               let lat = first.latitude, let lon = first.longitude {
                sun = SunTimes.phrase(for: date, latitude: lat, longitude: lon)
                if let sun { add(.sun, "Photos taken \(sun)", scope: chapter.id) }
            }
            let photos = chapter.photos.map { photo -> DiaryRequest.Photo in
                counter += 1
                let key = "p\(counter)"
                byKey[key] = photo
                let labels = photo.labels.filter(\.isConfident).map(\.readable)
                if !labels.isEmpty { add(.scene, "Photo \(key) shows: " + labels.joined(separator: ", "), scope: key) }
                if photo.faceCount > 0 { add(.people, "Photo \(key): \(photo.faceCount) \(photo.faceCount == 1 ? "person" : "people")", scope: key) }
                let text = enrichment[photo.id]?.text ?? []
                for line in text { add(.photoText, "Photo \(key) has the words: \(line)", scope: key) }
                return DiaryRequest.Photo(
                    key: key,
                    time: photo.captureDate.map { $0.formatted(timeFormat) } ?? "",
                    labels: labels,
                    people: photo.faceCount,
                    orientation: photo.isPortraitOrientation ? "portrait" : "landscape",
                    text: text
                )
            }
            return DiaryRequest.Chapter(id: chapter.id, place: chapter.place?.display, when: when, day: day, nearby: Array(nearby.prefix(3)), sun: sun, photos: photos)
        }
        let request = DiaryRequest(
            dateRange: range,
            places: facts.places.map(\.display),
            chapters: requestChapters,
            facts: grounded,
            tone: tone,
            voiceExamples: voiceExamples
        )
        return (request, byKey)
    }

    public static func compose(
        facts: TripFacts,
        writer: any DiaryWriter,
        enrichment: [PhotoID: PhotoEnrichment] = [:],
        context: TripContext = .empty,
        thumbnail: (PhotoFacts) -> Data? = { _ in nil },
        tone: DiaryTone = .warm,
        voiceExamples: [String] = [],
        theme: BookTheme = .book
    ) async -> TripBook {
        let chapters = BookSectioner.chapters(for: facts)
        let (request, byKey) = self.request(chapters: chapters, facts: facts, enrichment: enrichment, context: context, tone: tone, voiceExamples: voiceExamples)
        var thumbnails: [String: Data] = [:]
        for (key, photo) in byKey { thumbnails[key] = thumbnail(photo) }

        var writerName = writer.name
        let text: DiaryText
        do {
            text = try await writer.write(request, thumbnails: thumbnails)
        } catch {
            writerName = TemplateDiaryWriter().name
            text = TemplateDiaryWriter().text(for: request)
        }
        var (checked, rejected) = ground(text, request: request)
        // The owner's own short note is the best title there is.
        if let note = context.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty, note.count <= 60 {
            checked.title = note.prefix(1).uppercased() + note.dropFirst()
        }
        var book = assemble(text: checked, request: request, byKey: byKey, chapters: chapters, writer: writerName, theme: theme)
        book.groundingRejections = rejected
        return book
    }

    /// Replaces any field that names something outside the facts with the
    /// offline writer's version of that field. Returns how many were replaced.
    public static func ground(_ text: DiaryText, request: DiaryRequest) -> (DiaryText, Int) {
        let fallback = TemplateDiaryWriter().text(for: request)
        let extra = request.voiceExamples + request.chapters.flatMap { [$0.when, $0.day] }
        let check = GroundingCheck(facts: request.facts, extra: extra)
        var rejected = 0
        func pick(_ value: String, _ safe: String) -> String {
            if check.accepts(value), !isLabelList(value) { return value }
            rejected += 1
            return safe
        }
        let safeSections = Dictionary(fallback.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let safePhotos = Dictionary(fallback.photos.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out = text
        out.title = pick(text.title, fallback.title)
        out.intro = pick(text.intro, fallback.intro)
        // Headings must differ from the title and from each other; a model that
        // reuses the owner's note for every chapter falls back to the place or time.
        func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        var seen: Set<String> = [normalized(out.title)]
        out.sections = text.sections.map { section in
            guard let safe = safeSections[section.id] else { return section }
            var heading = pick(section.heading, safe.heading)
            if seen.contains(normalized(heading)) {
                let when = request.chapters.first { $0.id == section.id }?.when.capitalizedFirst ?? safe.heading
                heading = seen.contains(normalized(safe.heading)) ? when : safe.heading
            }
            seen.insert(normalized(heading))
            return DiaryText.Section(id: section.id, heading: heading, diary: pick(section.diary, safe.diary))
        }
        out.photos = text.photos.map { photo in
            guard let safe = safePhotos[photo.key] else { return photo }
            return DiaryText.Photo(
                key: photo.key,
                label: pick(photo.label, safe.label),
                caption: pick(photo.caption, safe.caption),
                instagram_caption: pick(photo.instagram_caption, safe.instagram_caption),
                alt_text: pick(photo.alt_text, safe.alt_text)
            )
        }
        return (out, rejected)
    }

    /// "light, candle, fire, flame, night sky": a model repeating its input
    /// labels instead of writing a caption.
    static func isLabelList(_ text: String) -> Bool {
        let items = text.trimmingCharacters(in: CharacterSet(charactersIn: " .")).split(separator: ",")
        guard items.count >= 3 else { return false }
        return items.allSatisfy { $0.split(separator: " ").count <= 3 }
    }

    static func assemble(text: DiaryText, request: DiaryRequest, byKey: [String: PhotoFacts], chapters: [BookSectioner.Chapter], writer: String, theme: BookTheme) -> TripBook {
        let fallback = TemplateDiaryWriter().text(for: request)
        let sectionText = Dictionary(text.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let photoText = Dictionary(text.photos.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let fallbackSections = Dictionary(fallback.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fallbackPhotos = Dictionary(fallback.photos.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        let sections = zip(chapters, request.chapters).map { chapter, requested -> BookSection in
            let words = sectionText[chapter.id] ?? fallbackSections[chapter.id]
            // The same caption twice in a chapter reads like a mistake; repeats stay blank.
            var usedCaptions = Set<String>()
            func distinct(_ caption: String) -> String {
                let key = caption.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return caption }
                return usedCaptions.insert(key).inserted ? caption : ""
            }
            return BookSection(
                id: chapter.id,
                heading: words?.heading ?? "",
                dateLine: requested.day,
                place: requested.place,
                diary: words?.diary ?? "",
                photos: requested.photos.compactMap { photo in
                    guard let facts = byKey[photo.key] else { return nil }
                    let words = photoText[photo.key] ?? fallbackPhotos[photo.key]
                    return BookPhoto(
                        id: facts.id,
                        fileName: facts.fileName,
                        label: words?.label ?? "",
                        caption: distinct(words?.caption ?? ""),
                        instagramCaption: words?.instagram_caption ?? "",
                        altText: words?.alt_text ?? "",
                        isPortrait: facts.isPortraitOrientation
                    )
                }
            )
        }
        let cover = sections.flatMap(\.photos).first { !$0.isPortrait }?.id ?? sections.first?.photos.first?.id
        return TripBook(
            title: text.title.isEmpty ? fallback.title : text.title,
            intro: text.intro.isEmpty ? fallback.intro : text.intro,
            dateRange: request.dateRange,
            coverPhotoID: cover,
            sections: sections,
            writer: writer,
            theme: theme
        )
    }

    /// A 512-pixel JPEG for a model that looks at images.
    public static func thumbnailData(url: URL, maxPixel: Int = 512) -> Data? {
        guard let image = CGImage.photocoreThumbnail(url: url, maxPixel: maxPixel) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// The offline writer: plain, true sentences from the facts alone. Used when no
/// model is available and for any field the grounding check rejects.
public struct TemplateDiaryWriter: DiaryWriter {
    public init() {}
    public var name: String { "offline" }

    public func write(_ request: DiaryRequest, thumbnails: [String: Data]) async throws -> DiaryText {
        text(for: request)
    }

    public func text(for request: DiaryRequest) -> DiaryText {
        let title: String
        if let place = request.places.first {
            title = request.places.count > 1 ? "\(place) and beyond" : place
        } else {
            title = request.dateRange.isEmpty ? "Our trip" : request.dateRange
        }
        let count = request.chapters.reduce(0) { $0 + $1.photos.count }
        let days = Set(request.chapters.map(\.day)).count
        let intro = days > 1 ? "\(days) days, \(count) favorite photos." : "\(count) favorite photos" + (request.dateRange.isEmpty ? "." : " from \(request.dateRange).")
        let sections = request.chapters.map { chapter -> DiaryText.Section in
            let heading = chapter.place ?? chapter.when.capitalizedFirst
            var parts: [String] = []
            if let landmark = chapter.nearby.first { parts.append("Near \(landmark)") }
            if let sun = chapter.sun { parts.append(sun) }
            let labels = Self.topLabels(chapter.photos.flatMap(\.labels), limit: 2)
            if parts.isEmpty, !labels.isEmpty { parts.append(ListFormatter.localizedString(byJoining: labels).capitalizedFirst) }
            let diary = parts.isEmpty ? "" : parts.joined(separator: ", ").capitalizedFirst + "."
            return DiaryText.Section(id: chapter.id, heading: heading, diary: diary)
        }
        let photos = request.chapters.flatMap { chapter in
            chapter.photos.map { photo -> DiaryText.Photo in
                let top = Array(photo.labels.prefix(2))
                let label = top.first?.capitalizedFirst ?? (photo.people > 0 ? "People" : "Scene")
                // Sign text is a fact for models that can see the photo, but OCR
                // fragments ("TION BOX") make poor captions on their own.
                let caption: String
                if !top.isEmpty {
                    caption = ListFormatter.localizedString(byJoining: top).capitalizedFirst
                } else {
                    // Nothing true to say: an empty caption beats a filler.
                    caption = ""
                }
                let place = chapter.place.map { " · \($0)" } ?? ""
                let tags = photo.labels.prefix(3).map { "#" + $0.replacingOccurrences(of: " ", with: "") }.joined(separator: " ")
                let people = photo.people > 0 ? " with \(photo.people) \(photo.people == 1 ? "person" : "people")" : ""
                return DiaryText.Photo(
                    key: photo.key,
                    label: label,
                    caption: caption,
                    instagram_caption: (caption + place + " " + tags).trimmingCharacters(in: .whitespaces),
                    alt_text: "Photo" + (photo.labels.isEmpty ? "" : " of " + ListFormatter.localizedString(byJoining: Array(photo.labels.prefix(3)))) + people + "."
                )
            }
        }
        return DiaryText(title: title, intro: intro, sections: sections, photos: photos)
    }

    static func topLabels(_ labels: [String], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for label in labels { counts[label, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Any provider with an OpenAI-compatible chat completions API. DeepSeek and
/// Gemini both offer one; both accept images and return JSON objects.
public struct OpenAICompatibleDiaryWriter: DiaryWriter {
    public struct Provider: Sendable, Equatable {
        public var name: String
        public var baseURL: URL
        public var model: String
        public var sendsImages: Bool

        /// DeepSeek's fast model; accepts images and JSON output.
        public static let deepseek = Provider(name: "deepseek", baseURL: URL(string: "https://api.deepseek.com")!, model: "deepseek-flash", sendsImages: true)
        /// Google's cheapest current Gemini model with image input.
        public static let gemini = Provider(name: "gemini", baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!, model: "gemini-3.1-flash-lite", sendsImages: true)
    }

    public enum WriterError: Error, Equatable {
        case http(Int, String)
        case noText
    }

    public var provider: Provider
    public var apiKey: String
    public var session: URLSession

    public init(provider: Provider, apiKey: String, session: URLSession = .shared) {
        self.provider = provider
        self.apiKey = apiKey
        self.session = session
    }

    public var name: String { "\(provider.name):\(provider.model)" }

    func body(_ request: DiaryRequest, thumbnails: [String: Data]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let facts = String(decoding: try encoder.encode(request), as: UTF8.self)
        var content: [[String: Any]] = [["type": "text", "text": "Trip facts:\n" + facts]]
        if provider.sendsImages {
            for chapter in request.chapters {
                for photo in chapter.photos {
                    guard let data = thumbnails[photo.key] else { continue }
                    content.append(["type": "text", "text": "Photo \(photo.key)"])
                    content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]])
                }
            }
        }
        content.append(["type": "text", "text": "Write the book in a \(request.tone.rawValue) tone.\n\n" + DiaryInstructions.jsonShape])
        let body: [String: Any] = [
            "model": provider.model,
            "messages": [
                ["role": "system", "content": DiaryInstructions.system],
                ["role": "user", "content": content]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.6
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func urlRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: provider.baseURL.appendingPathComponent("chat/completions"), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func write(_ request: DiaryRequest, thumbnails: [String: Data]) async throws -> DiaryText {
        let (data, response) = try await session.data(for: urlRequest(body: body(request, thumbnails: thumbnails)))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw WriterError.http(status, String(decoding: data.prefix(500), as: UTF8.self)) }
        return try Self.parse(data)
    }

    public static func parse(_ data: Data) throws -> DiaryText {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              var text = message["content"] as? String else { throw WriterError.noText }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.drop(while: { $0 != "\n" }).dropFirst().description
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
        }
        return try JSONDecoder().decode(DiaryText.self, from: Data(text.utf8))
    }
}

/// Picks the writer. Order: an explicit choice in `PHOTOCORE_WRITER`; then a
/// hosted model when its key is configured (Gemini first, it is cheaper per
/// book and reads images well); then Apple's model (Private Cloud Compute on
/// OS 27, otherwise on-device); then the offline writer.
///
/// Measured on a real trip, Apple's small on-device model mostly repeats scene
/// labels, so a configured hosted key wins when quality matters.
public enum DiaryWriters {
    public static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> any DiaryWriter {
        let choice = environment["PHOTOCORE_WRITER"]?.lowercased()
        func hosted(_ provider: OpenAICompatibleDiaryWriter.Provider, key: String) -> (any DiaryWriter)? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            var provider = provider
            if let model = environment["PHOTOCORE_WRITER_MODEL"], !model.isEmpty { provider.model = model }
            return OpenAICompatibleDiaryWriter(provider: provider, apiKey: value)
        }
        switch choice {
        case "offline": return TemplateDiaryWriter()
        case "deepseek": return hosted(.deepseek, key: "DEEPSEEK_API_KEY") ?? TemplateDiaryWriter()
        case "gemini": return hosted(.gemini, key: "GEMINI_API_KEY") ?? TemplateDiaryWriter()
        case "apple": return AppleDiaryWriter.makeIfAvailable() ?? TemplateDiaryWriter()
        default:
            return hosted(.gemini, key: "GEMINI_API_KEY")
                ?? hosted(.deepseek, key: "DEEPSEEK_API_KEY")
                ?? AppleDiaryWriter.makeIfAvailable()
                ?? TemplateDiaryWriter()
        }
    }
}
