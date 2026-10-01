import CoreGraphics
import Foundation
import ImageIO
import PhotoEngineApple
import PhotoEngineCore
import PhotoEngineWorkflow
import Testing

/// Answers every request with a canned response and records the last request.
final class MockProvider: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, Data) = (200, Data())
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: Self.response.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProvider.self]
        return URLSession(configuration: config)
    }
}

@Suite("Trip book", .serialized)
struct TripBookTests {
    static func facts(_ entries: [(Date, String?)], tz: Int? = nil) -> TripFacts {
        TripFacts(photos: entries.enumerated().map { index, entry in
            PhotoFacts(
                id: PhotoID(), fileName: "IMG_\(index).jpg", captureDate: entry.0, latitude: nil, longitude: nil,
                place: entry.1.map { PlaceName(name: $0) }, labels: [SceneLabel(identifier: index % 2 == 0 ? "beach" : "food", confidence: 0.9)],
                faceCount: index % 3, crops: [:], pixelWidth: 4000, pixelHeight: 3000, utcOffsetSeconds: tz
            )
        })
    }

    let t0 = ISO8601DateFormatter().date(from: "2026-06-12T09:00:00Z")!

    @Test("chapters split on day, place, long pauses and size")
    func chapters() {
        let facts = Self.facts([
            (t0, "Alfama"), (t0.addingTimeInterval(600), "Alfama"),
            (t0.addingTimeInterval(1_200), "Belém"),
            (t0.addingTimeInterval(1_200 + 5 * 3600), "Belém"),
            (t0.addingTimeInterval(86_400), nil)
        ], tz: 0)
        let chapters = BookSectioner.chapters(for: facts)
        #expect(chapters.map(\.photos.count) == [2, 1, 1, 1])
        #expect(chapters.first?.place?.name == "Alfama")
        let big = Self.facts((0..<30).map { (t0.addingTimeInterval(Double($0) * 60), nil) }, tz: 0)
        #expect(BookSectioner.chapters(for: big, maximumPhotos: 12).map(\.photos.count) == [12, 12, 6])
    }

    @Test("local time follows GPS place, then camera offset")
    func localTime() {
        var photo = Self.facts([(t0, nil)], tz: -7 * 3600).photos[0]
        #expect(photo.localTimeZone.secondsFromGMT(for: t0) == -7 * 3600)
        photo.place = PlaceName(name: "Taipei", timeZoneIdentifier: "Asia/Taipei")
        #expect(photo.localTimeZone.identifier == "Asia/Taipei")
        // 09:00 UTC is 17:00 in Taipei.
        #expect(BookSectioner.momentLine(for: t0, timeZone: photo.localTimeZone).hasSuffix("afternoon") == false)
        #expect(BookSectioner.momentLine(for: t0, timeZone: photo.localTimeZone).hasSuffix("evening"))
    }

    @Test("only known keys can be edited and edits survive regeneration")
    func edits() {
        #expect(BookEdits.isAllowed(key: "title"))
        #expect(BookEdits.isAllowed(key: "section.s1.diary"))
        #expect(BookEdits.isAllowed(key: "photo.ABC.caption"))
        #expect(!BookEdits.isAllowed(key: "photo.ABC.fileName"))
        #expect(!BookEdits.isAllowed(key: "theme"))
        let facts = Self.facts([(t0, "Alfama"), (t0.addingTimeInterval(60), "Alfama")], tz: 0)
        let (request, byKey) = TripBookComposer.request(chapters: BookSectioner.chapters(for: facts), facts: facts)
        let text = TemplateDiaryWriter().text(for: request)
        #expect(Set(text.photos.map(\.key)) == Set(byKey.keys))
        #expect(text.sections.map(\.id) == ["s1"])
        var edits = BookEdits()
        edits.values["title"] = "Lisbon with friends"
        edits.values["photo.\(facts.photos[0].id.description).caption"] = "First swim"
        edits.hiddenPhotoIDs = [facts.photos[1].id]
        let book = TripBook(title: "Alfama", intro: "x", dateRange: "", coverPhotoID: nil,
                            sections: [BookSection(id: "s1", heading: "Alfama", dateLine: "", place: "Alfama", diary: "",
                                                   photos: facts.photos.map { BookPhoto(id: $0.id, fileName: $0.fileName, caption: "auto") })],
                            writer: "template", theme: .book)
        let applied = edits.applied(to: book)
        #expect(applied.title == "Lisbon with friends")
        #expect(applied.allPhotos.map(\.caption) == ["First swim"])
    }

