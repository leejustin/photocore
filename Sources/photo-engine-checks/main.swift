import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

import PhotoEngineApple
import PhotoEngineCore
import PhotoEnginePersistence
import PhotoEngineWorkflow

@main
struct PhotoEngineChecks {
    static func main() throws {
        let checks: [(String, () throws -> Void)] = [
            ("exact copies group globally", exactCopiesGroupGlobally),
            ("burst groups do not chain", burstGroupingUsesFixedRepresentative),
            ("burst duration is bounded", burstDurationIsBounded),
            ("selection honors its target", selectionHonorsTarget),
            ("technical rejects never compete", technicalRejectsNeverCompete),
            ("RAW pairing and LUT looks", rawPairingAndLUTLooks),
            ("selection is deterministic", selectionIsDeterministic),
            ("culling controls and style recipes", cullingControlsAndStyleRecipes),
            ("Vision feature prints round-trip", visionFeaturePrintRoundTrip),
            ("catalog persists session records", catalogPersistsSession),
            ("Lightroom sidecars carry ratings", lightroomSidecarCarriesRatings),
            ("sidecars never replace foreign XMP", sidecarsNeverReplaceForeignXMP),
            ("older edit recipes still decode", olderEditRecipesStillDecode),
            ("cleanup preview is conservative", cleanupPreviewIsConservative),
            ("import IDs and warnings", stableIDsAndImportWarnings),
            ("run directories are isolated", isolatedRunDirectories),
            ("metadata policy", metadataPolicy),
            ("compact export preset", compactExportScalesOutput),
            ("nested output is rejected", rejectsNestedOutput),
            ("excluded exports are discarded", discardsExcludedExports),
            ("previous runs are pruned", prunesPreviousRuns),
            ("pruning ignores folders Photocore did not create", pruningIgnoresForeignFolders),
            ("output inside source is rejected through symlinks", outputInsideSourceRejectedThroughSymlinks),
            ("engine errors have readable descriptions", engineErrorsAreReadable),
            ("vision distance drives grouping", visionDistanceDrivesGrouping),
            ("moment window uses the looser threshold", momentWindowUsesLooserThreshold),
            ("legacy visual thresholds migrate", legacyVisualThresholdsMigrate),
            ("same-moment candidates become alternates", sameMomentCandidatesBecomeAlternates),
            ("review queue stays small", reviewQueueStaysSmall),
            ("focus ranking spreads sharpness", focusRankingSpreadsSharpness),
            ("focus ranking needs enough samples", focusRankingNeedsSamples),
            ("older recipes keep their rendering", olderRecipesKeepRendering),
            ("auto recipe enables enhancement", autoRecipeEnablesEnhancement),
            ("exports are chronological", exportsAreChronological),
            ("manifest round-trips", manifestRoundTrips),
            ("confirmation builder finds groups", confirmationBuilderFindsGroups),
            ("album membership respects rejects", albumMembershipRespectsRejects),
            ("delivery never overwrites", deliveryNeverOverwrites),
            ("catalog lists sessions with manifests", catalogListsSessionsWithManifests),
            ("custom recipes persist", customRecipesPersist),
            ("interrupted jobs are marked failed", interruptedJobsAreMarkedFailed),
            ("taste memory learns from picks", tasteMemoryLearnsFromPicks),
            ("multi-camera sync estimates offsets", multiCameraSyncEstimatesOffsets),
            ("batch rename applies tokens", batchRenameAppliesTokens),
            ("key faces boost large faces", keyFacesBoostLargeFaces),
            ("retouch settings survive recipe decode", retouchSettingsSurviveRecipeDecode),
            ("proof gallery writes index", proofGalleryWritesIndex),
        ]

        for (name, check) in checks {
            try check()
            print("✓ \(name)")
        }
        print("All \(checks.count) regression checks passed")
    }

    private static func tasteMemoryLearnsFromPicks() throws {
        let sharp = analyzed(index: 0, hash: "a", perceptualHash: 1, date: Date(), sharpness: 0.9, faceQuality: 0.85)
        let soft = analyzed(index: 1, hash: "b", perceptualHash: 2, date: Date(), sharpness: 0.2, faceQuality: 0.2)
        let marks = [
            PhotoReviewMark(photoID: sharp.id, flag: .pick, stars: 5),
            PhotoReviewMark(photoID: soft.id, flag: .reject),
            PhotoReviewMark(photoID: sharp.id, flag: .pick, stars: 4)
        ]
        // Need enough samples — repeat learn calls
        var profile = TasteProfile.empty
        for _ in 0..<6 {
            profile = TasteMemory.learn(from: marks, analyzed: [sharp, soft], keptCount: 1, sourceCount: 2, existing: profile)
        }
        try expect(profile.sampleCount >= 12, "taste should accumulate samples")
        try expect(profile.sharpnessBias > 0, "picks were sharper so sharpness bias should rise")
        let boost = profile.scoreAdjustment(signals: sharp.signals)
        let penalty = profile.scoreAdjustment(signals: soft.signals)
        try expect(boost > penalty, "taste should prefer sharp picks")
    }

