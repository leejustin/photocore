import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

import PhotoEngineApple
import PhotoEngineCore
import PhotoEnginePersistence

@main
struct PhotoEngineChecks {
    static func main() throws {
        let checks: [(String, () throws -> Void)] = [
            ("exact copies group globally", exactCopiesGroupGlobally),
            ("burst groups do not chain", burstGroupingUsesFixedRepresentative),
            ("burst duration is bounded", burstDurationIsBounded),
            ("selection honors its target", selectionHonorsTarget),
            ("selection is deterministic", selectionIsDeterministic),
            ("culling controls and style recipes", cullingControlsAndStyleRecipes),
            ("Vision feature prints round-trip", visionFeaturePrintRoundTrip),
            ("catalog persists session records", catalogPersistsSession),
            ("cleanup preview is conservative", cleanupPreviewIsConservative),
            ("import IDs and warnings", stableIDsAndImportWarnings),
            ("run directories are isolated", isolatedRunDirectories),
            ("metadata policy", metadataPolicy),
            ("nested output is rejected", rejectsNestedOutput)
        ]

        for (name, check) in checks {
            try check()
            print("✓ \(name)")
        }
        print("All \(checks.count) regression checks passed")
    }

    private static func exactCopiesGroupGlobally() throws {
        let photos = [
            analyzed(index: 0, hash: "same", perceptualHash: 0, date: nil),
            analyzed(index: 1, hash: "same", perceptualHash: .max, date: nil),
            analyzed(index: 2, hash: "other", perceptualHash: 0, date: nil)
        ]
        let grouping = PhotoGroupingEngine.group(photos, profile: .default(for: .everyday))
        try expect(grouping.groups.count == 1, "expected one exact-copy group")
        try expect(grouping.groups[0].kind == .exactDuplicate, "expected exact duplicate kind")
        try expect(grouping.groups[0].memberIDs.count == 2, "expected two exact copies")
        let scored = photos.map {
            ScoredPhoto(photo: $0, score: PhotoScoring.score($0, profile: .default(for: .everyday)))
        }
        let shortlist = PhotoSelectionEngine.select(
            scored,
            grouping: grouping,
            profile: .default(for: .everyday)
        )
        try expect(shortlist.decisions.filter { $0.bucket == .hidden }.count == 1, "exact copy was not hidden")
    }