    static func reply(_ text: DiaryText) throws -> Data {
        let content = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    @Test("the DeepSeek and Gemini writer sends facts and images and parses JSON")
    func hostedWriter() async throws {
        let facts = Self.facts([(t0, "Alfama"), (t0.addingTimeInterval(60), "Alfama")], tz: 0)
        let (request, byKey) = TripBookComposer.request(chapters: BookSectioner.chapters(for: facts), facts: facts)
        let reply = DiaryText(title: "Alfama", intro: "Two photos.", sections: [.init(id: "s1", heading: "Alfama", diary: "Beach and food.")],
                              photos: byKey.keys.sorted().map { .init(key: $0, label: "Beach", caption: "Beach", instagram_caption: "Beach #beach", alt_text: "A beach.") })
        MockProvider.response = (200, try Self.reply(reply))
        for provider in [OpenAICompatibleDiaryWriter.Provider.deepseek, .gemini] {
            let writer = OpenAICompatibleDiaryWriter(provider: provider, apiKey: "k-\(provider.name)", session: MockProvider.session())
            let thumbs = Dictionary(uniqueKeysWithValues: byKey.keys.map { ($0, Data([0xFF, 0xD8])) })
            #expect(try await writer.write(request, thumbnails: thumbs) == reply)
            let sent = try #require(MockProvider.lastRequest)
            #expect(sent.url?.absoluteString == provider.baseURL.absoluteString + "/chat/completions")
            #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer k-\(provider.name)")
            let body = try #require(MockProvider.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            #expect(body["model"] as? String == provider.model)
            #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")
            let messages = try #require(body["messages"] as? [[String: Any]])
            let user = try #require(messages.last?["content"] as? [[String: Any]])
            #expect(user.filter { $0["type"] as? String == "image_url" }.count == 2)
            let sentText = user.first?["text"] as? String ?? ""
            #expect(!sentText.contains("IMG_"), "file names leaked to the model: \(sentText.components(separatedBy: "IMG_").first?.suffix(120) ?? "")")
        }
    }

    @Test("a fenced JSON reply still parses")
    func fencedReply() throws {
        let text = DiaryText(title: "T", intro: "I", sections: [], photos: [])
        let inner = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "```json\n" + inner + "\n```"]]]])
        #expect(try OpenAICompatibleDiaryWriter.parse(data) == text)
    }

    @Test("an outage falls back to the offline writer")
    func fallback() async throws {
        MockProvider.response = (529, Data("{}".utf8))
        let facts = Self.facts([(t0, "Alfama")], tz: 0)
        let writer = OpenAICompatibleDiaryWriter(provider: .gemini, apiKey: "k", session: MockProvider.session())
        let book = await TripBookComposer.compose(facts: facts, writer: writer)
        #expect(book.writer == "offline")
        #expect(book.allPhotos.count == 1)
    }

    @Test("invented names, numbers, things and events are replaced with facts")
    func grounding() async throws {
        let facts = Self.facts([(t0, "Alfama"), (t0.addingTimeInterval(60), "Alfama")], tz: 0)
        let (request, byKey) = TripBookComposer.request(chapters: BookSectioner.chapters(for: facts), facts: facts, context: TripContext(note: "Sam's birthday weekend"))
        let check = GroundingCheck(facts: request.facts)
        #expect(check.accepts("A beach in Alfama for Sam's birthday."))
        #expect(check.accepts("Food on the beach, a good evening with friends."))
        #expect(!check.accepts("Dinner at Cervejaria Ramiro."), "an invented restaurant passed")
        #expect(!check.accepts("We arrived after a 12 hour flight."), "an invented flight passed")
        #expect(!check.accepts("The stars came out over the balcony."), "invented objects passed")
        #expect(!check.accepts("We ate sardines."), "an invented meal passed")

        let invented = DiaryText(
            title: "Lisbon with Maria", intro: "Beach and food in Alfama.",
            sections: [.init(id: "s1", heading: "Alfama", diary: "We arrived after a long flight and ate sardines.")],
            photos: byKey.keys.sorted().map { .init(key: $0, label: "Beach", caption: "Food on the beach", instagram_caption: "#beach", alt_text: "A beach.") }
        )
        let (checked, rejected) = TripBookComposer.ground(invented, request: request)
        #expect(rejected == 2)
        #expect(!checked.title.contains("Maria"))
        #expect(!checked.sections[0].diary.contains("sardines"))
        #expect(checked.photos.allSatisfy { $0.caption == "Food on the beach" })
    }

    @Test("sun times land near the published values")
    func sunTimes() throws {
        // Lisbon, 21 June 2026: sunrise about 05:12 UTC, sunset about 20:05 UTC.
        let day = ISO8601DateFormatter().date(from: "2026-06-21T12:00:00Z")!
        let times = try #require(SunTimes.compute(date: day, latitude: 38.72, longitude: -9.14))
        let utc = Calendar(identifier: .gregorian)
        var c = utc; c.timeZone = TimeZone(identifier: "UTC")!
        #expect(abs(c.component(.hour, from: times.sunrise) * 60 + c.component(.minute, from: times.sunrise) - (5 * 60 + 12)) <= 6)
        #expect(abs(c.component(.hour, from: times.sunset) * 60 + c.component(.minute, from: times.sunset) - (20 * 60 + 5)) <= 6)
        #expect(SunTimes.phrase(for: times.sunset.addingTimeInterval(600), latitude: 38.72, longitude: -9.14) == "around sunset")
        #expect(SunTimes.phrase(for: day, latitude: 38.72, longitude: -9.14) == nil)
        #expect(SunTimes.compute(date: day, latitude: 80, longitude: 0) == nil, "midnight sun has no sunset")
    }

    @Test("only sign-like text is kept from photos")
    func signText() {
        #expect(PhotoTextReader.isSignLike("PASTÉIS DE BELÉM"))
        #expect(!PhotoTextReader.isSignLike("12:45"))
        #expect(!PhotoTextReader.isSignLike("ok"))
        #expect(!PhotoTextReader.isSignLike(String(repeating: "word ", count: 12)))
    }

    @Test("the writer choice follows configuration")
    func writerChoice() {
        #expect(DiaryWriters.make(environment: ["PHOTOCORE_WRITER": "offline"]).name == "offline")
        #expect(DiaryWriters.make(environment: ["GEMINI_API_KEY": "g", "DEEPSEEK_API_KEY": "d"]).name == "gemini:gemini-3.1-flash-lite")
        #expect(DiaryWriters.make(environment: ["PHOTOCORE_WRITER": "deepseek", "DEEPSEEK_API_KEY": "d"]).name == "deepseek:deepseek-flash")
        #expect(DiaryWriters.make(environment: ["PHOTOCORE_WRITER": "gemini", "GEMINI_API_KEY": "g", "PHOTOCORE_WRITER_MODEL": "gemini-x"]).name == "gemini:gemini-x")
        #expect(DiaryWriters.make(environment: ["PHOTOCORE_WRITER": "deepseek"]).name == "offline", "a missing key must not crash")
    }

    @Test("the page escapes text and only shows guest tools when enabled")
    func html() {
        let id = PhotoID()
        let book = TripBook(title: "<script>alert(1)</script>", intro: "Tom & Jerry", dateRange: "June", coverPhotoID: id,
                            sections: [BookSection(id: "s1", heading: "Beach", dateLine: "Friday", place: nil, diary: "We swam.",
                                                   photos: [BookPhoto(id: id, fileName: "a.HEIC", caption: "\"quoted\"", altText: "x\"onerror=\"y")])],
                            writer: "template", theme: .book)
        let plain = BookRenderer.html(book)
        #expect(!plain.contains("<script>alert"))
        #expect(plain.contains("Tom &amp; Jerry"))
        #expect(plain.contains("photos/a.jpg"))
        #expect(!plain.contains("onerror=\"y"))
        #expect(!plain.contains("id=\"note-form\""))
        #expect(plain.contains("data-key=\"photo.\(id.description).caption\""))
        let social = BookRenderer.html(book, options: .init(editEndpoint: "/v1/books/x/edits", guestEndpoint: "/v1/books/x/guest"))
        #expect(social.contains("id=\"note-form\""))
        #expect(social.contains("\"/v1/books/x/guest\""))
    }

    @Test("chapters open on a single photo, then pair portraits and alternate landscapes")
    func layoutRows() {
        func photo(_ portrait: Bool) -> BookPhoto { BookPhoto(id: PhotoID(), fileName: "x.jpg", isPortrait: portrait) }
        let land = (0..<5).map { _ in photo(false) }
        let tall = (0..<3).map { _ in photo(true) }
        let rows = BookRenderer.rows(for: [land[0], tall[0], land[1], tall[1], land[2], land[3], land[4], tall[2]])
        #expect(rows.first?.count == 1, "the opener is a single photo")
        #expect(rows.contains { $0.count == 2 && $0.allSatisfy(\.isPortrait) }, "portraits are paired")
        #expect(rows.flatMap { $0 }.count == 8, "no photo is lost or repeated")
        #expect(Set(rows.flatMap { $0 }.map(\.id)).count == 8)
        #expect(BookRenderer.rows(for: []).isEmpty)
        #expect(BookRenderer.rows(for: [land[0]]).map(\.count) == [1])
    }

    @Test("the carousel walks through every chapter, cover first")
    func carouselPick() {
        let sections = (1...3).map { s in
            BookSection(id: "s\(s)", heading: "", dateLine: "", place: nil, diary: "", photos: (1...5).map { _ in BookPhoto(id: PhotoID(), fileName: "x.jpg") })
        }
        let cover = sections[1].photos[2].id
        let book = TripBook(title: "T", intro: "", dateRange: "", coverPhotoID: cover, sections: sections, writer: "t", theme: .book)
        let picked = InstagramPack.pick(book: book, limit: 4)
        #expect(picked.first?.id == cover)
        #expect(picked.map(\.id) == [cover, sections[0].photos[0].id, sections[1].photos[0].id, sections[2].photos[0].id])
    }
}