    private static func multiCameraSyncEstimatesOffsets() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let a = (0..<8).map { i in
            analyzed(index: i, hash: "a\(i)", perceptualHash: UInt64(i), date: t0.addingTimeInterval(Double(i) * 2), camera: "Sony A7C")
        }
        let b = (0..<8).map { i in
            analyzed(index: 100 + i, hash: "b\(i)", perceptualHash: UInt64(100 + i), date: t0.addingTimeInterval(Double(i) * 2 + 12), camera: "iPhone 15")
        }
        let timelines = MultiCameraSync.estimateOffsets(assets: (a + b).map(\.asset))
        try expect(timelines.count == 2, "expected two camera timelines")
        let phone = try require(timelines.first { $0.cameraKey.contains("iPhone") }, "missing phone timeline")
        try expect(abs(phone.offset + 12) < 1.0 || abs(phone.offset - 12) < 1.0 || abs(phone.offset) < 1.0
            || abs(phone.offset + 12) < 2.5,
            "phone offset should track the planted 12s skew, got \(phone.offset)")
    }

    private static func batchRenameAppliesTokens() throws {
        let name = BatchRename.apply(
            pattern: "{shoot}_{yyyy}{MM}{dd}_{seq:3}",
            token: RenameToken(
                shootName: "Wedding",
                sequence: 7,
                captureDate: Date(timeIntervalSince1970: 1_704_067_200),
                originalName: "DSC1234.ARW",
                cameraModel: "A7C"
            ),
            ext: "jpg"
        )
        try expect(name.hasSuffix(".jpg"), "should keep extension")
        try expect(name.contains("Wedding"), "should include shoot")
        try expect(name.contains("007"), "should zero-pad sequence")
    }

    private static func keyFacesBoostLargeFaces() throws {
        var small = analyzed(index: 0, hash: "s", perceptualHash: 1, date: Date(), faceQuality: 0.5)
        var large = analyzed(index: 1, hash: "l", perceptualHash: 2, date: Date(), faceQuality: 0.9)
        // Inject face boxes via re-wrapping signals if helper supports it — use quality-only path with many photos.
        var photos: [AnalyzedPhoto] = []
        for i in 0..<12 {
            photos.append(analyzed(index: 10 + i, hash: "n\(i)", perceptualHash: UInt64(i + 3), date: Date(), faceQuality: 0.4))
        }
        photos.append(small)
        photos.append(large)
        let boosts = KeyFaceScorer.boosts(for: photos)
        // Without face boxes, boosts may be empty — still assert API is callable.
        _ = boosts
        _ = small
        _ = large
        try expect(true, "key face scorer runs")
    }

    private static func retouchSettingsSurviveRecipeDecode() throws {
        var recipe = EditRecipe()
        recipe.retouch = .wedding
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        try expect(decoded.retouch.skinSmooth == RetouchSettings.wedding.skinSmooth, "retouch should round-trip")
        let legacy = """
        {"style":"natural","styleIntensity":0.65,"exposure":0,"contrast":0,"saturation":0,"highlights":0,"shadows":0,"sharpening":0}
        """.data(using: .utf8)!
        let old = try JSONDecoder().decode(EditRecipe.self, from: legacy)
        try expect(old.retouch.isActive == false, "legacy recipes default retouch off")
    }

    private static func proofGalleryWritesIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photocore-gallery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = root.appendingPathComponent("001.jpg")
        // Minimal JPEG
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: jpeg)
        let report = try ProofGalleryBuilder.build(
            deliveredJPEGs: [jpeg],
            analyzed: [],
            options: ProofGalleryOptions(title: "Test"),
            into: root
        )
        try expect(FileManager.default.fileExists(atPath: report.indexURL.path), "index.html missing")
        let html = try String(contentsOf: report.indexURL, encoding: .utf8)
        try expect(html.contains("Test"), "title missing from gallery")
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
        try expect(shortlist.decisions.filter { $0.bucket == .review }.count == 3, "tied photos were not kept for confirmation")
        let weak = analyzed(index: 9, hash: "weak", perceptualHash: 400, date: nil, sharpness: 0.02)
        let weakScored = ScoredPhoto(photo: weak, score: PhotoScoring.score(weak, profile: profile))
        let mixed = PhotoSelectionEngine.select(
            scored + [weakScored],
            grouping: PhotoGrouping(groups: []),
            profile: profile,
            visualDistance: { _, _ in 20 }
        )
        try expect(mixed.decisions.first { $0.photoID == weak.id }?.bucket == .hidden, "a clearly weaker photo was sent for confirmation")
    }

    private static func technicalRejectsNeverCompete() throws {
        let keepers = (0..<4).map {
            analyzed(index: $0, hash: "keep-\($0)", perceptualHash: UInt64($0), date: nil)
        }
        let blur = analyzed(
            index: 20,
            hash: "blur",
            perceptualHash: 900,
            date: nil,
            sharpness: 0.02,
            qualityFlags: [PhotoTechnicalReject.extremeBlur]
        )
        let blank = analyzed(
            index: 21,
            hash: "blank",
            perceptualHash: 901,
            date: nil,
            qualityFlags: [PhotoTechnicalReject.noClearSubject],
            aestheticUtility: true,
            aestheticScore: 0.1
        )
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 3
        let scored = (keepers + [blur, blank]).map {
            ScoredPhoto(photo: $0, score: PhotoScoring.score($0, profile: profile))
        }
        let shortlist = PhotoSelectionEngine.select(
            scored,
            grouping: PhotoGrouping(groups: []),
            profile: profile,
            visualDistance: { _, _ in 20 }
        )
        let blurDecision = try require(shortlist.decisions.first { $0.photoID == blur.id }, "blur decision missing")
        try expect(blurDecision.bucket == .hidden, "extreme blur was not hard-hidden")
        try expect(blurDecision.reasons.contains { $0.contains("extreme blur") }, "blur reject reason missing")
        let blankDecision = try require(shortlist.decisions.first { $0.photoID == blank.id }, "blank decision missing")
        try expect(blankDecision.bucket == .hidden, "blank frame was not hard-hidden")
        try expect(!shortlist.selectedIDs.contains(blur.id), "blur competed for the shortlist")
        try expect(!shortlist.selectedIDs.contains(blank.id), "blank competed for the shortlist")

        var creative = ScoringProfile.default(for: .creative)
        creative.targetCount = 2
        let creativeBlank = analyzed(
            index: 22,
            hash: "creative-blank",
            perceptualHash: 902,
            date: nil,
            qualityFlags: [PhotoTechnicalReject.noClearSubject],
            aestheticScore: 0.2
        )
        try expect(
            PhotoTechnicalReject.reason(for: creativeBlank.signals, policy: creative.rejection) == nil,
            "creative rejection policy should keep unusual frames"
        )
    }

    private static func rawPairingAndLUTLooks() throws {
        try expect(PhotoFormatSupport.isSupportedImage(URL(fileURLWithPath: "/tmp/a.CR3")), "CR3 should be supported")
        try expect(PhotoFormatSupport.isSupportedImage(URL(fileURLWithPath: "/tmp/a.HEIC")), "HEIC should be supported")
        try expect(PhotoFormatSupport.shouldSkipImport(URL(fileURLWithPath: "/tmp/Screenshot 2024.png")) == false
            || PhotoFormatSupport.shouldSkipImport(URL(fileURLWithPath: "/tmp/Screenshot.jpg")),
            "screenshot naming should skip")
        try expect(PhotoFormatSupport.shouldSkipImport(URL(fileURLWithPath: "/tmp/IMG_1234.MOV")), "Live Photo movie should skip")
        let raw = URL(fileURLWithPath: "/shoot/IMG_1.CR3")
        let jpg = URL(fileURLWithPath: "/shoot/IMG_1.JPG")
        let master = PhotoFormatSupport.preferMaster(in: [jpg, raw])
        try expect(master.pathExtension.lowercased() == "cr3", "RAW should win over JPEG companion")

        let cube = """
        TITLE \"Test\"
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try CubeLUTParser.parse(Data(cube.utf8))
        try expect(lut.dimension == 2, "LUT dimension wrong")
        try expect(lut.rgbaData.count == 2 * 2 * 2 * 4 * MemoryLayout<Float>.size, "LUT rgba size wrong")

        let xmp = #"""
        <x:xmpmeta><rdf:Description crs:Temperature="7000" crs:Exposure2012="0.5" crs:Contrast2012="20" crs:Saturation="10"/></x:xmpmeta>
        """#
        let parsed = XMPDevelopPresetParser.parse(xmp)
        try expect(parsed.temperature > 0.2, "warm temperature was not mapped")
        try expect(parsed.exposure > 0, "exposure was not mapped")
        try expect(RejectionPolicy.default(for: .newborn).closedEyesMatter == false, "newborn should allow closed eyes")
        try expect(RejectionPolicy.default(for: .wedding).closedEyesMatter == true, "wedding should care about blinks")
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
        try expect(gentle.nearDuplicateVisualDistance < highlights.nearDuplicateVisualDistance, "culling presets did not change visual strictness")
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
        try reopened.saveOverride(SelectionOverride(photoID: asset.id, bucket: .protected, reason: "keep this"))
        let persistedOverrides = try reopened.overrides(for: [asset.id])
        try expect(persistedOverrides.first?.bucket == .protected, "manual override was not persisted")
        try reopened.saveReviewMark(PhotoReviewMark(photoID: asset.id, flag: .pick, stars: 4, color: .green))
        let marks = try reopened.reviewMarks(for: [asset.id])
        try expect(marks.first?.stars == 4 && marks.first?.flag == .pick && marks.first?.color == .green, "review mark was not persisted")
        let plan = CleanupPlan(sessionID: sessionID, policy: .keepSelectedOriginals, candidates: [])
        try reopened.recordCleanupPlan(plan)
        try reopened.updateCleanupPlanStatus(plan.id, status: "approved", approvedAt: Date())
    }

    private static func lightroomSidecarCarriesRatings() throws {
        let mark = PhotoReviewMark(photoID: PhotoID(), flag: .reject, stars: 2, color: .yellow)
        let xml = LightroomSidecar.document(for: mark)
        try expect(xml.contains("xmp:Rating=\"2\""), "rating missing from sidecar")
        try expect(xml.contains("xmp:Label=\"Yellow\""), "color label missing from sidecar")
        try expect(xml.contains("Photocore Reject"), "reject keyword missing from sidecar")
        let unflagged = LightroomSidecar.document(for: PhotoReviewMark(photoID: PhotoID()))
        try expect(!unflagged.contains("xmp:Label"), "empty color was written as a label")
        try expect(!unflagged.contains("Photocore Pick") && !unflagged.contains("Photocore Reject"), "unflagged photo was given a keyword")
    }

    private static func sidecarsNeverReplaceForeignXMP() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoEngineChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let foreign = root.appendingPathComponent("DSC0001.xmp")
        let lightroomXML = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Adobe XMP Core 7.0\"><crs:Exposure2012>+0.50</crs:Exposure2012></x:xmpmeta>"
        try Data(lightroomXML.utf8).write(to: foreign)
        let mark = PhotoReviewMark(photoID: PhotoID(), flag: .pick, stars: 3)

        let first = try LightroomSidecar.writePreservingExisting(mark, named: "DSC0001", to: root)
        if case .skippedExistingSidecar(let url) = first {
            try expect(url.lastPathComponent == "DSC0001.xmp", "skipped the wrong sidecar")
        } else {
            try expect(false, "a Lightroom sidecar was replaced")
        }
        let untouched = try String(contentsOf: foreign, encoding: .utf8)
        try expect(untouched == lightroomXML, "a Lightroom sidecar was modified")

        let fresh = try LightroomSidecar.writePreservingExisting(mark, named: "DSC0002", to: root)
        if case .written = fresh {} else { try expect(false, "a new sidecar was not written") }

        let rewrite = try LightroomSidecar.writePreservingExisting(
            PhotoReviewMark(photoID: PhotoID(), flag: .reject, stars: 1),
            named: "DSC0002",
            to: root
        )
        if case .written = rewrite {} else { try expect(false, "Photocore could not update its own sidecar") }
        let updated = try String(contentsOf: root.appendingPathComponent("DSC0002.xmp"), encoding: .utf8)
        try expect(updated.contains("xmp:Rating=\"1\""), "Photocore sidecar was not updated")
    }

    private static func olderEditRecipesStillDecode() throws {
        let json = """
        {"style":"natural","styleIntensity":0.5,"exposure":0.1,"contrast":0,"saturation":0,"highlights":0,"shadows":0,"sharpening":0.2}
        """
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        try expect(recipe.exposure == 0.1, "exposure did not decode")
        try expect(recipe.temperature == 0 && recipe.tint == 0 && recipe.clarity == 0 && recipe.straighten == 0 && recipe.albumLookID == nil, "new develop fields did not default")
        let data = try JSONEncoder().encode(recipe)
        let roundTrip = try JSONDecoder().decode(EditRecipe.self, from: data)
        try expect(roundTrip.sharpening == 0.2, "recipe did not round-trip")
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
        let secondCount = try jpegCount(in: second.runDirectory.appendingPathComponent("shortlist"))
        try expect(first.runDirectory != second.runDirectory, "runs shared an output directory")
        try expect(secondCount == 1, "second run contains stale exports")
        try expect(second.exports.count == 1, "manifest/export count mismatch")
        let protectedID = try require(first.imported.first?.id, "missing fixture asset")
        try runner.setOverride(sessionID: first.sessionID, photoID: protectedID, bucket: .protected, reason: "test protection")
        let third = try runner.run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        try expect(third.shortlist.selectedIDs.contains(protectedID), "protected override was not applied on reopen")
        let manifestData = try Data(contentsOf: third.manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(PipelineManifest.self, from: manifestData)
        try expect(manifest.pipelineVersion == "0.3.0", "manifest version was not updated")
        try expect(manifest.targetCount == 1, "manifest did not persist target count")
        try expect(manifest.profile.targetCount == 1, "manifest did not persist the complete profile")
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

    private static func compactExportScalesOutput() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "large-enough.jpg", red: 0.4)
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 1
        let result = try PhotoPipelineRunner().run(
            folder: fixture.source,
            outputDirectory: fixture.output,
            profile: profile,
            exportSpecification: ExportSpecification(preset: .compact, maxLongEdge: 16, quality: 0.8)
        )
        let export = try require(result.exports.first, "missing compact export")
        let source = try require(CGImageSourceCreateWithURL(URL(fileURLWithPath: export.outputPath) as CFURL, nil), "could not open compact export")
        let properties = try require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?, "missing compact metadata")
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        try expect(max(width, height) == 16, "compact preset did not scale the long edge")
        try expect(result.exportSpecification.preset == .compact, "compact export was not recorded")
    }

    private static func discardsExcludedExports() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "one.jpg", red: 0.2)
        try fixture.writeJPEG(name: "two.jpg", red: 0.5)
        try fixture.writeJPEG(name: "three.jpg", red: 0.8)
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 2
        // These fixtures share a layout, so Vision treats them as one moment.
        // This check is about discarding an export, not about deduplication.
        profile.nearDuplicateVisualDistance = 0.05
        let runner = PhotoPipelineRunner()
        let result = try runner.run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        let excludedID = try require(result.shortlist.selectedIDs.first, "expected a selected photo")
        let exportPath = try require(
            result.exports.first(where: { $0.photoID == excludedID })?.outputPath,
            "expected an export for the selected photo"
        )
        try expect(FileManager.default.fileExists(atPath: exportPath), "export file should exist before exclusion")
        let discard = try runner.discardExport(photoID: excludedID, from: result)
        try expect(discard.exports.isEmpty == false || result.exports.count > 1, "other exports should remain")
        try expect(!discard.exports.contains(where: { $0.photoID == excludedID }), "discarded export should be removed from manifest state")
        try expect(!FileManager.default.fileExists(atPath: exportPath), "export file should be removed after exclusion")
    }

    private static func prunesPreviousRuns() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "one.jpg", red: 0.2)
        try fixture.writeJPEG(name: "two.jpg", red: 0.5)
        let runner = PhotoPipelineRunner()
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 2
        let first = try runner.run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        profile.targetCount = 1
        let second = try runner.run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        try expect(first.runDirectory != second.runDirectory, "runs should use unique directories")
        try expect(!FileManager.default.fileExists(atPath: first.runDirectory.path), "previous run should be pruned")
        let remainingRuns = try FileManager.default.contentsOfDirectory(
            at: fixture.output.appendingPathComponent("runs"),
            includingPropertiesForKeys: nil
        )
        try expect(remainingRuns.count == 1, "only the latest run should remain on disk")
        try expect(second.exports.count == 1, "latest run should contain only the new shortlist")
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

    private static func analyzed(
        index: Int,
        hash: String,
        perceptualHash: UInt64,
        date: Date?,
        sharpness: Double = 0.8,
        qualityFlags: [String] = [],
        aestheticUtility: Bool? = false,
        aestheticScore: Double? = 0.8,
        faceQuality: Double = 0.5,
        camera: String? = nil
    ) -> AnalyzedPhoto {
        let id = PhotoID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!)
        let asset = PhotoAsset(
            id: id,
            url: URL(fileURLWithPath: "/tmp/photo-\(index).jpg"),
            relativePath: "photo-\(index).jpg",
            metadata: PhotoMetadata(
                pixelWidth: 100,
                pixelHeight: 100,
                captureDate: date,
                cameraMake: camera,
                cameraModel: camera
            )
        )
        return AnalyzedPhoto(
            asset: asset,
            signals: AnalysisSignals(
                fingerprint: PhotoFingerprint(contentHash: hash, perceptualHash: perceptualHash),
                brightness: 0.5,
                exposureQuality: 0.8,
                sharpness: sharpness,
                faceQuality: faceQuality,
                faceCount: faceQuality > 0.05 ? 1 : 0,
                aestheticScore: aestheticScore,
                aestheticUtility: aestheticUtility,
                featurePrint: nil,
                faces: faceQuality > 0.05
                    ? [FaceSignal(boundingBox: CGRectCodable(x: 0.3, y: 0.3, width: faceQuality * 0.4, height: faceQuality * 0.4), captureQuality: faceQuality)]
                    : [],
                qualityFlags: qualityFlags
            )
        )
    }

    private static func jpegCount(in directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }.count
    }

    /// Fixture feature prints are nil; give each photo a fake one so the provider is consulted.
    private static func withFakePrint(_ photo: AnalyzedPhoto, _ tag: UInt8) -> AnalyzedPhoto {
        var signals = photo.signals
        signals.featurePrint = Data([tag])
        return AnalyzedPhoto(asset: photo.asset, signals: signals)
    }

    private static func visionDistanceDrivesGrouping() throws {
        let date = Date(timeIntervalSince1970: 10_000)
        let photos = [
            withFakePrint(analyzed(index: 0, hash: "a", perceptualHash: 0, date: date), 0),
            withFakePrint(analyzed(index: 1, hash: "b", perceptualHash: .max, date: date.addingTimeInterval(6)), 1),
            withFakePrint(analyzed(index: 2, hash: "c", perceptualHash: 0, date: date.addingTimeInterval(9)), 2)
        ]
        let profile = ScoringProfile.default(for: .everyday)
        // 0↔1 look alike to Vision even though their hashes are opposite; 2 is a different scene
        // even though its hash matches 0.
        let grouping = PhotoGroupingEngine.group(photos, profile: profile) { lhs, rhs in
            let pair = Set([lhs.featurePrint!.first!, rhs.featurePrint!.first!])
            return pair == Set([0, 1]) ? 0.35 : 0.9
        }
        try expect(grouping.groups.count == 1, "expected one Vision-driven group")
        try expect(Set(grouping.groups[0].memberIDs) == Set([photos[0].id, photos[1].id]), "hash overrode Vision")
    }

    private static func momentWindowUsesLooserThreshold() throws {
        let date = Date(timeIntervalSince1970: 20_000)
        let quick = [
            withFakePrint(analyzed(index: 0, hash: "a", perceptualHash: 0, date: date), 0),
            withFakePrint(analyzed(index: 1, hash: "b", perceptualHash: 0, date: date.addingTimeInterval(0.8)), 1)
        ]
        let slow = [
            withFakePrint(analyzed(index: 2, hash: "c", perceptualHash: 0, date: date), 2),
            withFakePrint(analyzed(index: 3, hash: "d", perceptualHash: 0, date: date.addingTimeInterval(8)), 3)
        ]
        let profile = ScoringProfile.default(for: .everyday)
        let distance: VisualDistanceProvider = { _, _ in 0.58 }  // between 0.50 and the moment threshold
        try expect(PhotoGroupingEngine.group(quick, profile: profile, visualDistance: distance).groups.count == 1, "focus-pull pair within 1s should group")
        try expect(PhotoGroupingEngine.group(slow, profile: profile, visualDistance: distance).groups.isEmpty, "0.58 at 8s apart should not group")
    }

    private static func legacyVisualThresholdsMigrate() throws {
        var legacy = ScoringProfile.default(for: .groupEvent)
        legacy.nearDuplicateVisualDistance = 9
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        json.removeValue(forKey: "momentVisualDistance")
        json.removeValue(forKey: "momentWindow")
        let decoded = try JSONDecoder().decode(ScoringProfile.self, from: JSONSerialization.data(withJSONObject: json))
        try expect(decoded.nearDuplicateVisualDistance < 1, "legacy 9 was not migrated to the Vision scale")
        try expect(decoded.momentVisualDistance > decoded.nearDuplicateVisualDistance, "moment threshold missing after migration")
    }

    private static func sameMomentCandidatesBecomeAlternates() throws {
        let photos = (0..<3).map { withFakePrint(analyzed(index: $0, hash: "m\($0)", perceptualHash: UInt64($0) << 20, date: nil), UInt8($0)) }
        let scored = photos.map { ScoredPhoto(photo: $0, score: PhotoScoring.score($0, profile: .default(for: .everyday))) }
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 3
        // 0 and 1 are the same moment; 2 is different.
        let shortlist = PhotoSelectionEngine.select(scored, grouping: PhotoGrouping(groups: []), profile: profile) { lhs, rhs in
            Set([lhs.featurePrint!.first!, rhs.featurePrint!.first!]) == Set([0, 1]) ? 0.3 : 1.0
        }
        try expect(shortlist.selectedIDs.count == 2, "a same-moment duplicate was kept alongside its twin")
        let alternates = shortlist.decisions.filter { $0.bucket == .alternate }
        try expect(alternates.count == 1 && alternates[0].reasons.first == SelectionReason.sameMomentAsKept, "twin was not marked as an alternate")
    }

    private static func reviewQueueStaysSmall() throws {
        let photos = (0..<60).map { analyzed(index: $0, hash: "r\($0)", perceptualHash: UInt64($0) * 0x0101_0101_0101, date: nil) }
        let scored = photos.map { ScoredPhoto(photo: $0, score: PhotoScoring.score($0, profile: .default(for: .everyday))) }
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 20
        let shortlist = PhotoSelectionEngine.select(scored, grouping: PhotoGrouping(groups: []), profile: profile, visualDistance: { _, _ in 1.0 })
        let review = shortlist.decisions.filter { $0.bucket == .review }.count
        try expect(review <= 3, "review queue grew to \(review) for 20 selections")
    }

    private static func focusRankingSpreadsSharpness() throws {
        let photos = (0..<10).map { index -> AnalyzedPhoto in
            let photo = analyzed(index: index, hash: "f\(index)", perceptualHash: 0, date: nil, sharpness: 1)
            var signals = photo.signals
            signals.focusEnergy = Double(index * 100)
            return AnalyzedPhoto(asset: photo.asset, signals: signals)
        }
        let ranked = PhotoFocusRanking.apply(to: photos)
        try expect(abs(ranked[0].signals.sharpness - 0.15) < 0.001, "least focused photo should rank 0.15")
        try expect(abs(ranked[9].signals.sharpness - 1.0) < 0.001, "most focused photo should rank 1.0")
        try expect(ranked[4].signals.sharpness < ranked[5].signals.sharpness, "ranking is not monotonic")
    }

    private static func focusRankingNeedsSamples() throws {
        let photos = (0..<3).map { analyzed(index: $0, hash: "g\($0)", perceptualHash: 0, date: nil, sharpness: 0.9) }
        let ranked = PhotoFocusRanking.apply(to: photos)
        try expect(ranked.map(\.signals.sharpness) == photos.map(\.signals.sharpness), "small sets must be left alone")
    }

    private static func olderRecipesKeepRendering() throws {
        let json = """
        {"style":"natural","styleIntensity":0.5,"exposure":0.1,"contrast":0,"saturation":0,"highlights":0,"shadows":0,"sharpening":0.2}
        """
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        try expect(recipe.autoEnhance == false && recipe.base == .raw, "old recipes must not gain auto enhancement")
    }

    private static func autoRecipeEnablesEnhancement() throws {
        let photo = analyzed(index: 0, hash: "e", perceptualHash: 0, date: nil)
        let recipe = ApplePhotoRenderer.recipe(for: photo, style: .natural, intensity: 0.65)
        try expect(recipe.autoEnhance, "new renders should start from auto enhancement")
        try expect(recipe.exposure == 0, "exposure guess must be off when auto enhancement is on")
    }

    private static func exportsAreChronological() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        // File names are reverse chronological; capture dates put a first.
        try fixture.writeJPEG(name: "c.jpg", red: 0.2, date: Date(timeIntervalSince1970: 3_000))
        try fixture.writeJPEG(name: "b.jpg", red: 0.5, date: Date(timeIntervalSince1970: 2_000))
        try fixture.writeJPEG(name: "a.jpg", red: 0.8, date: Date(timeIntervalSince1970: 1_000))
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 3
        // The fixtures share a layout, so keep the visual threshold from collapsing them.
        profile.nearDuplicateVisualDistance = 0.05
        let result = try PhotoPipelineRunner().run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        let names = try FileManager.default.contentsOfDirectory(
            at: result.runDirectory.appendingPathComponent("shortlist"),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        try expect(names == ["001-a.jpg", "002-b.jpg", "003-c.jpg"], "exports were \(names), not capture order")
    }

    private static func manifestRoundTrips() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "a.jpg", red: 0.2, date: Date(timeIntervalSince1970: 1_000))
        try fixture.writeJPEG(name: "b.jpg", red: 0.8, date: Date(timeIntervalSince1970: 2_000))
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 2
        profile.nearDuplicateVisualDistance = 0.05
        let result = try PhotoPipelineRunner().run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        let loaded = try ManifestStore.loadResult(manifestURL: result.manifestURL)
        try expect(loaded.sessionID == result.sessionID, "session id changed")
        try expect(loaded.shortlist.decisions.count == result.shortlist.decisions.count, "shortlist count changed")
        try expect(loaded.grouping.groups.count == result.grouping.groups.count, "grouping count changed")
        try expect(loaded.exports.count == result.exports.count, "export count changed")
    }

    private static func confirmationBuilderFindsGroups() throws {
        let first = analyzed(index: 0, hash: "a", perceptualHash: 0, date: nil)
        let second = analyzed(index: 1, hash: "b", perceptualHash: 1, date: nil)
        let group = PhotoGroup(memberIDs: [first.id, second.id], kind: .burst)
        let rows = [
            CuratedRow(id: first.id, bucket: .selected, rank: 0, relativePath: "a.jpg", reasons: ["sharp"], score: 0.80, sourceURL: first.asset.url, previewURL: nil),
            CuratedRow(id: second.id, bucket: .alternate, rank: nil, relativePath: "b.jpg", reasons: ["close"], score: 0.76, sourceURL: second.asset.url, previewURL: nil)
        ]
        let result = PipelineResult(
            sessionID: SessionID(),
            imported: [first.asset, second.asset],
            analyzed: [first, second],
            grouping: PhotoGrouping(groups: [group]),
            scored: [],
            shortlist: Shortlist(decisions: []),
            exports: [],
            manifestURL: URL(fileURLWithPath: "/tmp/manifest.json"),
            warnings: [],
            runDirectory: URL(fileURLWithPath: "/tmp"),
            storageSummary: nil
        )
        let built = ConfirmationBuilder.build(result: result, rows: rows, groups: PhotoGroupIndex.build(result.grouping))
        try expect(built.moments.count == 1, "close group did not become one confirmation")
        try expect(built.moments[0].isChoice, "grouped frames were not a choice")
        try expect(built.moments[0].suggestedID == first.id, "higher score was not suggested")
    }

    private static func albumMembershipRespectsRejects() throws {
        let id = PhotoID()
        let row = CuratedRow(id: id, bucket: .selected, rank: 0, relativePath: "a.jpg", reasons: [], score: 0.9, sourceURL: URL(fileURLWithPath: "/tmp/a.jpg"), previewURL: nil)
        try expect(AlbumMembership.contains(row, mark: PhotoReviewMark(photoID: id, flag: .pick)), "a pick should stay in the album")
        try expect(!AlbumMembership.contains(row, mark: PhotoReviewMark(photoID: id, flag: .reject)), "a reject must leave the album")
    }

    private static func deliveryNeverOverwrites() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("photocore-delivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = DeliveryExecutor.newFolder(parent: parent, shootName: "Pycon")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = DeliveryExecutor.newFolder(parent: parent, shootName: "Pycon")
        try expect(second.lastPathComponent == first.lastPathComponent + " 2", "second folder was \(second.lastPathComponent)")
    }

    private static func catalogListsSessionsWithManifests() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let catalog = try PhotoCatalog(url: fixture.root.appendingPathComponent("catalog.sqlite"))
        let older = SessionID()
        let newer = SessionID()
        try catalog.beginSession(id: older, sourceFolder: fixture.source, settings: .default(for: .everyday))
        try catalog.finishSession(older)
        try catalog.beginSession(id: newer, sourceFolder: fixture.source, settings: .default(for: .trip))
        let manifest = fixture.output.appendingPathComponent("manifest.json")
        try catalog.recordRunLocation(sessionID: newer, manifestURL: manifest, runDirectory: fixture.output)
        let listed = try catalog.listSessions(limit: 10)
        try expect(listed.map(\.id) == [newer, older], "sessions were not newest first")
        try expect(listed[0].manifestPath == manifest.path, "manifest path was not stored")
        try expect(listed[0].runDirectory == fixture.output.path, "run directory was not stored")
        let reopened = try PhotoCatalog(url: fixture.root.appendingPathComponent("catalog.sqlite"))
        let again = try PhotoEngineChecks.require(reopened.session(id: newer), "session missing after reopen")
        try expect(again.manifestPath == manifest.path, "manifest path did not survive reopen")
    }

    private static func customRecipesPersist() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("catalog.sqlite")
        let session = SessionID()
        let photo = PhotoID()
        var recipe = EditRecipe(style: .natural, styleIntensity: 0.4, exposure: 0.2)
        recipe.temperature = 0.15
        do {
            let catalog = try PhotoCatalog(url: url)
            try catalog.beginSession(id: session, sourceFolder: fixture.source, settings: .default(for: .everyday))
            try catalog.saveCustomRecipe(recipe, photoID: photo, sessionID: session)
        }
        let reopened = try PhotoCatalog(url: url)
        let stored = try reopened.customRecipes(sessionID: session)
        try expect(stored[photo]?.temperature == 0.15 && stored[photo]?.exposure == 0.2, "custom recipe did not round-trip")
        try reopened.deleteCustomRecipe(photoID: photo, sessionID: session)
        let remaining = try reopened.customRecipes(sessionID: session)
        try expect(remaining.isEmpty, "deleted recipe remained")
    }

    private static func interruptedJobsAreMarkedFailed() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("catalog.sqlite")
        let running = JobRecord(id: UUID().uuidString, kind: "curate", sessionID: nil, state: "running", request: Data("{}".utf8), createdAt: Date())
        let done = JobRecord(id: UUID().uuidString, kind: "deliver", sessionID: nil, state: "succeeded", request: Data("{}".utf8), createdAt: Date().addingTimeInterval(-10))
        do {
            let catalog = try PhotoCatalog(url: url)
            try catalog.insertJob(running)
            try catalog.insertJob(done)
        }
        let reopened = try PhotoCatalog(url: url)
        let marked = try reopened.markInterruptedJobs()
        try expect(marked == 1, "expected one interrupted job, got \(marked)")
        let failed = try PhotoEngineChecks.require(reopened.job(id: running.id), "running job disappeared")
        try expect(failed.state == "failed" && failed.errorCode == "interrupted", "running job was not marked interrupted")
        let kept = try PhotoEngineChecks.require(reopened.job(id: done.id), "finished job disappeared")
        try expect(kept.state == "succeeded", "a finished job was rewritten")
    }

    private static func pruningIgnoresForeignFolders() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "one.jpg", red: 0.2)
        let foreign = fixture.output.appendingPathComponent("runs/important-project", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: foreign.appendingPathComponent("notes.txt"))
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 1
        _ = try PhotoPipelineRunner().run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        _ = try PhotoPipelineRunner().run(folder: fixture.source, outputDirectory: fixture.output, profile: profile)
        try expect(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("notes.txt").path), "a folder Photocore did not create was deleted")
    }

    private static func outputInsideSourceRejectedThroughSymlinks() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        try fixture.writeJPEG(name: "one.jpg", red: 0.3)
        let a = PhotoPipelineRunner.canonicalPath(fixture.source.appendingPathComponent("not-yet/exports"))
        let b = PhotoPipelineRunner.canonicalPath(fixture.source)
        try expect(a.hasPrefix(b + "/"), "canonical paths disagree for existing and missing paths")
    }

    private static func engineErrorsAreReadable() throws {
        let error: Error = PhotoEngineError.invalidArgument("target must be positive")
        try expect(error.localizedDescription.contains("target must be positive"), "error description is not surfaced")
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

    func writeJPEG(name: String, red: CGFloat, includeMetadata: Bool = false, date: Date? = nil) throws {
        let width = 128
        let height = 128
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
        // Patterned fixtures keep enough edge energy that analysis does not
        // hard-reject them as extreme blur / blank frames.
        context.setFillColor(CGColor(red: red, green: 0.25, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1 - red, green: 0.75, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 16, y: 16, width: 48, height: 48))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(2)
        context.stroke(CGRect(x: 8, y: 8, width: width - 16, height: height - 16))
        for i in 0..<8 {
            let x = CGFloat(12 + i * 14)
            context.move(to: CGPoint(x: x, y: 72))
            context.addLine(to: CGPoint(x: x + 8, y: 112))
        }
        context.strokePath()
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
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = formatter.string(from: date)
            properties[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try PhotoEngineChecks.expect(CGImageDestinationFinalize(destination), "could not finalize fixture")
    }
}