    private static func burstGroupingUsesFixedRepresentative() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let photos = [
            analyzed(index: 0, hash: "a", perceptualHash: 0b000, date: date),
            analyzed(index: 1, hash: "b", perceptualHash: 0b001, date: date.addingTimeInterval(1)),
            analyzed(index: 2, hash: "c", perceptualHash: 0b011, date: date.addingTimeInterval(2))
        ]
        var profile = ScoringProfile.default(for: .everyday)
        profile.nearDuplicateHammingDistance = 1
        let grouping = PhotoGroupingEngine.group(photos, profile: profile)
        try expect(grouping.groups.count == 1, "expected one non-singleton group")
        try expect(
            Set(grouping.groups[0].memberIDs) == Set([photos[0].id, photos[1].id]),
            "A~B~C was incorrectly chained"
        )
    }

    private static func selectionHonorsTarget() throws {
        let analyzedPhotos = (0..<5).map {
            analyzed(index: $0, hash: "hash-\($0)", perceptualHash: UInt64($0), date: nil)
        }
        let scored = analyzedPhotos.map {
            ScoredPhoto(photo: $0, score: PhotoScoring.score($0, profile: .default(for: .everyday)))
        }
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 2
        let shortlist = PhotoSelectionEngine.select(
            scored,
            grouping: PhotoGrouping(groups: []),
            profile: profile,
            visualDistance: { _, _ in 20 }
        )
        try expect(shortlist.selectedIDs.count == 2, "shortlist target was not honored")
        try expect(shortlist.decisions.filter { $0.bucket == .review }.count == 3, "review count was wrong")
    }

    private static func burstDurationIsBounded() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        let photos = (0..<5).map {
            analyzed(index: $0, hash: "duration-\($0)", perceptualHash: UInt64($0), date: start.addingTimeInterval(Double($0) * 10))
        }
        var profile = ScoringProfile.default(for: .everyday)
        profile.burstWindow = 12
        profile.maxBurstDuration = 20
        profile.nearDuplicateHammingDistance = 64
        let grouping = PhotoGroupingEngine.group(photos, profile: profile)
        try expect(grouping.groups.count == 2, "bounded burst should split into two groups")
        try expect(grouping.groups.allSatisfy { $0.memberIDs.count <= 3 }, "burst exceeded its total duration")
    }

    private static func selectionIsDeterministic() throws {
        let analyzedPhotos = (0..<6).map {
            analyzed(index: $0, hash: "deterministic-\($0)", perceptualHash: UInt64($0), date: nil)
        }
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 3
        let score = { (photo: AnalyzedPhoto) in
            ScoredPhoto(photo: photo, score: PhotoEngineCore.PhotoScoring.score(photo, profile: profile))
        }
        let first = PhotoSelectionEngine.select(
            analyzedPhotos.map(score),
            grouping: PhotoGrouping(groups: []),
            profile: profile
        )
        let second = PhotoSelectionEngine.select(
            analyzedPhotos.reversed().map(score),
            grouping: PhotoGrouping(groups: []),
            profile: profile
        )
        try expect(first.decisions == second.decisions, "input order changed deterministic decisions")
    }

    private static func cullingControlsAndStyleRecipes() throws {
        var gentle = ScoringProfile.default(for: .everyday)
        gentle.apply(aggressiveness: .gentle)
        var highlights = ScoringProfile.default(for: .everyday)
        highlights.apply(aggressiveness: .highlights)
        try expect(gentle.nearDuplicateHammingDistance < highlights.nearDuplicateHammingDistance, "culling presets did not change duplicate strictness")
        try expect(gentle.maxBurstDuration >= gentle.burstWindow, "gentle burst bounds became invalid")

        let photo = analyzed(index: 0, hash: "style", perceptualHash: 0, date: nil)
        let monochrome = ApplePhotoRenderer.recipe(for: photo, style: .blackAndWhite, intensity: 0.5)
        try expect(monochrome.style == .blackAndWhite, "style was not recorded")
        try expect(monochrome.styleIntensity == 0.5, "style intensity was not recorded")
        try expect(monochrome.saturation == 0, "black and white recipe applied intensity twice")
    }

    private static func stableIDsAndImportWarnings() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "one.jpg", red: 0.8)
        try Data("not a jpeg".utf8).write(to: fixture.source.appendingPathComponent("broken.jpg"))
        let importer = PhotoFolderImporter()
        let first = try importer.importFolderReport(fixture.source)
        let second = try importer.importFolderReport(fixture.source)
        try expect(first.photos.count == 1, "valid photo was not imported")
        try expect(first.issues.count == 1, "corrupt photo was not reported")
        try expect(first.photos[0].asset.id == second.photos[0].asset.id, "photo ID changed between imports")
    }

    private static func catalogPersistsSession() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let catalogURL = fixture.root.appendingPathComponent("catalog.sqlite")
        let sessionID = SessionID()
        let profile = ScoringProfile.default(for: .everyday)
        let asset = analyzed(index: 0, hash: "catalog", perceptualHash: 0, date: nil).asset
        do {
            let catalog = try PhotoCatalog(url: catalogURL)
            try catalog.beginSession(id: sessionID, sourceFolder: fixture.source, settings: profile)
            try catalog.upsert(asset: asset, sessionID: sessionID, contentHash: "catalog")
            try catalog.upsert(analysis: analyzed(index: 0, hash: "catalog", perceptualHash: 0, date: nil).signals, for: asset.id, analyzerVersion: "checks")
            try catalog.replaceDecisions([
                SelectionDecision(photoID: asset.id, bucket: .selected, rank: 0, reasons: ["test"], score: 1)
            ], sessionID: sessionID)
            try catalog.finishSession(sessionID)
        }
        let reopened = try PhotoCatalog(url: catalogURL)
        let summary = try reopened.storageSummary(sessionID: sessionID)
        try expect(summary.sourceBytes == asset.metadata.fileSize, "catalog summary did not persist source bytes")
        let snapshot = try PhotoEngineChecks.require(reopened.session(id: sessionID), "catalog session could not be reopened")
        try expect(snapshot.status == "complete", "reopened session status was not complete")
        let persistedDecisions = try reopened.decisions(sessionID: sessionID)
        try expect(persistedDecisions.count == 1, "reopened decisions were not persisted")
        let plan = CleanupPlan(sessionID: sessionID, policy: .keepSelectedOriginals, candidates: [])
        try reopened.recordCleanupPlan(plan)
        try reopened.updateCleanupPlanStatus(plan.id, status: "approved", approvedAt: Date())
    }

    private static func cleanupPreviewIsConservative() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "one.jpg", red: 0.2)
        let oneData = try Data(contentsOf: fixture.source.appendingPathComponent("one.jpg"))
        try oneData.write(to: fixture.source.appendingPathComponent("one-copy.jpg"))
        try fixture.writeJPEG(name: "two.jpg", red: 0.8)
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 2
        let result = try PhotoPipelineRunner().run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        let preserve = PhotoCleanupPlanner.preview(result: result, policy: .preserveOriginals)
        try expect(preserve.candidates.isEmpty, "preserve-originals policy proposed deletion")
        let plan = PhotoCleanupPlanner.preview(result: result, policy: .keepSelectedOriginals)
        try expect(plan.candidates.count == 1, "exact duplicate was not proposed for cleanup")
        let candidate = plan.candidates[0]
        let stale = CleanupPlan(
            sessionID: plan.sessionID,
            policy: plan.policy,
            candidates: [CleanupCandidate(
                photoID: candidate.photoID,
                sourcePath: candidate.sourcePath,
                retainedPath: candidate.retainedPath,
                contentHash: "stale",
                bytes: candidate.bytes,
                reason: candidate.reason
            )]
        )
        let report = PhotoCleanupPlanner.moveToTrash(stale)
        try expect(report.movedPhotoIDs.isEmpty, "stale cleanup approval moved a source")
        try expect(FileManager.default.fileExists(atPath: candidate.sourcePath), "stale cleanup removed the source")
    }

    private static func visionFeaturePrintRoundTrip() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "one.jpg", red: 0.55)
        let imported = try PhotoFolderImporter().importFolder(fixture.source)
        let photo = try require(imported.first, "fixture was not imported")
        let analyzer = AppleAnalysisEngine()
        let first = try analyzer.analyze(asset: photo.asset, thumbnailData: photo.thumbnail)
        let second = try analyzer.analyze(asset: photo.asset, thumbnailData: photo.thumbnail)
        let distance = try require(AppleVisualDistance.distance(first, second), "Vision feature print could not be decoded")
        try expect(distance < 0.000_001, "identical Vision feature prints did not compare as identical")
    }

    private static func isolatedRunDirectories() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "one.jpg", red: 0.2)
        let oneData = try Data(contentsOf: fixture.source.appendingPathComponent("one.jpg"))
        try oneData.write(to: fixture.source.appendingPathComponent("one-copy.jpg"))
        try fixture.writeJPEG(name: "two.jpg", red: 0.5)
        try fixture.writeJPEG(name: "three.jpg", red: 0.8)
        let runner = PhotoPipelineRunner()
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 3
        let first = try runner.run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        profile.targetCount = 1
        let second = try runner.run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        let firstCount = try jpegCount(in: first.runDirectory.appendingPathComponent("shortlist"))
        let secondCount = try jpegCount(in: second.runDirectory.appendingPathComponent("shortlist"))
        try expect(first.runDirectory != second.runDirectory, "runs shared an output directory")
        try expect(firstCount == 3, "first run lost exports")
        try expect(first.metrics.exactContentReuses == 1, "exact-content analysis was not reused")
        try expect(secondCount == 1, "second run contains stale exports")
        try expect(second.exports.count == 1, "manifest/export count mismatch")
        let manifestData = try Data(contentsOf: second.manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(PipelineManifest.self, from: manifestData)
        try expect(manifest.pipelineVersion == "0.3.0", "manifest version was not updated")
        try expect(manifest.targetCount == 1, "manifest did not persist target count")
        try expect(manifest.metrics.cacheHits == 4, "warm run did not reuse analysis cache")
    }

    private static func metadataPolicy() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "metadata.jpg", red: 0.4, includeMetadata: true)
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 1
        let result = try PhotoPipelineRunner().run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        let export = try require(result.exports.first, "missing export")
        let outputURL = URL(fileURLWithPath: export.outputPath)
        let source = try require(CGImageSourceCreateWithURL(outputURL as CFURL, nil), "could not open export")
        let properties = try require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?, "missing output metadata")
        let tiff = try require(properties[kCGImagePropertyTIFFDictionary] as? NSDictionary, "missing TIFF metadata")
        let exif = try require(properties[kCGImagePropertyExifDictionary] as? NSDictionary, "missing EXIF metadata")
        try expect(tiff[kCGImagePropertyTIFFMake] as? String == "Test Camera Co", "camera make was discarded")
        try expect(exif[kCGImagePropertyExifLensModel] as? String == "Fixture Lens", "lens model was discarded")
        try expect(properties[kCGImagePropertyGPSDictionary] == nil, "GPS metadata was retained")
        try expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1, "orientation was not normalized")
        let expectedDate = ISO8601DateFormatter().date(from: "2024-05-06T04:38:09Z")!
        let capturedDate = try require(result.imported.first?.metadata.captureDate, "capture date was not parsed")
        try expect(abs(capturedDate.timeIntervalSince(expectedDate) - 0.25) < 0.001, "offset/subsecond capture date was parsed incorrectly")
    }

    private static func rejectsNestedOutput() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "one.jpg", red: 0.3)
        let nested = fixture.source.appendingPathComponent("exports", isDirectory: true)
        do {
            _ = try PhotoPipelineRunner().run(
                folder: fixture.source,
                outputDirectory: nested,
                profile: .default(for: .everyday)
            )
            throw CheckFailure("nested output was accepted")
        } catch is PhotoEngineError {
            // Expected.
        }
    }

    private static func analyzed(index: Int, hash: String, perceptualHash: UInt64, date: Date?) -> AnalyzedPhoto {
        let id = PhotoID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!)
        let asset = PhotoAsset(
            id: id,
            url: URL(fileURLWithPath: "/tmp/photo-\(index).jpg"),
            relativePath: "photo-\(index).jpg",
            metadata: PhotoMetadata(pixelWidth: 100, pixelHeight: 100, captureDate: date)
        )
        return AnalyzedPhoto(
            asset: asset,
            signals: AnalysisSignals(
                fingerprint: PhotoFingerprint(contentHash: hash, perceptualHash: perceptualHash),
                brightness: 0.5,
                exposureQuality: 0.8,
                sharpness: 0.8,
                faceQuality: 0.5,
                faceCount: 0,
                aestheticScore: 0.8,
                aestheticUtility: false,
                featurePrint: nil,
                faces: []
            )
        )
    }

    private static func jpegCount(in directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }.count
    }

    fileprivate static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message) }
    }

    fileprivate static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw CheckFailure(message) }
        return value
    }
}

private struct CheckFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct FixtureDirectory {
    let root: URL
    let source: URL
    let output: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoEngineChecks-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func writeJPEG(name: String, red: CGFloat, includeMetadata: Bool = false) throws {
        let width = 64
        let height = 64
        let context = try PhotoEngineChecks.require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            "could not create fixture context"
        )
        context.setFillColor(CGColor(red: red, green: 0.25, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try PhotoEngineChecks.require(context.makeImage(), "could not create fixture image")
        let url = source.appendingPathComponent(name)
        let destination = try PhotoEngineChecks.require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil),
            "could not create fixture destination"
        )
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if includeMetadata {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "Test Camera Co",
                kCGImagePropertyTIFFModel: "Fixture 1"
            ]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09",
                kCGImagePropertyExifSubsecTimeOriginal: "250",
                kCGImagePropertyExifOffsetTimeOriginal: "+02:30",
                kCGImagePropertyExifLensModel: "Fixture Lens"
            ]
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.0,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.0,
                kCGImagePropertyGPSLongitudeRef: "W"
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try PhotoEngineChecks.expect(CGImageDestinationFinalize(destination), "could not finalize fixture")
    }
}