extension VisionSuites {
    @Suite("Book publish")
    struct BookPublishTests {
        @Test("publishing writes the page, finished photos and exact social sizes")
        func publish() async throws {
            let folder = try SyntheticPhotos.makeFolder(count: 6)
            defer { try? FileManager.default.removeItem(at: folder) }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: out) }
            var profile = ScoringProfile.default(for: .trip)
            profile.targetCount = 4
            let result = try PhotoPipelineRunner().run(folder: folder, outputDirectory: out.appendingPathComponent("cull"), profile: profile, exportSpecification: ExportSpecification(preset: .compact))
            let keepers = KeeperSelection(result: result).ordered(in: result)
            let facts = await TripFactsBuilder.build(keepers: keepers, lookUpPlaces: false)
            let urls = Dictionary(uniqueKeysWithValues: keepers.map { ($0.id, $0.asset.url) })
            let book = await TripBookComposer.compose(facts: facts, writer: TemplateDiaryWriter())
            let report = try BookPublisher.publish(book: book, facts: facts, source: { urls[$0.id] }, to: out, maxPixel: 800)
            #expect(report.photoCount == keepers.count)
            #expect(FileManager.default.fileExists(atPath: report.indexURL.path))
            for photo in book.allPhotos {
                #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent(BookRenderer.photoPath(photo)).path))
            }
            let carousel = out.appendingPathComponent("instagram/carousel-01.jpg")
            let props = try #require(CGImageSourceCreateWithURL(carousel as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
            #expect(props[kCGImagePropertyPixelWidth] as? Int == 1080)
            #expect(props[kCGImagePropertyPixelHeight] as? Int == 1350)
            #expect(try String(contentsOf: out.appendingPathComponent("instagram/caption.txt"), encoding: .utf8).isEmpty == false)
            #expect(try TripBook.load(from: out) == book)
        }
    }
}
