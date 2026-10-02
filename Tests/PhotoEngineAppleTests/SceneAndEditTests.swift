import CoreGraphics
import CoreImage
import CoreLocation
import Foundation
import ImageIO
import PhotoEngineApple
import PhotoEngineCore
import PhotoEngineWorkflow
import Testing

extension VisionSuites {
    @Suite("Scene understanding and subject edits")
    struct SceneAndEditTests {
        @Test("GPS is read from EXIF with hemisphere signs")
        func gpsRead() throws {
            let folder = try SyntheticPhotos.makeFolder(count: 1)
            defer { try? FileManager.default.removeItem(at: folder) }
            let image = try #require(CGImage.photocoreThumbnail(url: folder.appendingPathComponent("IMG_0000.jpg")))
            try PhotoLibraryIngest.writeJPEG(image, date: Date(), location: CLLocation(latitude: -33.86, longitude: 151.21), to: folder.appendingPathComponent("IMG_0000.jpg"))
            let imported = try PhotoFolderImporter().importFolder(folder)
            let metadata = try #require(imported.first?.asset.metadata)
            #expect(abs((metadata.latitude ?? 0) - -33.86) < 0.001)
            #expect(abs((metadata.longitude ?? 0) - 151.21) < 0.001)
        }

        @Test("crops keep the target shape, stay in frame and follow the subject")
        func cropGeometry() {
            let focus = NormalizedCrop(x: 0.75, y: 0.3, width: 0.2, height: 0.3)
            for aspect in CropAspect.allCases {
                let crop = SaliencyCropper.crop(imageWidth: 4000, imageHeight: 3000, aspect: aspect.ratio, focus: focus)
                let ratio = (crop.width * 4000) / (crop.height * 3000)
                #expect(abs(ratio - aspect.ratio) < 0.01, "\(aspect.rawValue) came out \(ratio)")
                #expect(crop.x >= 0 && crop.y >= 0 && crop.x + crop.width <= 1.0001 && crop.y + crop.height <= 1.0001)
                #expect(crop.x + crop.width / 2 > 0.5, "\(aspect.rawValue) crop did not move toward the subject")
            }
            let centered = SaliencyCropper.crop(imageWidth: 3000, imageHeight: 4000, aspect: CropAspect.portrait.ratio, focus: nil)
            #expect(abs(centered.x + centered.width / 2 - 0.5) < 0.01)
        }

        @Test("place names prefer landmarks, then neighborhoods, then towns")
        func placeNames() {
            #expect(PlaceNamer.place(areasOfInterest: ["Belém Tower"], subLocality: "Belém", locality: "Lisbon", administrativeArea: nil, country: "Portugal")?.display == "Belém Tower, Lisbon")
            #expect(PlaceNamer.place(areasOfInterest: [], subLocality: "Alfama", locality: "Lisbon", administrativeArea: nil, country: "Portugal")?.display == "Alfama, Lisbon")
            #expect(PlaceNamer.place(areasOfInterest: [], subLocality: nil, locality: "Lisbon", administrativeArea: nil, country: "Portugal")?.display == "Lisbon")
            #expect(PlaceNamer.place(areasOfInterest: [], subLocality: nil, locality: nil, administrativeArea: nil, country: nil) == nil)
        }

        @Test("nearby coordinates share one lookup cell and the cache persists")
        func placeCache() async throws {
            #expect(PlaceNamer.cellKey(latitude: 38.7101, longitude: -9.1402) == PlaceNamer.cellKey(latitude: 38.7124, longitude: -9.1381))
            #expect(PlaceNamer.cellKey(latitude: 38.71, longitude: -9.14) != PlaceNamer.cellKey(latitude: 38.76, longitude: -9.14))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("places-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let namer = PlaceNamer(cacheURL: url)
            await namer.store(PlaceName(name: "Alfama", locality: "Lisbon"), latitude: 38.711, longitude: -9.13)
            let reopened = PlaceNamer(cacheURL: url)
            let hit = await reopened.cached(latitude: 38.712, longitude: -9.131)
            #expect(hit?.display == "Alfama, Lisbon")
            let named = await reopened.names(for: [(38.712, -9.131)])
            #expect(named.count == 1)
        }

