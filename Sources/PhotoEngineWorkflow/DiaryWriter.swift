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
/// the writer never sees file names or identifiers.
public struct DiaryRequest: Codable, Sendable {
    public struct Photo: Codable, Sendable {
        public var key: String
        public var time: String
        public var labels: [String]
        public var people: Int
        public var orientation: String
    }

    public struct Chapter: Codable, Sendable {
        public var id: String
        public var place: String?
        public var when: String
        public var day: String
        public var photos: [Photo]
    }

    public var dateRange: String
    public var places: [String]
    public var chapters: [Chapter]
    public var tone: DiaryTone
    public var voiceExamples: [String]
}

/// What a writer returns. Field names match the JSON schema sent to Claude.
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

/// Builds the book: chapters from the facts, text from a writer, and a fallback
/// to the offline writer if the model is unavailable or declines.
public enum TripBookComposer {
    public static func request(chapters: [BookSectioner.Chapter], facts: TripFacts, tone: DiaryTone = .warm, voiceExamples: [String] = []) -> (DiaryRequest, [String: PhotoFacts]) {
        var byKey: [String: PhotoFacts] = [:]
        var counter = 0
        let requestChapters = chapters.map { chapter in
            var timeFormat = Date.FormatStyle().hour().minute()
            timeFormat.timeZone = chapter.timeZone
            return DiaryRequest.Chapter(
                id: chapter.id,
                place: chapter.place?.display,
                when: BookSectioner.momentLine(for: chapter.start, timeZone: chapter.timeZone),
                day: BookSectioner.dayLine(for: chapter.start, timeZone: chapter.timeZone),
                photos: chapter.photos.map { photo in
                    counter += 1
                    let key = "p\(counter)"
                    byKey[key] = photo
                    return DiaryRequest.Photo(
                        key: key,
                        time: photo.captureDate.map { $0.formatted(timeFormat) } ?? "",
                        labels: photo.labels.map(\.readable),
                        people: photo.faceCount,
                        orientation: photo.isPortraitOrientation ? "portrait" : "landscape"
                    )
                }
            )
        }
        let request = DiaryRequest(
            dateRange: BookSectioner.dateRange(for: facts),
            places: facts.places.map(\.display),
            chapters: requestChapters,
            tone: tone,
            voiceExamples: voiceExamples
        )
        return (request, byKey)
    }

    public static func compose(
        facts: TripFacts,
        writer: any DiaryWriter,
        thumbnail: (PhotoFacts) -> Data? = { _ in nil },
        tone: DiaryTone = .warm,
        voiceExamples: [String] = [],
        theme: BookTheme = .book
    ) async -> TripBook {
        let chapters = BookSectioner.chapters(for: facts)
        let (request, byKey) = self.request(chapters: chapters, facts: facts, tone: tone, voiceExamples: voiceExamples)
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
        return assemble(text: text, request: request, byKey: byKey, chapters: chapters, writer: writerName, theme: theme)
    }

