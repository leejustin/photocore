import CoreGraphics
import Foundation
import ImageIO
import PhotoEngineApple
import PhotoEngineCore
import PhotoEngineWorkflow
import Testing

/// Answers every request with a canned response and records the last request.
final class MockAnthropic: URLProtocol, @unchecked Sendable {
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
        config.protocolClasses = [MockAnthropic.self]
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

    @Test("the Claude request carries facts, images, schema and fallbacks")
    func claudeRequest() async throws {
        let facts = Self.facts([(t0, "Alfama"), (t0.addingTimeInterval(60), "Alfama")], tz: 0)
        let (request, byKey) = TripBookComposer.request(chapters: BookSectioner.chapters(for: facts), facts: facts)
        let reply = DiaryText(title: "Two days in Alfama", intro: "Sun and sardines.", sections: [.init(id: "s1", heading: "Alfama", diary: "We walked.")],
                              photos: byKey.keys.sorted().map { .init(key: $0, label: "Beach", caption: "Morning swim", instagram_caption: "Swim #lisbon", alt_text: "A beach.") })
        let replyText = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        let envelope: [String: Any] = ["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": replyText]]]
        MockAnthropic.response = (200, try JSONSerialization.data(withJSONObject: envelope))
        let writer = ClaudeDiaryWriter(credential: .apiKey("test-key"), session: MockAnthropic.session())
        let thumbs = Dictionary(uniqueKeysWithValues: byKey.keys.map { ($0, Data([0xFF, 0xD8])) })
        let text = try await writer.write(request, thumbnails: thumbs)
        #expect(text == reply)

        let sent = try #require(MockAnthropic.lastRequest)
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(sent.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let body = try #require(MockAnthropic.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["fallbacks"] as? String == "default")
        let config = try #require(body["output_config"] as? [String: Any])
        #expect((config["format"] as? [String: Any])?["type"] as? String == "json_schema")
        #expect(body["thinking"] == nil, "Opus 5.5 rejects a disabled thinking config; omit it")
        let content = try #require(((body["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        #expect(content.filter { $0["type"] as? String == "image" }.count == 2)
        let factsText = content.first?["text"] as? String ?? ""
        #expect(!factsText.contains("IMG_"), "file names leaked to the model")
    }

    @Test("a refusal or outage falls back to the offline writer")
    func fallback() async throws {
        MockAnthropic.response = (200, try JSONSerialization.data(withJSONObject: ["stop_reason": "refusal", "stop_details": ["category": "cyber"], "content": []]))
        let facts = Self.facts([(t0, "Alfama")], tz: 0)
        let writer = ClaudeDiaryWriter(credential: .authToken("tok"), session: MockAnthropic.session())
        let book = await TripBookComposer.compose(facts: facts, writer: writer)
        #expect(book.writer == "template")
        #expect(book.allPhotos.count == 1)
        #expect(MockAnthropic.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(MockAnthropic.lastRequest?.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01,oauth-2025-04-20")

        MockAnthropic.response = (529, Data("{\"type\":\"error\"}".utf8))
        let again = await TripBookComposer.compose(facts: facts, writer: ClaudeDiaryWriter(credential: .apiKey("k"), session: MockAnthropic.session()))
        #expect(again.writer == "template")
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
