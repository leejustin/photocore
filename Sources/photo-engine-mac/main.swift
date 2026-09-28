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
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Folder…") { model.showingChooser = true }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(model.recentFolders, id: \.self) { url in
                        Button(url.lastPathComponent) { model.selectFolder(url) }
                    }
                }
                .disabled(model.recentFolders.isEmpty)
            }
            CommandMenu("Go") {
                Button("Confirm") { model.workspace = .confirm }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(model.result == nil)
                Button("Look") { model.workspace = .look }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(model.result == nil)
                Button("Deliver") { model.workspace = .deliver }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(model.result == nil)
                Divider()
                Button("Album") {
                    model.workspace = .album
                    model.albumMode = .grid
                }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(model.result == nil)
                Button("Adjust…") { model.openAdjust() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.result == nil)
            }
            CommandMenu("Photo") {
                Button("Pick") { model.pressPick() }
                    .disabled(model.focusedRow == nil)
                Button("Reject") { model.pressReject() }
                    .disabled(model.focusedRow == nil)
                Button("Clear Flag") { model.flagFocused(.unflagged, advance: false) }
                    .disabled(model.focusedRow == nil)
                Divider()
                Button("Undo Mark") { model.undoMark() }
                    .keyboardShortcut("z", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { model.showingShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
}

@MainActor
final class PhotoEngineViewModel: ObservableObject {
    @Published var selectedFolder: URL?
    @Published private(set) var recentFolders: [URL] = []
    private static let recentFoldersKey = "PhotoEngine.recentFolders"
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
        didSet {
            UserDefaults.standard.set(exportPreset.rawValue, forKey: "PhotoEngine.exportPreset")
            lookIsApplied = false
        }
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
    @Published var result: PipelineResult? {
        didSet {
            analyzedByID = Dictionary((result?.analyzed ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    @Published var errorMessage: String?
    @Published var progress: PipelineProgress?
    @Published var stageStartedAt: Date?
    @Published var rows: [CuratedRow] = [] {
        didSet {
            rowIndexByID = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            refreshDerivedRows()
        }
    }
    @Published var cleanupPlan: CleanupPlan?
    @Published var cleanupReport: CleanupReport?
    @Published var showingChooser = false
    @Published var showingShortcuts = false
    @Published var workspace: StudioWorkspace = .album
    @Published var workspaceBeforeAdjust: StudioWorkspace = .album
    @Published var confirmations: [ConfirmationMoment] = []
    @Published var confirmationsBeyondCap = 0
    @Published var skippedConfirmationIDs: Set<String> = []
    @Published var filter: LibraryFilter = .all {
        didSet { refreshDerivedRows() }
    }
    @Published var focusedID: PhotoID?
    @Published var reviewMarks: [PhotoID: PhotoReviewMark] = [:] {
        didSet { refreshDerivedRows() }
    }
    @Published var groupsByPhoto: [PhotoID: PhotoGroup] = [:] {
        didSet { refreshDerivedRows() }
    }
    @Published private(set) var visibleRows: [CuratedRow] = []
    @Published private(set) var filterCounts: [LibraryFilter: Int] = [:]
    private var rowIndexByID: [PhotoID: Int] = [:]
    private var analyzedByID: [PhotoID: AnalyzedPhoto] = [:]
    @Published var cellSize: Double = 176
    @Published var developRecipe = EditRecipe()
    @Published var showingOriginal = false
    @Published var surveying = false
    @Published var albumMode: AlbumMode = .grid
    @Published var loupeZoom: LoupeZoom = .fit
    @Published var customRecipes: [PhotoID: EditRecipe] = [:]
    @Published var isReexportingLook = false
    @Published var selectedLookID: String = "builtin.natural" {
        didSet {
            UserDefaults.standard.set(selectedLookID, forKey: "PhotoEngine.selectedLookID")
            lookIsApplied = false
        }
    }
    @Published var autoStraightenLook = true {
        didSet {
            UserDefaults.standard.set(autoStraightenLook, forKey: "PhotoEngine.autoStraightenLook")
            lookIsApplied = false
        }
    }
    @Published var lookTemperature: Double = 0 {
        didSet {
            UserDefaults.standard.set(lookTemperature, forKey: "PhotoEngine.lookTemperature")
            lookIsApplied = false
        }
    }
    @Published var deliverParentFolder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures", isDirectory: true)
        .appendingPathComponent("Photocore", isDirectory: true)
    @Published var deliverWritesSidecarsBesideOriginals = false
    @Published var isDelivering = false
    @Published var deliverProgress: (done: Int, total: Int)?
    @Published var lastDelivery: DeliveryReport?
    /// True when the run's rendered JPEGs already match the chosen look and size.
    @Published var lookIsApplied = false
    @Published var lookRenderProgress: (done: Int, total: Int)?
    @Published private(set) var horizonCache: [PhotoID: Double?] = [:]
    private var undoStack: [[PhotoReviewMark]] = []
    private var openUndoGroup: [PhotoReviewMark]?

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
        if let raw = defaults.string(forKey: "PhotoEngine.selectedLookID") {
            selectedLookID = raw
        }
        if defaults.object(forKey: "PhotoEngine.autoStraightenLook") != nil {
            autoStraightenLook = defaults.bool(forKey: "PhotoEngine.autoStraightenLook")
        }
        if defaults.object(forKey: "PhotoEngine.lookTemperature") != nil {
            lookTemperature = min(max(defaults.double(forKey: "PhotoEngine.lookTemperature"), -0.6), 0.6)
        }
        recentFolders = (defaults.stringArray(forKey: Self.recentFoldersKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func rememberRecentFolder(_ folder: URL) {
        var list = recentFolders.filter { $0.standardizedFileURL != folder.standardizedFileURL }
        list.insert(folder, at: 0)
        recentFolders = Array(list.prefix(6))
        UserDefaults.standard.set(recentFolders.map(\.path), forKey: Self.recentFoldersKey)
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
                self?.sourcePhotoCount = count
                self?.isCountingPhotos = false
            }
        }
    }

    var folderHasNoPhotos: Bool { !isCountingPhotos && sourcePhotoCount == 0 }

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
        albumMode = .grid
        focusedID = nil
        confirmations = []
        skippedConfirmationIDs = []
        undoStack.removeAll()
        status = "Processing \(selectedFolder.lastPathComponent)…"

        let runner = runner
        let (progressUpdates, progressContinuation) = AsyncStream.makeStream(of: PipelineProgress.self)
        Task { @MainActor [weak self] in
            for await update in progressUpdates {
                if self?.progress?.stage != update.stage {
                    self?.stageStartedAt = Date()
                }
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
        filter = count(.album) > 0 ? .album : .all
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
        lookIsApplied = false
        lastDelivery = nil
        if let selectedFolder { rememberRecentFolder(selectedFolder) }
    }

    struct AlbumSummary {
        var total: Int
        var kept: Int
        var unusable: Int
        var close: Int
        var pending: Int

        var sentence: String {
            "\(total) in · \(kept) in album · \(unusable) unusable · \(close) close"
        }
    }

    var albumSummary: AlbumSummary {
        let close = rows.filter { $0.bucket == .review || $0.reasons.contains("close to a photo we kept") }.count
        return AlbumSummary(
            total: rows.count,
            kept: count(.album),
            unusable: count(.unusable),
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
                status = "Removed from the album."
            } else {
                status = "Moved to \(bucket.displayName)."
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
        albumMode = .grid
        loupeZoom = .fit
        reviewMarks = [:]
        customRecipes = [:]
        horizonCache = [:]
        undoStack.removeAll()
        filter = .all
        confirmations = []
        skippedConfirmationIDs = []
        workspace = .album
        lookIsApplied = false
        lastDelivery = nil
        status = "Ready to process \(folder.lastPathComponent)."
        refreshSourcePhotoCount()
    }

    func row(for id: PhotoID) -> CuratedRow? {
        rowIndexByID[id].map { rows[$0] }
    }

    private func refreshDerivedRows() {
        var counts: [LibraryFilter: Int] = [:]
        for row in rows {
            for candidate in LibraryFilter.allCases where passes(candidate, row: row) {
                counts[candidate, default: 0] += 1
            }
        }
        filterCounts = counts
        visibleRows = rows
            .filter { passes(filter, row: $0) }
            .sorted { ($0.rank ?? .max, -$0.score) < ($1.rank ?? .max, -$1.score) }
    }

    var focusedRow: CuratedRow? {
        if let focusedID, let row = row(for: focusedID) { return row }
        return visibleRows.first
    }

    func count(_ filter: LibraryFilter) -> Int {
        filterCounts[filter] ?? 0
    }

    func mark(for id: PhotoID) -> PhotoReviewMark {
        reviewMarks[id] ?? PhotoReviewMark(photoID: id)
    }

    func analyzedPhoto(id: PhotoID) -> AnalyzedPhoto? {
        analyzedByID[id]
    }

    func passes(_ filter: LibraryFilter, row: CuratedRow) -> Bool {
        switch filter {
        case .album:
            return isInAlbum(row)
        case .alternates:
            return row.bucket == .alternate && !isInAlbum(row)
        case .needsLook:
            return row.bucket == .review && !isInAlbum(row)
        case .hidden:
            return !isInAlbum(row) && (row.bucket == .hidden || mark(for: row.id).flag == .reject)
        case .unusable:
            return row.reasons.contains(where: PhotoTechnicalReject.isTechnicalRejectReason)
        case .all:
            return true
        case .picked:
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

    /// `look` with the user's warmth and auto-straighten choices applied, rendered for `photo`.
    /// Look previews, Adjust, Apply look and Deliver all go through here.
    func recipe(for photo: AnalyzedPhoto, look: AlbumLook) -> EditRecipe {
        var look = look
        look.temperature += lookTemperature
        look.autoStraighten = autoStraightenLook
        let horizon: Double? = autoStraightenLook ? (horizonCache[photo.id] ?? nil) : nil
        return look.recipe(for: photo, horizonDegrees: horizon)
    }

    var effectiveLook: AlbumLook {
        var look = selectedLook ?? AlbumLook.builtins[0]
        look.temperature += lookTemperature
        look.autoStraighten = autoStraightenLook
        return look
    }

    /// The album-look recipe for a photo before any per-photo Adjust edits.
    func baseRecipe(for photo: AnalyzedPhoto) -> EditRecipe {
        recipe(for: photo, look: selectedLook ?? AlbumLook.builtins[0])
    }

    /// In the album unless the user rejected it: AI keepers, protected photos, and the user's own picks.
    func isInAlbum(_ row: CuratedRow) -> Bool {
        let flag = mark(for: row.id).flag
        if flag == .reject { return false }
        return row.bucket == .selected || row.bucket == .protected || flag == .pick
    }

    var deliverRows: [CuratedRow] {
        rows.filter(isInAlbum).sorted { ($0.rank ?? .max, -$0.score) < ($1.rank ?? .max, -$1.score) }
    }

    var lookSamplePhotos: [AnalyzedPhoto] {
        deliverRows.prefix(9).compactMap { analyzedPhoto(id: $0.id) }
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
        let keepers = deliverRows.compactMap { analyzedPhoto(id: $0.id) }
        let customs = customRecipes
        guard !keepers.isEmpty else { return }
        let look = effectiveLook
        isReexportingLook = true
        lookRenderProgress = (0, keepers.count)
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
                    let recipe = customs[photo.id] ?? look.recipe(for: photo, horizonDegrees: horizon)
                    let fileName = String(format: "%03d-%@.jpg", index + 1, photo.asset.url.deletingPathExtension().lastPathComponent)
                    let outputURL = exportDirectory.appendingPathComponent(fileName)
                    let exported = try renderer.render(
                        photo: photo,
                        outputURL: outputURL,
                        recipe: recipe,
                        exportSpecification: exportSpecification
                    )
                    exports.append(exported)
                    await self?.noteLookProgress(done: index + 1, total: keepers.count)
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
            lookRenderProgress = nil
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
        lookRenderProgress = nil
        lookIsApplied = true
        status = "Applied \(lookName) to \(exports.count) keepers."
        workspace = .deliver
    }

    @MainActor
    private func noteLookFailure(_ error: Error) {
        isReexportingLook = false
        lookRenderProgress = nil
        errorMessage = error.localizedDescription
        status = "Could not apply that look."
    }

    private func noteLookProgress(done: Int, total: Int) {
        lookRenderProgress = (done, total)
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

    /// P: keep. In Confirm it keeps the focused frame (or the suggestion).
    func pressPick() {
        if workspace == .confirm {
            if let moment = currentConfirmation, let focused = focusedID, focused != moment.suggestedID {
                useConfirmationCandidate(focused)
            } else {
                acceptSuggestion()
            }
        } else {
            flagFocused(.pick, advance: true)
        }
    }

    /// X: not this one. In Confirm it drops a single-photo moment; it does nothing on multi-frame choices.
    func pressReject() {
        if workspace == .confirm {
            if let moment = currentConfirmation, !moment.isChoice {
                dropSuggestion()
            }
        } else {
            flagFocused(.reject, advance: true)
        }
    }

    func isStepDone(_ step: StudioWorkspace) -> Bool {
        switch step {
        case .confirm: return result != nil && pendingConfirmations.isEmpty
        case .look: return lookIsApplied
        case .deliver: return lastDelivery != nil
        case .album, .adjust: return false
        }
    }

    func toggleSurvey() {
        guard let id = focusedRow?.id, groupsByPhoto[id] != nil else {
            surveying = false
            return
        }
        surveying.toggle()
    }

    func toggleLoupe() {
        guard workspace == .album, result != nil else { return }
        if albumMode == .grid {
            if focusedID == nil { focusedID = visibleRows.first?.id }
            albumMode = .loupe
        } else {
            albumMode = .grid
            surveying = false
        }
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
        performAsOneUndo {
            updateMark(moment.suggestedID) { $0.flag = .pick }
            for id in moment.candidateIDs where id != moment.suggestedID {
                updateMark(id) { $0.flag = .reject }
            }
        }
        status = confirmationStatus
    }

    func useConfirmationCandidate(_ id: PhotoID) {
        guard let moment = currentConfirmation,
              moment.candidateIDs.contains(id) || moment.hiddenRunnerUpIDs.contains(id) else { return }
        if id == moment.suggestedID {
            acceptSuggestion()
            return
        }
        performAsOneUndo {
            updateMark(id) { $0.flag = .pick }
            if let row = row(for: id), row.bucket != .selected, row.bucket != .protected {
                override(photoID: id, bucket: .selected)
            }
            for other in moment.candidateIDs where other != id {
                updateMark(other) { $0.flag = .reject }
                if row(for: other)?.bucket == .selected {
                    override(photoID: other, bucket: .alternate)
                }
            }
        }
        status = confirmationStatus
    }

    func dropSuggestion() {
        guard let moment = currentConfirmation else { return }
        performAsOneUndo {
            updateMark(moment.suggestedID) { $0.flag = .reject }
            override(photoID: moment.suggestedID, bucket: .hidden)
        }
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
        if left == 0 { return "All close calls confirmed." }
        return "\(left) close moment\(left == 1 ? "" : "s") left."
    }

    private func makeConfirmations() -> [ConfirmationMoment] {
        var moments: [ConfirmationMoment] = []
        var covered = Set<PhotoID>()
        let groups = result?.grouping.groups ?? []
        for group in groups where group.kind != .exactDuplicate && group.memberIDs.count > 1 {
            let visible = group.memberIDs.compactMap { id in row(for: id) }.filter { $0.bucket != .hidden }
            guard visible.count >= 2 else { continue }
            let ranked = visible.sorted { $0.score > $1.score }
            guard let best = ranked.first, let second = ranked.dropFirst().first else { continue }
            let margin = best.score - second.score
            guard margin < 0.08 else { continue }
            covered.formUnion(ranked.map(\.id))
            let candidates = Array(ranked.prefix(4).map(\.id))
            let candidateSet = Set(candidates)
            let runnersUp = group.memberIDs.filter { id in
                guard !candidateSet.contains(id), let row = row(for: id) else { return false }
                return !row.reasons.contains(where: PhotoTechnicalReject.isTechnicalRejectReason)
            }
            moments.append(ConfirmationMoment(
                id: group.id.uuidString,
                suggestedID: best.id,
                candidateIDs: candidates,
                reason: best.reasons.first ?? "These frames are close.",
                margin: margin,
                hiddenRunnerUpIDs: runnersUp
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
        let sorted = moments.sorted { $0.margin < $1.margin }
        confirmationsBeyondCap = max(0, sorted.count - 16)
        return Array(sorted.prefix(16))
    }

    func suggestionExplanation(for moment: ConfirmationMoment) -> String {
        guard moment.isChoice, let best = analyzedPhoto(id: moment.suggestedID) else { return moment.reason }
        let others = moment.candidateIDs.filter { $0 != moment.suggestedID }.compactMap { analyzedPhoto(id: $0) }
        guard !others.isEmpty else { return moment.reason }
        func focus(_ photo: AnalyzedPhoto) -> Double { photo.signals.subjectSharpness ?? photo.signals.sharpness }
        func eyesClosed(_ photo: AnalyzedPhoto) -> Bool { photo.signals.qualityFlags.contains(PhotoTechnicalReject.eyesClosed) }
        var edges: [String] = []
        if others.allSatisfy({ focus(best) - focus($0) > 0.05 }) { edges.append("is sharper") }
        if best.signals.faceCount > 0, others.allSatisfy({ best.signals.faceQuality - $0.signals.faceQuality > 0.05 }) {
            edges.append("has better faces")
        }
        if !eyesClosed(best), others.contains(where: eyesClosed) { edges.append("has open eyes") }
        if others.allSatisfy({ best.signals.exposureQuality - $0.signals.exposureQuality > 0.05 }) {
            edges.append("is better exposed")
        }
        guard !edges.isEmpty else { return "These frames are nearly identical. Either is a fine keep." }
        return "Suggested because it " + ListFormatter.localizedString(byJoining: edges) + "."
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

    /// Every mark changed inside `body` is undone by a single Undo.
    func performAsOneUndo(_ body: () -> Void) {
        openUndoGroup = []
        body()
        if let group = openUndoGroup, !group.isEmpty {
            pushUndo(group)
        }
        openUndoGroup = nil
    }

    private func pushUndo(_ group: [PhotoReviewMark]) {
        undoStack.append(group)
        if undoStack.count > 80 { undoStack.removeFirst() }
    }

    func updateMark(_ id: PhotoID, _ mutate: (inout PhotoReviewMark) -> Void) {
        var mark = mark(for: id)
        if openUndoGroup != nil {
            openUndoGroup?.append(mark)
        } else {
            pushUndo([mark])
        }
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
        guard let group = undoStack.popLast() else { return }
        for previous in group.reversed() {
            reviewMarks[previous.photoID] = previous
            do {
                try runner.saveReviewMark(previous)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        focusedID = group.first?.photoID
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

    func openAdjust() {
        guard result != nil else { return }
        if focusedID == nil {
            focusedID = rows.first { $0.bucket == .selected || $0.bucket == .protected }?.id
                ?? visibleRows.first?.id
        }
        syncDevelopRecipe()
        if workspace != .adjust { workspaceBeforeAdjust = workspace }
        workspace = .adjust
        showingOriginal = false
    }

    /// Starts horizon detection for `photo` in the background if auto-straighten needs it.
    func ensureHorizon(for photo: AnalyzedPhoto) {
        guard autoStraightenLook, horizonCache[photo.id] == nil else { return }
        horizonCache[photo.id] = .some(nil)  // mark as in-flight so we only start once
        let url = photo.asset.url
        let orientation = photo.asset.metadata.orientation
        let id = photo.id
        Task.detached(priority: .userInitiated) { [weak self] in
            let degrees = ApplePhotoRenderer.detectHorizonDegrees(url: url, orientation: orientation)
            await self?.storeHorizon(degrees, for: id)
        }
    }

    private func storeHorizon(_ degrees: Double?, for id: PhotoID) {
        horizonCache[id] = .some(degrees)
        if focusedID == id, customRecipes[id] == nil {
            syncDevelopRecipe()
        }
    }

    func syncDevelopRecipe() {
        guard let row = focusedRow, let photo = analyzedPhoto(id: row.id) else { return }
        if let custom = customRecipes[row.id] {
            developRecipe = custom
            return
        }
        ensureHorizon(for: photo)
        developRecipe = baseRecipe(for: photo)
    }

    func setDevelopRecipe(_ recipe: EditRecipe) {
        developRecipe = recipe
        if let id = focusedRow?.id {
            customRecipes[id] = recipe
        }
    }

    func resetDevelopRecipe() {
        guard let id = focusedRow?.id else { return }
        customRecipes[id] = nil
        syncDevelopRecipe()
    }

    func resetDevelopValue(_ keyPath: WritableKeyPath<EditRecipe, Double>) {
        guard let row = focusedRow, let photo = analyzedPhoto(id: row.id) else { return }
        var recipe = developRecipe
        recipe[keyPath: keyPath] = baseRecipe(for: photo)[keyPath: keyPath]
        setDevelopRecipe(recipe)
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

    func deliver() {
        guard result != nil, !isDelivering else { return }
        let exportByID = Dictionary(
            (result?.exports ?? []).map { ($0.photoID, URL(fileURLWithPath: $0.outputPath)) },
            uniquingKeysWith: { first, _ in first }
        )
        let jobs: [DeliveryJob] = deliverRows.enumerated().compactMap { index, row in
            guard let photo = analyzedPhoto(id: row.id) else { return nil }
            let custom = customRecipes[row.id]
            return DeliveryJob(
                photo: photo,
                fileName: String(format: "%03d-%@.jpg", index + 1, row.sourceURL.deletingPathExtension().lastPathComponent),
                mark: sidecarMark(for: row),
                customRecipe: custom,
                reusableExport: (lookIsApplied && custom == nil) ? exportByID[row.id] : nil
            )
        }
        guard !jobs.isEmpty else {
            status = "Nothing in the album to deliver."
            return
        }
        let sidecarJobs: [SidecarJob] = deliverWritesSidecarsBesideOriginals
            ? rows.map { row in
                SidecarJob(
                    mark: sidecarMark(for: row),
                    baseName: row.sourceURL.deletingPathExtension().lastPathComponent,
                    folder: row.sourceURL.deletingLastPathComponent()
                )
            }
            : []
        let entries = rows.map { row in
            let mark = sidecarMark(for: row)
            return PortableCullEntry(
                fileName: row.sourceURL.lastPathComponent,
                relativePath: row.relativePath,
                bucket: row.bucket.rawValue,
                flag: mark.flag.rawValue,
                stars: mark.stars,
                color: mark.color.rawValue,
                reasons: row.reasons
            )
        }
        let destination = newDeliveryFolder()
        let look = effectiveLook
        let spec = ExportSpecification(preset: exportPreset)
        let sourceFolder = selectedFolder
        isDelivering = true
        deliverProgress = (0, jobs.count)
        status = "Exporting \(jobs.count) photos…"

        Task.detached(priority: .userInitiated) { [weak self] in
            let accessed = sourceFolder?.startAccessingSecurityScopedResource() ?? false
            defer { if accessed { sourceFolder?.stopAccessingSecurityScopedResource() } }
            do {
                let fileManager = FileManager.default
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                let renderer = ApplePhotoRenderer()
                for (index, job) in jobs.enumerated() {
                    let output = destination.appendingPathComponent(job.fileName)
                    if let reusable = job.reusableExport, fileManager.fileExists(atPath: reusable.path) {
                        try fileManager.copyItem(at: reusable, to: output)
                    } else {
                        let recipe: EditRecipe
                        if let custom = job.customRecipe {
                            recipe = custom
                        } else {
                            let horizon = look.autoStraighten
                                ? ApplePhotoRenderer.detectHorizonDegrees(url: job.photo.asset.url, orientation: job.photo.asset.metadata.orientation)
                                : nil
                            recipe = look.recipe(for: job.photo, horizonDegrees: horizon)
                        }
                        _ = try renderer.render(photo: job.photo, outputURL: output, recipe: recipe, exportSpecification: spec)
                    }
                    try JPEGRatingStamp.stamp(job.mark, into: output)
                    await self?.noteDeliverProgress(done: index + 1, total: jobs.count)
                }
                var written = 0
                var skipped = 0
                for sidecar in sidecarJobs {
                    switch try LightroomSidecar.writePreservingExisting(sidecar.mark, named: sidecar.baseName, to: sidecar.folder) {
                    case .written: written += 1
                    case .skippedExistingSidecar: skipped += 1
                    }
                }
                try LightroomSidecar.decisionsData(entries)
                    .write(to: destination.appendingPathComponent("photocore-cull.json"), options: .atomic)
                await self?.didDeliver(DeliveryReport(folder: destination, photoCount: jobs.count, sidecarsWritten: written, sidecarsSkipped: skipped))
            } catch {
                await self?.noteDeliverFailure(error)
            }
        }
    }

    /// Always a brand-new folder, so delivery never overwrites or deletes anything.
    private func newDeliveryFolder() -> URL {
        let shoot = selectedFolder?.lastPathComponent ?? "Album"
        let day = Date().formatted(.iso8601.year().month().day())
        let base = "\(shoot) \(day)"
        var candidate = deliverParentFolder.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = deliverParentFolder.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func noteDeliverProgress(done: Int, total: Int) {
        deliverProgress = (done, total)
    }

    private func didDeliver(_ report: DeliveryReport) {
        isDelivering = false
        deliverProgress = nil
        lastDelivery = report
        status = report.sidecarsSkipped == 0
            ? "Delivered \(report.photoCount) photos."
            : "Delivered \(report.photoCount) photos. Left \(report.sidecarsSkipped) existing sidecars untouched."
    }

    private func noteDeliverFailure(_ error: Error) {
        isDelivering = false
        deliverProgress = nil
        errorMessage = error.localizedDescription
        status = "Delivery stopped."
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

struct DeliveryJob: Sendable {
    let photo: AnalyzedPhoto
    let fileName: String
    let mark: PhotoReviewMark
    let customRecipe: EditRecipe?
    let reusableExport: URL?
}

struct SidecarJob: Sendable {
    let mark: PhotoReviewMark
    let baseName: String
    let folder: URL
}

struct DeliveryReport: Equatable {
    let folder: URL
    let photoCount: Int
    let sidecarsWritten: Int
    let sidecarsSkipped: Int
}