    static func assemble(text: DiaryText, request: DiaryRequest, byKey: [String: PhotoFacts], chapters: [BookSectioner.Chapter], writer: String, theme: BookTheme) -> TripBook {
        let fallback = TemplateDiaryWriter().text(for: request)
        let sectionText = Dictionary(text.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let photoText = Dictionary(text.photos.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let fallbackSections = Dictionary(fallback.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fallbackPhotos = Dictionary(fallback.photos.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        let sections = zip(chapters, request.chapters).map { chapter, requested -> BookSection in
            let words = sectionText[chapter.id] ?? fallbackSections[chapter.id]
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
                        caption: words?.caption ?? "",
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

    /// A 512-pixel JPEG for the model to look at, from the culling thumbnail or the source.
    public static func thumbnailData(url: URL, maxPixel: Int = 512) -> Data? {
        guard let image = CGImage.photocoreThumbnail(url: url, maxPixel: maxPixel) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// The offline writer: plain sentences from the facts alone. Used for the free
/// tier, when no API key is configured, and whenever the model is unavailable.
public struct TemplateDiaryWriter: DiaryWriter {
    public init() {}
    public var name: String { "template" }

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
        let intro = "\(count) favorite photos" + (request.dateRange.isEmpty ? "." : " from \(request.dateRange).")
        let sections = request.chapters.map { chapter -> DiaryText.Section in
            let labels = Self.topLabels(chapter.photos.flatMap(\.labels), limit: 2)
            let heading = chapter.place ?? chapter.when.capitalizedFirst
            let diary = labels.isEmpty ? "" : "Photos of " + ListFormatter.localizedString(byJoining: labels) + "."
            return DiaryText.Section(id: chapter.id, heading: heading, diary: diary)
        }
        let photos = request.chapters.flatMap { chapter in
            chapter.photos.map { photo -> DiaryText.Photo in
                let top = Array(photo.labels.prefix(2))
                let label = top.first?.capitalizedFirst ?? (photo.people > 0 ? "People" : "Scene")
                let caption = top.isEmpty ? (chapter.place ?? "") : ListFormatter.localizedString(byJoining: top).capitalizedFirst
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

/// Writes the diary with Claude over the Messages API. The model only sees the
/// shortlist's facts and 512-pixel thumbnails, never the whole roll.
public struct ClaudeDiaryWriter: DiaryWriter {
    public enum Credential: Sendable {
        case apiKey(String)
        case authToken(String)
    }

    public enum WriterError: Error, Equatable {
        case noCredential
        case http(Int, String)
        case refused(String?)
        case noText
    }

    public var credential: Credential
    public var model: String
    public var endpoint: URL
    public var session: URLSession

    public init(credential: Credential, model: String = "claude-opus-5-5", endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!, session: URLSession = .shared) {
        self.credential = credential
        self.model = model
        self.endpoint = endpoint
        self.session = session
    }

    /// Reads `ANTHROPIC_API_KEY`, then `ANTHROPIC_AUTH_TOKEN`.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeDiaryWriter? {
        if let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty { return ClaudeDiaryWriter(credential: .apiKey(key)) }
        if let token = environment["ANTHROPIC_AUTH_TOKEN"], !token.isEmpty { return ClaudeDiaryWriter(credential: .authToken(token)) }
        return nil
    }

    public var name: String { model }

    static let system = """
    You write the words for a shared online photobook of someone's trip: a title, a short intro, a diary entry for each chapter, and captions for each photo.

    Write only from the facts and photos you are given: chapter place names, times of day, scene labels, how many people appear, and the photos themselves. Do not invent events, names, relationships, food, weather or feelings the photos do not show. Never name or identify a person; say "friends", "we" or describe what they are doing. If a place is unknown, describe the scene instead of guessing a location.

    Keep it light and specific. Diary entries are two to four sentences in first person plural. Captions are one short line. Grid labels are two to four words. Instagram captions are one line plus up to four relevant hashtags. Alt text plainly describes what is visible for someone who cannot see the photo.

    Match the requested tone: warm is affectionate and present, dry is understated with a little wit, minimal is sparse and factual. If voice examples are given, match their style without copying them.

    Return one entry in "sections" for every chapter id and one entry in "photos" for every photo key.
    """

    static var schema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["title", "intro", "sections", "photos"],
        "properties": [
            "title": ["type": "string"],
            "intro": ["type": "string"],
            "sections": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["id", "heading", "diary"],
                    "properties": ["id": ["type": "string"], "heading": ["type": "string"], "diary": ["type": "string"]]
                ]
            ],
            "photos": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["key", "label", "caption", "instagram_caption", "alt_text"],
                    "properties": [
                        "key": ["type": "string"], "label": ["type": "string"], "caption": ["type": "string"],
                        "instagram_caption": ["type": "string"], "alt_text": ["type": "string"]
                    ]
                ]
            ]
        ]
    ] }

    func body(_ request: DiaryRequest, thumbnails: [String: Data]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let facts = String(decoding: try encoder.encode(request), as: UTF8.self)
        var content: [[String: Any]] = [["type": "text", "text": "Trip facts:\n" + facts]]
        for chapter in request.chapters {
            for photo in chapter.photos {
                guard let data = thumbnails[photo.key] else { continue }
                content.append(["type": "text", "text": "Photo \(photo.key)"])
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]])
            }
        }
        content.append(["type": "text", "text": "Write the book in a \(request.tone.rawValue) tone."])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16_000,
            "system": Self.system,
            "fallbacks": "default",
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": Self.schema]],
            "messages": [["role": "user", "content": content]]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    func urlRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var betas = ["server-side-fallback-2026-07-01"]
        switch credential {
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .authToken(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            betas.append("oauth-2025-04-20")
        }
        request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        return request
    }

    public func write(_ request: DiaryRequest, thumbnails: [String: Data]) async throws -> DiaryText {
        let (data, response) = try await session.data(for: urlRequest(body: body(request, thumbnails: thumbnails)))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw WriterError.http(status, String(decoding: data.prefix(500), as: UTF8.self))
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> DiaryText {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WriterError.noText }
        if object["stop_reason"] as? String == "refusal" {
            let details = object["stop_details"] as? [String: Any]
            throw WriterError.refused(details?["category"] as? String)
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw WriterError.noText
        }
        return try JSONDecoder().decode(DiaryText.self, from: Data(text.utf8))
    }
}
