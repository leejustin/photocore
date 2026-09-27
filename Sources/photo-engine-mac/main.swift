import AppKit
import Foundation
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct PhotoEngineMacApp: App {
    @StateObject private var model = PhotoEngineViewModel()

    var body: some Scene {
        WindowGroup("Photocore") {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Folder…") { model.showingChooser = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Cull") {
                Button("Album") { model.workspace = .album }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(model.result == nil)
                Button("Confirm") { model.workspace = .confirm }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(model.result == nil)
                Divider()
                Button("Pick") { model.flagFocused(.pick, advance: true) }
                    .keyboardShortcut("p", modifiers: [.command])
                    .disabled(model.focusedRow == nil)
                Button("Reject") { model.flagFocused(.reject, advance: true) }
                    .keyboardShortcut("x", modifiers: [.command])
                    .disabled(model.focusedRow == nil)
                Button("Clear Flag") { model.flagFocused(.unflagged, advance: false) }
                    .keyboardShortcut("u", modifiers: [.command])
                    .disabled(model.focusedRow == nil)
                Button("Undo Mark") { model.undoMark() }
                    .keyboardShortcut("z", modifiers: .command)
            }
        }
    }
}

@MainActor
final class PhotoEngineViewModel: ObservableObject {
    @Published var selectedFolder: URL?
    @Published var mode: CurationMode = .everyday {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "PhotoEngine.mode") }
    }
    @Published var aggressiveness: CullingAggressiveness = .balanced {
        didSet { UserDefaults.standard.set(aggressiveness.rawValue, forKey: "PhotoEngine.aggressiveness") }
    }
    @Published var style: StylePreset = .natural {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "PhotoEngine.style") }
    }
    @Published var styleIntensity: Double = 0.65 {
        didSet { UserDefaults.standard.set(styleIntensity, forKey: "PhotoEngine.styleIntensity") }
    }
    @Published var exportPreset: ExportPreset = .full {
        didSet { UserDefaults.standard.set(exportPreset.rawValue, forKey: "PhotoEngine.exportPreset") }
    }
    @Published var sizingMode: ShortlistSizingMode = .count {
        didSet { UserDefaults.standard.set(sizingMode.rawValue, forKey: "PhotoEngine.sizingMode") }
    }
    @Published var targetCount: Double = 40 {
        didSet { UserDefaults.standard.set(targetCount, forKey: "PhotoEngine.targetCount") }
    }
    @Published var keepPercentage: Double = 30 {
        didSet { UserDefaults.standard.set(keepPercentage, forKey: "PhotoEngine.keepPercentage") }
    }
    @Published var sourcePhotoCount: Int?
    @Published var isCountingPhotos = false
    @Published var status = "Choose a folder of photos to begin."
    @Published var isRunning = false
    @Published var result: PipelineResult?
    @Published var errorMessage: String?
    @Published var progress: PipelineProgress?
    @Published var rows: [CuratedRow] = []
    @Published var cleanupPlan: CleanupPlan?
    @Published var cleanupReport: CleanupReport?
    @Published var showingChooser = false
    @Published var workspace: StudioWorkspace = .album
    @Published var confirmations: [ConfirmationMoment] = []
    @Published var skippedConfirmationIDs: Set<String> = []
    @Published var filter: LibraryFilter = .all
    @Published var focusedID: PhotoID?
    @Published var reviewMarks: [PhotoID: PhotoReviewMark] = [:]
    @Published var groupsByPhoto: [PhotoID: PhotoGroup] = [:]
    @Published var cellSize: Double = 176
    @Published var developRecipe = EditRecipe()
    @Published var showingOriginal = false
    @Published var surveying = false
    @Published var loupeZoom: LoupeZoom = .fit
    @Published var customRecipes: [PhotoID: EditRecipe] = [:]
    @Published var isReexportingLook = false
    @Published var selectedLookID: String = "builtin.natural"
    @Published var autoStraightenLook = true
    @Published var lookTemperature: Double = 0
    private var undoStack: [PhotoReviewMark] = []

    private let runner = PhotoPipelineRunner()
    private var processingTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "PhotoEngine.mode"), let value = CurationMode(rawValue: raw) {
            mode = value
        }
        if let raw = defaults.string(forKey: "PhotoEngine.aggressiveness"), let value = CullingAggressiveness(rawValue: raw) {
            aggressiveness = value
        }
        if let raw = defaults.string(forKey: "PhotoEngine.style"), let value = StylePreset(rawValue: raw) {
            style = value
        }
        if defaults.object(forKey: "PhotoEngine.styleIntensity") != nil {
            styleIntensity = min(max(defaults.double(forKey: "PhotoEngine.styleIntensity"), 0), 1)
        }
        if let raw = defaults.string(forKey: "PhotoEngine.exportPreset"), let value = ExportPreset(rawValue: raw) {
            exportPreset = value
        }
        if let raw = defaults.string(forKey: "PhotoEngine.sizingMode"), let value = ShortlistSizingMode(rawValue: raw) {
            sizingMode = value
        }
        if defaults.object(forKey: "PhotoEngine.targetCount") != nil {
            targetCount = min(max(defaults.double(forKey: "PhotoEngine.targetCount"), 5), 150)
        }
        if defaults.object(forKey: "PhotoEngine.keepPercentage") != nil {
            keepPercentage = min(max(defaults.double(forKey: "PhotoEngine.keepPercentage"), 5), 90)
        }
    }

    var targetCountInt: Int { max(1, Int(targetCount.rounded())) }
    var keepPercentageInt: Int { max(5, min(90, Int(keepPercentage.rounded()))) }

    var shortlistEstimateText: String? {
        guard let sourcePhotoCount, sourcePhotoCount > 0 else { return nil }
        switch sizingMode {
        case .count:
            let target = min(targetCountInt, sourcePhotoCount)
            return "About \(target) of \(sourcePhotoCount) photos"
        case .percentage:
            let range = ShortlistEstimate.estimatedKeepRange(
                totalPhotos: sourcePhotoCount,
                sizingMode: sizingMode,
                targetCount: targetCountInt,
                keepPercentage: Double(keepPercentageInt),
                aggressiveness: aggressiveness
            )
            if range.lowerBound == range.upperBound {
                return "Roughly \(range.lowerBound) of \(sourcePhotoCount) photos (\(keepPercentageInt)% requested)"
            }
            return "Roughly \(range.lowerBound)–\(range.upperBound) of \(sourcePhotoCount) photos (\(keepPercentageInt)% requested)"
        }
    }

    func refreshSourcePhotoCount() {
        guard let selectedFolder else {
            sourcePhotoCount = nil
            return
        }
        isCountingPhotos = true
        let folder = selectedFolder
        Task.detached(priority: .utility) { [weak self] in
            let accessed = folder.startAccessingSecurityScopedResource()
            defer {
                if accessed { folder.stopAccessingSecurityScopedResource() }
            }
            let count = (try? PhotoFolderImporter().countSupportedPhotos(in: folder)) ?? 0
            await MainActor.run { [weak self] in
                guard self?.selectedFolder == folder else { return }
                self?.sourcePhotoCount = count > 0 ? count : nil
                self?.isCountingPhotos = false
            }
        }
    }

    func process() {
        guard let selectedFolder else { return }
        let mode = mode
        let aggressiveness = aggressiveness
        let style = style
        let styleIntensity = styleIntensity
        let sizingMode = sizingMode
        let keepPercentageInt = keepPercentageInt
        let targetCountInt = targetCountInt
        let exportSpecification = ExportSpecification(preset: exportPreset)
        let outputURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("PhotoEngine Exports", isDirectory: true)
            .appendingPathComponent(selectedFolder.lastPathComponent + "-curated", isDirectory: true)

        isRunning = true
        result = nil
        rows = []
        cleanupPlan = nil
        cleanupReport = nil
        errorMessage = nil
        progress = nil
        workspace = .album
        focusedID = nil
        confirmations = []
        skippedConfirmationIDs = []
        undoStack.removeAll()
        status = "Processing \(selectedFolder.lastPathComponent)…"

        let runner = runner
        let (progressUpdates, progressContinuation) = AsyncStream.makeStream(of: PipelineProgress.self)
        Task { @MainActor [weak self] in
            for await update in progressUpdates {
                self?.progress = update
                self?.status = update.message
            }
        }
        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            defer { progressContinuation.finish() }
            let accessed = selectedFolder.startAccessingSecurityScopedResource()
            defer {
                if accessed { selectedFolder.stopAccessingSecurityScopedResource() }
            }
            do {
                var profile = ScoringProfile.default(for: mode)
                profile.apply(aggressiveness: aggressiveness)
                profile.style = style
                profile.styleIntensity = styleIntensity
                profile.sizingMode = sizingMode
                profile.keepPercentage = Double(keepPercentageInt)
                profile.targetCount = targetCountInt
                let result = try runner.run(
                    folder: selectedFolder,
                    outputDirectory: outputURL,
                    profile: profile,
                    exportSpecification: exportSpecification,
                    progress: { update in progressContinuation.yield(update) },
                    shouldCancel: { Task.isCancelled }
                )
                await self?.finish(result: result, outputURL: outputURL)
            } catch is CancellationError {
                await self?.cancelled()
            } catch {
                await self?.fail(error)
            }
        }
    }

    func finish(result: PipelineResult, outputURL: URL) {
        self.result = result
        rows = Self.makeRows(result: result)
        groupsByPhoto = Self.indexGroups(result.grouping)
        if let stored = try? runner.reviewMarks(for: result.analyzed.map(\.id)) {
            reviewMarks = Dictionary(stored.map { ($0.photoID, $0) }, uniquingKeysWith: { _, latest in latest })
        }
        filter = rows.contains { $0.bucket == .selected || $0.bucket == .protected } ? .picks : .all
        confirmations = makeConfirmations()
        skippedConfirmationIDs = []
        seedInCameraRatings()
        focusedID = confirmations.first?.suggestedID ?? visibleRows.first?.id
        workspace = confirmations.isEmpty ? .look : .confirm
        isRunning = false
        progress = nil
        let summary = albumSummary
        if confirmations.isEmpty {
            status = "\(summary.sentence) Choose a look when you are ready."
        } else {
            status = "\(summary.sentence) \(confirmations.count) close moment\(confirmations.count == 1 ? "" : "s") to confirm."
        }
        processingTask = nil
    }

    struct AlbumSummary {
        var total: Int
        var kept: Int
        var trash: Int
        var close: Int
        var pending: Int

        var sentence: String {
            "\(total) in · \(kept) kept · \(trash) trash · \(close) close"
        }
    }

    var albumSummary: AlbumSummary {
        let trash = rows.filter { $0.reasons.contains(where: PhotoTechnicalReject.isTechnicalRejectReason) }.count
        let close = rows.filter { $0.bucket == .review || $0.reasons.contains("close to a photo we kept") }.count
        return AlbumSummary(
            total: rows.count,
            kept: count(.picks),
            trash: trash,
            close: close,
            pending: pendingConfirmations.count
        )
    }

    private func seedInCameraRatings() {
        guard let result else { return }
        for asset in result.imported {
            guard let stars = asset.metadata.rating, stars > 0 else { continue }
            var mark = mark(for: asset.id)
            if mark.stars == 0 {
                mark.stars = stars
                reviewMarks[asset.id] = mark
                try? runner.saveReviewMark(mark)
            }
        }
    }

    func prepareCleanup() {
        guard let result else { return }
        let accessed = selectedFolder?.startAccessingSecurityScopedResource() ?? false
        defer {
            if accessed { selectedFolder?.stopAccessingSecurityScopedResource() }
        }
        cleanupReport = nil
        let plan = PhotoCleanupPlanner.preview(result: result, policy: .keepSelectedOriginals)
        do {
            try runner.recordCleanupPlan(plan)
            cleanupPlan = plan
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func executeCleanup() {
        guard let plan = cleanupPlan else { return }
        let accessed = selectedFolder?.startAccessingSecurityScopedResource() ?? false
        defer {
            if accessed { selectedFolder?.stopAccessingSecurityScopedResource() }
        }
        cleanupReport = PhotoCleanupPlanner.moveToTrash(plan)
        let moved = cleanupReport?.movedPhotoIDs.count ?? 0
        let skipped = cleanupReport?.skipped.count ?? 0
        try? runner.updateCleanupPlanStatus(
            plan.id,
            status: skipped == 0 ? "complete" : "partial",
            approvedAt: Date(),
            completedAt: Date()
        )
        status = skipped == 0
            ? "Moved \(moved) exact duplicate(s) to Trash."
            : "Moved \(moved) duplicate(s); \(skipped) item(s) were skipped."
    }

    func override(photoID: PhotoID, bucket: SelectionBucket) {
        guard let result else { return }
        do {
            try runner.setOverride(
                sessionID: result.sessionID,
                photoID: photoID,
                bucket: bucket,
                reason: "user chose \(bucket.rawValue)"
            )
            let updatedShortlist = PhotoSelectionEngine.applying(
                [SelectionOverride(photoID: photoID, bucket: bucket, reason: "user chose \(bucket.rawValue)")],
                to: result.shortlist
            )
            var exports = result.exports
            var storageSummary = result.storageSummary
            var removedExport = false
            if !GeneratedArtifactCleanup.bucketsThatRetainExports.contains(bucket),
               result.exports.contains(where: { $0.photoID == photoID }) {
                let discard = try runner.discardExport(photoID: photoID, from: result)
                exports = discard.exports
                storageSummary = discard.storageSummary
                removedExport = discard.removedPath != nil
            }
            try Self.updateManifest(result.manifestURL, shortlist: updatedShortlist, exports: exports)
            self.result = PipelineResult(
                sessionID: result.sessionID,
                imported: result.imported,
                analyzed: result.analyzed,
                grouping: result.grouping,
                scored: result.scored,
                shortlist: updatedShortlist,
                exports: exports,
                manifestURL: result.manifestURL,
                warnings: result.warnings,
                runDirectory: result.runDirectory,
                storageSummary: storageSummary,
                metrics: result.metrics,
                exportSpecification: result.exportSpecification
            )
            rows = Self.makeRows(result: self.result!)
            cleanupPlan = nil
            cleanupReport = nil
            if removedExport {
                status = "Excluded photo and moved its export to Trash."
            } else {
                status = "Saved your \(bucket.rawValue) override."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fail(_ error: Error) {
        isRunning = false
        progress = nil
        errorMessage = error.localizedDescription
        status = "Processing failed."
        processingTask = nil
    }

    func cancel() {
        processingTask?.cancel()
        status = "Cancelling…"
    }

    func cancelled() {
        isRunning = false
        progress = nil
        status = "Processing cancelled."
        processingTask = nil
    }

    func revealExports() {
        guard let result else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.manifestURL])
    }

    func selectFolder(_ folder: URL) {
        selectedFolder = folder
        result = nil
        rows = []
        errorMessage = nil
        cleanupPlan = nil
        cleanupReport = nil
        sourcePhotoCount = nil
        focusedID = nil
        groupsByPhoto = [:]
        surveying = false
        loupeZoom = .fit
        reviewMarks = [:]
        customRecipes = [:]
        undoStack.removeAll()
        filter = .all
        confirmations = []
        skippedConfirmationIDs = []
        workspace = .album
        status = "Ready to process \(folder.lastPathComponent)."
        refreshSourcePhotoCount()
    }

    var visibleRows: [CuratedRow] {
        rows
            .filter { passes(filter, row: $0) }
            .sorted { ($0.rank ?? .max, -$0.score) < ($1.rank ?? .max, -$1.score) }
    }

    var focusedRow: CuratedRow? {
        if let focusedID, let row = rows.first(where: { $0.id == focusedID }) { return row }
        return visibleRows.first
    }

    func count(_ filter: LibraryFilter) -> Int {
        rows.filter { passes(filter, row: $0) }.count
    }

    func mark(for id: PhotoID) -> PhotoReviewMark {
        reviewMarks[id] ?? PhotoReviewMark(photoID: id)
    }

    func analyzedPhoto(id: PhotoID) -> AnalyzedPhoto? {
        result?.analyzed.first { $0.id == id }
    }

    func passes(_ filter: LibraryFilter, row: CuratedRow) -> Bool {
        switch filter {
        case .all:
            return true
        case .picks:
            return row.bucket == .selected || row.bucket == .protected
        case .alternates:
            return row.bucket == .alternate
        case .review:
            return row.bucket == .review
        case .closeHidden:
            return row.bucket == .hidden
                && row.reasons.contains("close to a photo we kept")
                && !row.reasons.contains(where: PhotoTechnicalReject.isTechnicalRejectReason)
        case .trash:
            return row.reasons.contains(where: PhotoTechnicalReject.isTechnicalRejectReason)
        case .duplicates:
            return groupsByPhoto[row.id] != nil
        case .rejected:
            return row.bucket == .hidden || mark(for: row.id).flag == .reject
        case .myPicks:
            return mark(for: row.id).flag == .pick
        case .starred:
            return mark(for: row.id).stars > 0
        }
    }

    func restoreToAlbum(_ id: PhotoID) {
        override(photoID: id, bucket: .selected)
        updateMark(id) { $0.flag = .pick }
        status = "Restored to the album."
    }

    var availableLooks: [AlbumLook] { AlbumLookLibrary.shared.allLooks() }

    var selectedLook: AlbumLook? {
        availableLooks.first { $0.id == selectedLookID } ?? availableLooks.first
    }

    func importLook(from url: URL, kind: AlbumLook.Kind) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let look: AlbumLook
            switch kind {
            case .lut:
                look = try AlbumLookLibrary.shared.importCubeLUT(from: url)
            case .xmp:
                look = try AlbumLookLibrary.shared.importXMPPreset(from: url)
            case .builtin:
                return
            }
            selectedLookID = look.id
            status = "Imported look “\(look.name)”."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyAlbumLook() {
        guard let result, !isReexportingLook else { return }
        let keepers = result.analyzed.filter { photo in
            result.shortlist.selectedIDs.contains(photo.id)
        }
        guard !keepers.isEmpty else { return }
        var look = selectedLook ?? AlbumLook.builtins[0]
        look.temperature = lookTemperature
        look.autoStraighten = autoStraightenLook
        isReexportingLook = true
        status = "Applying \(look.name) to \(keepers.count) keepers…"
        let exportDirectory = result.runDirectory.appendingPathComponent("shortlist", isDirectory: true)
        let exportSpecification = ExportSpecification(preset: exportPreset)
        let runDirectory = result.runDirectory
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
                let renderer = ApplePhotoRenderer()
                var exports: [ExportedPhoto] = []
                for (index, photo) in keepers.enumerated() {
                    let horizon = look.autoStraighten
                        ? ApplePhotoRenderer.detectHorizonDegrees(url: photo.asset.url, orientation: photo.asset.metadata.orientation)
                        : nil
                    let recipe = look.recipe(for: photo, horizonDegrees: horizon)
                    let fileName = String(format: "%03d-%@.jpg", index + 1, photo.asset.url.deletingPathExtension().lastPathComponent)
                    let outputURL = exportDirectory.appendingPathComponent(fileName)
                    let exported = try renderer.render(
                        photo: photo,
                        outputURL: outputURL,
                        recipe: recipe,
                        exportSpecification: exportSpecification
                    )
                    exports.append(exported)
                }
                await self?.didApplyAlbumLook(exports: exports, runDirectory: runDirectory, lookName: look.name)
            } catch {
                await self?.noteLookFailure(error)
            }
        }
    }

    @MainActor
    private func didApplyAlbumLook(exports: [ExportedPhoto], runDirectory: URL, lookName: String) {
        guard let result else {
            isReexportingLook = false
            return
        }
        self.result = PipelineResult(
            sessionID: result.sessionID,
            imported: result.imported,
            analyzed: result.analyzed,
            grouping: result.grouping,
            scored: result.scored,
            shortlist: result.shortlist,
            exports: exports,
            manifestURL: result.manifestURL,
            warnings: result.warnings,
            runDirectory: runDirectory,
            storageSummary: result.storageSummary,
            metrics: result.metrics,
            exportSpecification: result.exportSpecification
        )
        rows = Self.makeRows(result: self.result!)
        isReexportingLook = false
        status = "Applied \(lookName) to \(exports.count) keepers."
        workspace = .album
    }

    @MainActor
    private func noteLookFailure(_ error: Error) {
        isReexportingLook = false
        errorMessage = error.localizedDescription
        status = "Could not apply that look."
    }

    func prepareHandoffPackage() {
        guard let result else { return }
        let accessed = selectedFolder?.startAccessingSecurityScopedResource() ?? false
        defer {
            if accessed { selectedFolder?.stopAccessingSecurityScopedResource() }
        }
        let root = result.runDirectory.appendingPathComponent("handoff", isDirectory: true)
        let keepersDir = root.appendingPathComponent("01-keepers", isDirectory: true)
        let alternatesDir = root.appendingPathComponent("02-alternates", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: keepersDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: alternatesDir, withIntermediateDirectories: true)
            var written = 0
            for row in rows where row.bucket == .selected || row.bucket == .protected || mark(for: row.id).flag == .pick {
                let mark = sidecarMark(for: row)
                let base = row.sourceURL.deletingPathExtension().lastPathComponent
                // Always write XMP beside the master (RAW or HEIC) so Lightroom
                // picks up ratings without importing our JPEG proofs first.
                _ = try LightroomSidecar.write(mark, named: base, to: row.sourceURL.deletingLastPathComponent())
                _ = try LightroomSidecar.write(mark, named: base, to: keepersDir)
                if let export = result.exports.first(where: { $0.photoID == row.id }) {
                    let source = URL(fileURLWithPath: export.outputPath)
                    let dest = keepersDir.appendingPathComponent(source.lastPathComponent)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: source, to: dest)
                }
                written += 1
            }
            for row in rows where row.bucket == .alternate {
                let mark = sidecarMark(for: row)
                let base = row.sourceURL.deletingPathExtension().lastPathComponent
                _ = try LightroomSidecar.write(mark, named: base, to: alternatesDir)
                written += 1
            }
            let readme = """
            Photocore handoff
            - 01-keepers: finished JPEGs plus XMP for Lightroom
            - XMP was also written beside each master file (including RAW)
            - 02-alternates: XMP for near-duplicates you may want later
            Image originals were not modified.
            """
            try Data(readme.utf8).write(to: root.appendingPathComponent("README.txt"), options: .atomic)
            status = "Packed \(written) files for Lightroom."
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func flagFocused(_ flag: ReviewFlag, advance: Bool) {
        guard let id = focusedRow?.id else { return }
        updateMark(id) { $0.flag = flag }
        guard advance else { return }
        if surveying, let group = groupsByPhoto[id], let index = group.memberIDs.firstIndex(of: id), group.memberIDs.indices.contains(index + 1) {
            focusSibling(offset: 1)
        } else {
            focusNext()
            if surveying, let focusedID, groupsByPhoto[focusedID] == nil {
                surveying = false
            }
        }
    }

    func toggleSurvey() {
        guard let id = focusedRow?.id, groupsByPhoto[id] != nil else {
            surveying = false
            return
        }
        surveying.toggle()
    }

    var pendingConfirmations: [ConfirmationMoment] {
        confirmations.filter { moment in
            !skippedConfirmationIDs.contains(moment.id)
                && !moment.candidateIDs.contains { mark(for: $0).flag != .unflagged }
        }
    }

    var currentConfirmation: ConfirmationMoment? {
        pendingConfirmations.first
    }

    func acceptSuggestion() {
        guard let moment = currentConfirmation else { return }
        updateMark(moment.suggestedID) { $0.flag = .pick }
        for id in moment.candidateIDs where id != moment.suggestedID {
            updateMark(id) { $0.flag = .reject }
        }
        status = confirmationStatus
    }

    func useConfirmationCandidate(_ id: PhotoID) {
        guard let moment = currentConfirmation, moment.candidateIDs.contains(id) else { return }
        if id == moment.suggestedID {
            acceptSuggestion()
            return
        }
        updateMark(id) { $0.flag = .pick }
        if let row = rows.first(where: { $0.id == id }), row.bucket != .selected, row.bucket != .protected {
            override(photoID: id, bucket: .selected)
        }
        for other in moment.candidateIDs where other != id {
            updateMark(other) { $0.flag = .reject }
            if rows.first(where: { $0.id == other })?.bucket == .selected {
                override(photoID: other, bucket: .alternate)
            }
        }
        status = confirmationStatus
    }

    func dropSuggestion() {
        guard let moment = currentConfirmation else { return }
        updateMark(moment.suggestedID) { $0.flag = .reject }
        override(photoID: moment.suggestedID, bucket: .hidden)
        status = confirmationStatus
    }

    func skipConfirmation() {
        guard let moment = currentConfirmation else { return }
        skippedConfirmationIDs.insert(moment.id)
        status = confirmationStatus
    }

    func focusConfirmation(offset: Int) {
        guard let moment = currentConfirmation else { return }
        let ids = moment.candidateIDs
        let current = focusedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = min(max(current + offset, 0), ids.count - 1)
        focusedID = ids[next]
    }

    private var confirmationStatus: String {
        let left = pendingConfirmations.count
        if left == 0 { return "Confirmed. The album is ready to hand off." }
        return "\(left) close moment\(left == 1 ? "" : "s") left."
    }

    private func makeConfirmations() -> [ConfirmationMoment] {
        var moments: [ConfirmationMoment] = []
        var covered = Set<PhotoID>()
        let groups = result?.grouping.groups ?? []
        for group in groups where group.kind != .exactDuplicate && group.memberIDs.count > 1 {
            let visible = group.memberIDs.compactMap { id in rows.first { $0.id == id } }.filter { $0.bucket != .hidden }
            guard visible.count >= 2 else { continue }
            let ranked = visible.sorted { $0.score > $1.score }
            guard let best = ranked.first, let second = ranked.dropFirst().first else { continue }
            let margin = best.score - second.score
            guard margin < 0.08 else { continue }
            covered.formUnion(ranked.map(\.id))
            moments.append(ConfirmationMoment(
                id: group.id.uuidString,
                suggestedID: best.id,
                candidateIDs: Array(ranked.prefix(4).map(\.id)),
                reason: best.reasons.first ?? "These frames are close.",
                margin: margin
            ))
        }
        for row in rows where row.bucket == .selected || row.bucket == .protected {
            guard !covered.contains(row.id), groupsByPhoto[row.id] == nil else { continue }
            let flags = analyzedPhoto(id: row.id)?.signals.qualityFlags.filter {
                $0 == "subject appears soft" || $0 == "face quality low" || $0 == PhotoTechnicalReject.eyesClosed
            } ?? []
            guard !flags.isEmpty else { continue }
            covered.insert(row.id)
            moments.append(ConfirmationMoment(
                id: row.id.description,
                suggestedID: row.id,
                candidateIDs: [row.id],
                reason: flags.joined(separator: " · "),
                margin: 0
            ))
        }
        for row in rows where row.bucket == .review && !covered.contains(row.id) {
            guard !row.reasons.contains(where: PhotoTechnicalReject.isTechnicalRejectReason) else { continue }
            moments.append(ConfirmationMoment(
                id: row.id.description,
                suggestedID: row.id,
                candidateIDs: [row.id],
                reason: row.reasons.first ?? "Close to a photo we kept.",
                margin: 0.05
            ))
        }
        return Array(moments.sorted { $0.margin < $1.margin }.prefix(16))
    }

    func cycleLoupeZoom() {
        loupeZoom = loupeZoom == .fit ? .actual : .fit
    }

    func zoomToEyes() {
        loupeZoom = .face
    }

    func primaryFaceBox(for id: PhotoID) -> CGRectCodable? {
        analyzedPhoto(id: id)?.signals.faces.max { lhs, rhs in
            lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
        }?.boundingBox
    }

    func setStars(_ stars: Int) {
        guard let id = focusedRow?.id else { return }
        updateMark(id) { $0.stars = stars }
    }

    func setColor(_ color: ReviewColor) {
        guard let id = focusedRow?.id else { return }
        updateMark(id) { $0.color = color }
    }

    func updateMark(_ id: PhotoID, _ mutate: (inout PhotoReviewMark) -> Void) {
        var mark = mark(for: id)
        undoStack.append(mark)
        if undoStack.count > 80 { undoStack.removeFirst() }
        mutate(&mark)
        mark.stars = min(5, max(0, mark.stars))
        reviewMarks[id] = mark
        do {
            try runner.saveReviewMark(mark)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undoMark() {
        guard let previous = undoStack.popLast() else { return }
        reviewMarks[previous.photoID] = previous
        focusedID = previous.photoID
        do {
            try runner.saveReviewMark(previous)
        } catch {
            errorMessage = error.localizedDescription
        }
        syncDevelopRecipe()
    }

    func focusNext() {
        stepFocus(1)
    }

    func focusPrevious() {
        stepFocus(-1)
    }

    func focusSibling(offset: Int) {
        guard let id = focusedRow?.id, let group = groupsByPhoto[id], let index = group.memberIDs.firstIndex(of: id) else { return }
        let next = index + offset
        guard group.memberIDs.indices.contains(next) else { return }
        focusedID = group.memberIDs[next]
        syncDevelopRecipe()
    }

    func syncDevelopRecipe() {
        guard let row = focusedRow, let photo = analyzedPhoto(id: row.id) else { return }
        if let custom = customRecipes[row.id] {
            developRecipe = custom
        } else {
            developRecipe = ApplePhotoRenderer.recipe(for: photo, style: style, intensity: styleIntensity)
        }
    }

    func setDevelopRecipe(_ recipe: EditRecipe) {
        developRecipe = recipe
        if let id = focusedRow?.id {
            customRecipes[id] = recipe
        }
    }

    func applyLook(_ style: StylePreset) {
        guard let row = focusedRow, let photo = analyzedPhoto(id: row.id) else { return }
        setDevelopRecipe(ApplePhotoRenderer.recipe(for: photo, style: style, intensity: styleIntensity))
    }

    func resetDevelopRecipe() {
        guard let id = focusedRow?.id else { return }
        customRecipes[id] = nil
        syncDevelopRecipe()
    }

    func renderFocusedEdit() {
        guard let result, let row = focusedRow, let photo = analyzedPhoto(id: row.id) else { return }
        let recipe = developRecipe
        let base = row.sourceURL.deletingPathExtension().lastPathComponent
        let output = result.runDirectory
            .appendingPathComponent("edits", isDirectory: true)
            .appendingPathComponent(base + ".jpg")
        status = "Rendering \(base)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try ApplePhotoRenderer().render(
                    photo: photo,
                    outputURL: output,
                    recipe: recipe,
                    exportSpecification: ExportSpecification(preset: .full)
                )
                await self?.didRender(output)
            } catch {
                await self?.noteRenderFailure(error)
            }
        }
    }

    func didRender(_ url: URL) {
        status = "Rendered \(url.lastPathComponent)."
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func noteRenderFailure(_ error: Error) {
        errorMessage = error.localizedDescription
        status = "Could not render that photo."
    }

    func sidecarMark(for row: CuratedRow) -> PhotoReviewMark {
        var mark = mark(for: row.id)
        if mark.flag == .unflagged {
            switch row.bucket {
            case .selected, .protected:
                mark.flag = .pick
            case .hidden:
                mark.flag = .reject
            case .alternate, .review:
                break
            }
        }
        return mark
    }

    func writeSidecars(besideOriginals: Bool) {
        guard let result else { return }
        let accessed = selectedFolder?.startAccessingSecurityScopedResource() ?? false
        defer {
            if accessed { selectedFolder?.stopAccessingSecurityScopedResource() }
        }
        let collection = result.runDirectory.appendingPathComponent("lightroom", isDirectory: true)
        var entries: [PortableCullEntry] = []
        do {
            for row in rows {
                let mark = sidecarMark(for: row)
                let folder = besideOriginals ? row.sourceURL.deletingLastPathComponent() : collection
                let base = besideOriginals
                    ? row.sourceURL.deletingPathExtension().lastPathComponent
                    : (row.relativePath as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: " - ")
                _ = try LightroomSidecar.write(mark, named: base, to: folder)
                entries.append(PortableCullEntry(
                    fileName: row.sourceURL.lastPathComponent,
                    relativePath: row.relativePath,
                    bucket: row.bucket.rawValue,
                    flag: mark.flag.rawValue,
                    stars: mark.stars,
                    color: mark.color.rawValue,
                    reasons: row.reasons
                ))
            }
            try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
            let decisionsURL = collection.appendingPathComponent("cull.json")
            try LightroomSidecar.decisionsData(entries).write(to: decisionsURL, options: .atomic)
            status = besideOriginals
                ? "Wrote \(entries.count) sidecars next to the originals."
                : "Wrote \(entries.count) sidecars into the export folder."
            NSWorkspace.shared.activateFileViewerSelecting([decisionsURL])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stepFocus(_ offset: Int) {
        let visible = visibleRows
        guard !visible.isEmpty else { return }
        guard let id = focusedRow?.id, let index = visible.firstIndex(where: { $0.id == id }) else {
            focusedID = visible[0].id
            syncDevelopRecipe()
            return
        }
        let next = min(max(index + offset, 0), visible.count - 1)
        focusedID = visible[next].id
        if surveying, let focusedID, groupsByPhoto[focusedID] == nil {
            surveying = false
        }
        syncDevelopRecipe()
    }

    private static func indexGroups(_ grouping: PhotoGrouping) -> [PhotoID: PhotoGroup] {
        var map: [PhotoID: PhotoGroup] = [:]
        let ordered = grouping.groups.sorted { groupRank($0.kind) < groupRank($1.kind) }
        for group in ordered where group.memberIDs.count > 1 {
            for id in group.memberIDs {
                map[id] = group
            }
        }
        return map
    }

    private static func groupRank(_ kind: PhotoGroup.Kind) -> Int {
        switch kind {
        case .scene: 0
        case .burst: 1
        case .exactDuplicate: 2
        }
    }

    private static func makeRows(result: PipelineResult) -> [CuratedRow] {
        let analyzedByID = Dictionary(uniqueKeysWithValues: result.analyzed.map { ($0.id, $0) })
        let scoreByID = Dictionary(uniqueKeysWithValues: result.scored.map { ($0.id, $0.score) })
        let exportByID = Dictionary(uniqueKeysWithValues: result.exports.map { ($0.photoID, URL(fileURLWithPath: $0.outputPath)) })
        return result.shortlist.decisions.compactMap { decision in
            guard let analyzed = analyzedByID[decision.photoID] else { return nil }
            return CuratedRow(
                id: decision.photoID,
                bucket: decision.bucket,
                rank: decision.rank,
                relativePath: analyzed.asset.relativePath,
                reasons: scoreByID[decision.photoID]?.reasons ?? decision.reasons,
                score: decision.score,
                sourceURL: analyzed.asset.url,
                previewURL: exportByID[decision.photoID]
            )
        }
    }

    private static func updateManifest(_ url: URL, shortlist: Shortlist, exports: [ExportedPhoto]? = nil) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(PipelineManifest.self, from: data)
        let updated = PipelineManifest(
            sessionID: manifest.sessionID,
            schemaVersion: manifest.schemaVersion,
            pipelineVersion: manifest.pipelineVersion,
            createdAt: manifest.createdAt,
            sourceFolder: manifest.sourceFolder,
            mode: manifest.mode,
            profile: manifest.profile,
            aggressiveness: manifest.aggressiveness,
            style: manifest.style,
            styleIntensity: manifest.styleIntensity,
            targetCount: manifest.targetCount,
            exportSpecification: manifest.exportSpecification,
            assets: manifest.assets,
            analyzed: manifest.analyzed,
            grouping: manifest.grouping,
            shortlist: shortlist,
            exports: exports ?? manifest.exports,
            warnings: manifest.warnings,
            metrics: manifest.metrics
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(updated).write(to: url, options: .atomic)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct CuratedRow: Identifiable, Sendable {
    let id: PhotoID
    let bucket: SelectionBucket
    let rank: Int?
    let relativePath: String
    let reasons: [String]
    let score: Double
    let sourceURL: URL
    let previewURL: URL?
}