        @Test("the finish render lifts a subject more than its background")
        func subjectLift() throws {
            let image = try Self.subjectImage()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subj-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("subject.jpg")
            try PhotoLibraryIngest.writeJPEG(image, date: nil, location: nil, to: url)

            let output = try FinishRenderer.render(url: url, maxPixel: 800)
            let rendered = try #require(CGImageSourceCreateWithData(output.jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            #expect(rendered.width == 800)
            #if os(macOS)
            #expect(output.maskSource != .none, "no subject mask on macOS")
            #endif
            guard output.maskSource != .none else {
                // The iOS simulator has no segmentation models; the render still succeeds.
                return
            }
            let center = CGRect(x: 0.42, y: 0.42, width: 0.16, height: 0.16)
            let corner = CGRect(x: 0.02, y: 0.02, width: 0.12, height: 0.12)
            let lift = Self.luma(rendered, in: center) - Self.luma(image, in: center)
            let backgroundChange = Self.luma(rendered, in: corner) - Self.luma(image, in: corner)
            #expect(lift > backgroundChange + 0.02, "subject lift \(lift) vs background \(backgroundChange)")
        }

        @Test("trip facts cover every keeper with three crops")
        func tripFacts() async throws {
            let folder = try SyntheticPhotos.makeFolder(count: 6)
            defer { try? FileManager.default.removeItem(at: folder) }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("facts-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: output) }
            var profile = ScoringProfile.default(for: .trip)
            profile.targetCount = 4
            let result = try PhotoPipelineRunner().run(folder: folder, outputDirectory: output, profile: profile, exportSpecification: ExportSpecification(preset: .compact))
            let keepers = KeeperSelection(result: result).ordered(in: result)
            let facts = await TripFactsBuilder.build(keepers: keepers, lookUpPlaces: false)
            #expect(facts.photos.count == keepers.count)
            #expect(facts.photos.allSatisfy { $0.crops.count == 3 })
            try facts.save(to: output)
            #expect(try TripFacts.load(from: output) == facts)
        }

        @Test("render real photos for an eye check")
        func eyeCheck() throws {
            guard let dir = ProcessInfo.processInfo.environment["PHOTOCORE_EYE_DIR"], let out = ProcessInfo.processInfo.environment["PHOTOCORE_EYE_OUT"] else { return }
            let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.uppercased().hasSuffix(".JPG") }.sorted()
            for name in files {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                let rendered = try FinishRenderer.render(url: url, maxPixel: 1200, settings: ProcessInfo.processInfo.environment["PHOTOCORE_EYE_PORTRAIT"] == "1" ? .portrait : .natural)
                try rendered.jpeg.write(to: URL(fileURLWithPath: out).appendingPathComponent("finish-" + name))
                let labels = CGImage.photocoreThumbnail(url: url).map { SceneLabeler.labels(for: $0).map(\.identifier) } ?? []
                print("EYE", name, rendered.maskSource.rawValue, labels)
            }
        }

        static func subjectImage() throws -> CGImage {
            let width = 800, height = 600
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: 0.45, green: 0.5, blue: 0.55, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(red: 0.55, green: 0.3, blue: 0.2, alpha: 1)
            context.fillEllipse(in: CGRect(x: 250, y: 150, width: 300, height: 300))
            context.setFillColor(red: 0.95, green: 0.8, blue: 0.2, alpha: 1)
            context.fillEllipse(in: CGRect(x: 340, y: 250, width: 120, height: 100))
            return try #require(context.makeImage())
        }

        static func luma(_ image: CGImage, in normalized: CGRect) -> Double {
            let side = 64
            guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            guard let data = context.data else { return 0 }
            let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
            var sum = 0.0, count = 0.0
            let x0 = Int(normalized.minX * Double(side)), x1 = Int(normalized.maxX * Double(side))
            let y0 = Int(normalized.minY * Double(side)), y1 = Int(normalized.maxY * Double(side))
            for y in y0..<y1 { for x in x0..<x1 {
                let o = (y * side + x) * 4
                sum += (0.299 * Double(pixels[o]) + 0.587 * Double(pixels[o + 1]) + 0.114 * Double(pixels[o + 2])) / 255
                count += 1
            } }
            return count > 0 ? sum / count : 0
        }
    }
}
