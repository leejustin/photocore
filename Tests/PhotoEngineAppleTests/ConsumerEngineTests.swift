import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PhotoEngineApple
import PhotoEngineCore
import Testing

@Suite("On-device consumer engine")
struct ConsumerEngineTests {
    @Test("library file names are flat and stable")
    func libraryFileNames() {
        let name = LibraryExportIndex.fileName(for: "9F1C2B7E-1D2A-4C55-9A2B-00F00D/L0/001")
        #expect(name == "9F1C2B7E-1D2A-4C55-9A2B-00F00D_L0_001.jpg")
        #expect(!name.contains("/"))
    }

    @Test("export index round-trips and knows what is current")
    func exportIndex() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let modified = Date(timeIntervalSince1970: 1_000)
        let photoID = "A/L0/001", receiptID = "B/L0/001"
        var index = LibraryExportIndex()
        let photoName = LibraryExportIndex.fileName(for: photoID)
        index.entries[photoName] = LibraryExportEntry(fileName: photoName, localIdentifier: photoID, creationDate: nil, modificationDate: modified)
        let receiptName = LibraryExportIndex.fileName(for: receiptID)
        index.entries[receiptName] = LibraryExportEntry(fileName: receiptName, localIdentifier: receiptID, creationDate: nil, modificationDate: modified, utility: .document)
        try index.save(to: folder)

        let loaded = LibraryExportIndex.load(from: folder)
        #expect(loaded == index)
        #expect(loaded.utilityCount == 1)
        #expect(loaded.localIdentifier(forFile: photoName) == photoID)
        // The photo's file is missing, so it must be re-exported.
        #expect(!loaded.isCurrent(localIdentifier: photoID, modificationDate: modified, in: folder))
        try Data([0xFF]).write(to: folder.appendingPathComponent(photoName))
        #expect(loaded.isCurrent(localIdentifier: photoID, modificationDate: modified, in: folder))
        // An edit in Photos changes the modification date and forces a re-export.
        #expect(!loaded.isCurrent(localIdentifier: photoID, modificationDate: modified.addingTimeInterval(5), in: folder))
        // Utility frames have no file and stay skipped.
        #expect(loaded.isCurrent(localIdentifier: receiptID, modificationDate: modified, in: folder))
    }

    @Test("exported thumbnails carry date and location for the engine")
    func thumbnailMetadata() throws {
        let folder = try SyntheticPhotos.makeFolder(count: 1)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("IMG_0000.jpg")
        let image = try #require(CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let out = folder.appendingPathComponent("out.jpg")
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        try PhotoLibraryIngest.writeJPEG(image, date: date, location: .init(latitude: 38.71, longitude: -9.14), to: out)
        let properties = try #require(CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
        let gps = try #require(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect(gps[kCGImagePropertyGPSLongitudeRef] as? String == "W")
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] != nil)
    }

    @Test("a page of text is a document, a photo is not")
    func documentDetection() throws {
        let receipt = try Self.textImage(lines: (1...16).map { "ITEM \($0)   COFFEE BEANS   $\($0).99" })
        #expect(UtilityShotDetector.classify(receipt) == .document)

        let folder = try SyntheticPhotos.makeFolder(count: 6)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<6 {
            let url = folder.appendingPathComponent(String(format: "IMG_%04d.jpg", index))
            let photo = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            #expect(UtilityShotDetector.classify(photo) == .none, "synthetic photo \(index) flagged as a document")
        }
        // One large false box, or a sign with a couple of lines, is not a document.
        #expect(UtilityShotDetector.classify(textCoverage: 0.48, lineCount: 1) == .none)
        #expect(UtilityShotDetector.classify(textCoverage: 0.10, lineCount: 3) == .none)
    }

    @Test("auto-enhance renders a JPEG")
    func autoEnhance() throws {
        let folder = try SyntheticPhotos.makeFolder(count: 1)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try AutoEnhance.render(url: folder.appendingPathComponent("IMG_0000.jpg"), maxPixel: 512)
        let source = try #require(CGImageSourceCreateWithData(result.jpeg as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
    }

    @Test("a cancelled cull resumes from its checkpoint")
    func resumableCull() throws {
        let folder = try SyntheticPhotos.makeFolder(count: 16)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        var profile = ScoringProfile.default(for: .trip)
        profile.targetCount = 6

        var runner = PhotoPipelineRunner()
        runner.checkpointInterval = 4
        let counter = Counter()
        #expect(throws: (any Error).self) {
            _ = try runner.run(folder: folder, outputDirectory: output, profile: profile, exportSpecification: ExportSpecification(preset: .compact), progress: { event in
                if event.stage == .analyzing { counter.increment() }
            }, shouldCancel: { counter.value >= 6 })
        }
        let resumed = try runner.run(folder: folder, outputDirectory: output, profile: profile, exportSpecification: ExportSpecification(preset: .compact))
        #expect(resumed.metrics.cacheHits >= 4, "only \(resumed.metrics.cacheHits) cache hits after resume")
        #expect(resumed.analyzed.count == 16)
    }

    @Test("keepers map back to Photos identifiers")
    func keeperIdentifiers() throws {
        let folder = try SyntheticPhotos.makeFolder(count: 8)
        defer { try? FileManager.default.removeItem(at: folder) }
        var index = LibraryExportIndex()
        for i in 0..<8 {
            let name = String(format: "IMG_%04d.jpg", i)
            index.entries[name] = LibraryExportEntry(fileName: name, localIdentifier: "asset-\(i)/L0/001", creationDate: nil, modificationDate: nil)
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        var profile = ScoringProfile.default(for: .trip)
        profile.targetCount = 4
        let result = try PhotoPipelineRunner().run(folder: folder, outputDirectory: output, profile: profile, exportSpecification: ExportSpecification(preset: .compact))
        let ids = index.localIdentifiers(for: result.shortlist.selectedIDs, in: result)
        #expect(ids.count == result.shortlist.selectedIDs.count)
        #expect(ids.allSatisfy { $0.hasPrefix("asset-") })
    }

    static func textImage(lines: [String]) throws -> CGImage {
        let width = 900, height = 1200
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Courier" as CFString, 40, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): black
            ])
            context.textPosition = CGPoint(x: 40, y: height - 80 - index * 66)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return try #require(context.makeImage())
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

