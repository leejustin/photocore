import AppKit
import Foundation
import PhotoEngineApple
import PhotoEngineCore
import PhotoEngineWorkflow
import SwiftUI
import UniformTypeIdentifiers

@main
struct PhotoEngineMacApp: App {
    @StateObject private var model = PhotoEngineViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 720)
                .navigationTitle(model.windowTitle)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
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
                Button("Check") { model.workspace = .confirm }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(model.result == nil)
                Button("Style") { model.workspace = .look }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(model.result == nil)
                Button("Save") { model.workspace = .deliver }
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
    @Published var renderBase: RenderBase = .raw {
        didSet {
            UserDefaults.standard.set(renderBase.rawValue, forKey: "PhotoEngine.renderBase")
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
        if let raw = defaults.string(forKey: "PhotoEngine.renderBase"), let value = RenderBase(rawValue: raw) {
            renderBase = value
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

    var windowTitle: String {
        if let name = selectedFolder?.lastPathComponent, !name.isEmpty {
            return "Photocore — \(name)"
        }
        return "Photocore"
    }

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
        let renderBase = renderBase
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
                profile.renderBase = renderBase
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
        rows = CuratedRow.rows(for: result)
        groupsByPhoto = PhotoGroupIndex.build(result.grouping)
        if let stored = try? runner.reviewMarks(for: result.analyzed.map(\.id)) {
            reviewMarks = Dictionary(stored.map { ($0.photoID, $0) }, uniquingKeysWith: { _, latest in latest })
        }
        if let stored = try? runner.customRecipes(sessionID: result.sessionID) {
            customRecipes = stored
        }
        filter = count(.album) > 0 ? .album : .all
        let built = ConfirmationBuilder.build(result: result, rows: rows, groups: groupsByPhoto)
        confirmationsBeyondCap = built.beyondCap
        confirmations = built.moments
        skippedConfirmationIDs = []
        seedInCameraRatings()
        focusedID = confirmations.first?.suggestedID ?? visibleRows.first?.id
        workspace = confirmations.isEmpty ? .look : .confirm
        isRunning = false
        progress = nil
        let summary = albumSummary
        if confirmations.isEmpty {
            status = "\(summary.kept) photos kept. Choose a style when you're ready."
        } else {
            status = "\(summary.kept) photos kept. \(confirmations.count) close call\(confirmations.count == 1 ? "" : "s") to check."
        }
        processingTask = nil
        lookIsApplied = false
        lastDelivery = nil
        if let selectedFolder { rememberRecentFolder(selectedFolder) }
    }

    var albumSummary: AlbumSummary {
        AlbumSummary.make(rows: rows, marks: reviewMarks, pendingConfirmations: pendingConfirmations.count)
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
            try ManifestStore.update(result.manifestURL, shortlist: updatedShortlist, exports: exports)
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
            rows = CuratedRow.rows(for: self.result!)
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
        let horizon: Double? = autoStraightenLook ? (horizonCache[photo.id] ?? nil) : nil
        return LookComposer.recipe(for: photo, look: look, settings: currentLookSettings(lookID: look.id), horizon: horizon)
    }

    var effectiveLook: AlbumLook {
        let look = selectedLook ?? AlbumLook.builtins[0]
        return LookComposer.effective(look: look, settings: currentLookSettings(lookID: look.id))
    }

    private func currentLookSettings(lookID: String) -> LookSettings {
        LookSettings(lookID: lookID, temperature: lookTemperature, autoStraighten: autoStraightenLook, renderBase: renderBase)
    }

    /// The album-look recipe for a photo before any per-photo Adjust edits.
    func baseRecipe(for photo: AnalyzedPhoto) -> EditRecipe {
        recipe(for: photo, look: selectedLook ?? AlbumLook.builtins[0])
    }

    /// In the album unless the user rejected it: AI keepers, protected photos, and the user's own picks.
    func isInAlbum(_ row: CuratedRow) -> Bool {
        AlbumMembership.contains(row, mark: mark(for: row.id))
    }

    var deliverRows: [CuratedRow] {
        rows.filter(isInAlbum).sorted { lhs, rhs in
            let left = analyzedPhoto(id: lhs.id)?.asset.metadata.captureDate ?? .distantFuture
            let right = analyzedPhoto(id: rhs.id)?.asset.metadata.captureDate ?? .distantFuture
            return left == right ? (lhs.rank ?? .max) < (rhs.rank ?? .max) : left < right
        }
    }

    var lookSamplePhotos: [AnalyzedPhoto] {
        rows.filter(isInAlbum)
            .sorted { ($0.rank ?? .max, -$0.score) < ($1.rank ?? .max, -$1.score) }
            .prefix(9)
            .compactMap { analyzedPhoto(id: $0.id) }
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
        rows = CuratedRow.rows(for: self.result!)
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
        applyConfirmation(ConfirmationBuilder.resolution(for: moment, action: .accept, rows: rows))
    }

    func useConfirmationCandidate(_ id: PhotoID) {
        guard let moment = currentConfirmation else { return }
        applyConfirmation(ConfirmationBuilder.resolution(for: moment, action: .use(id), rows: rows))
    }

    func dropSuggestion() {
        guard let moment = currentConfirmation else { return }
        applyConfirmation(ConfirmationBuilder.resolution(for: moment, action: .drop, rows: rows))
    }

    private func applyConfirmation(_ resolution: (marks: [MarkChange], overrides: [BucketOverride])) {
        guard !resolution.marks.isEmpty || !resolution.overrides.isEmpty else { return }
        performAsOneUndo {
            for change in resolution.marks {
                updateMark(change.photoID) { $0.flag = change.flag }
            }
            for change in resolution.overrides {
                override(photoID: change.photoID, bucket: change.bucket)
            }
        }
        status = confirmationStatus
    }

    func skipConfirmation() {
        guard let moment = currentConfirmation else { return }
        skippedConfirmationIDs.insert(moment.id)
        status = confirmationStatus
    }

    /// Accepts the suggested frame in every remaining duplicate set. Single-photo questions stay in the queue.
    func acceptRemainingChoices() {
        let moments = pendingConfirmations.filter(\.isChoice)
        guard !moments.isEmpty else { return }
        performAsOneUndo {
            for moment in moments {
                let resolution = ConfirmationBuilder.resolution(for: moment, action: .accept, rows: rows)
                for change in resolution.marks {
                    updateMark(change.photoID) { $0.flag = change.flag }
                }
            }
        }
        let left = pendingConfirmations.count
        if left == 0 {
            status = moments.count == 1
                ? "Kept the suggested frame."
                : "Kept the suggested frame in \(moments.count) duplicate sets."
        } else {
            status = "Kept the suggested duplicates. \(left) still need a look."
        }
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
        if left == 0 { return "All the close calls are settled." }
        return "\(left) close moment\(left == 1 ? "" : "s") left."
    }

    func suggestionExplanation(for moment: ConfirmationMoment) -> String {
        ConfirmationBuilder.explanation(for: moment, analyzed: result?.analyzed ?? [])
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
        guard let id = focusedRow?.id else { return }
        customRecipes[id] = recipe
        guard let sessionID = result?.sessionID else { return }
        do {
            try runner.saveCustomRecipe(recipe, photoID: id, sessionID: sessionID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetDevelopRecipe() {
        guard let id = focusedRow?.id else { return }
        customRecipes[id] = nil
        if let sessionID = result?.sessionID {
            do {
                try runner.deleteCustomRecipe(photoID: id, sessionID: sessionID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        syncDevelopRecipe()
    }

    func resetDevelopValue(_ keyPath: WritableKeyPath<EditRecipe, Double>) {
        guard let row = focusedRow, let photo = analyzedPhoto(id: row.id) else { return }
        var recipe = developRecipe
        recipe[keyPath: keyPath] = baseRecipe(for: photo)[keyPath: keyPath]
        setDevelopRecipe(recipe)
    }

    func renderFocusedEdit() {
        guard result != nil, let row = focusedRow, let photo = analyzedPhoto(id: row.id) else { return }
        let recipe = developRecipe
        let base = row.sourceURL.deletingPathExtension().lastPathComponent
        let shoot = selectedFolder?.lastPathComponent ?? "Photocore"
        let output = deliverParentFolder
            .appendingPathComponent("\(shoot) edits", isDirectory: true)
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
                let report = try DeliveryExecutor.run(
                    jobs: jobs,
                    sidecars: sidecarJobs,
                    entries: entries,
                    destination: destination,
                    look: look,
                    specification: spec
                ) { done, total in
                    Task { @MainActor in self?.noteDeliverProgress(done: done, total: total) }
                }
                await self?.didDeliver(report)
            } catch {
                await self?.noteDeliverFailure(error)
            }
        }
    }

    /// Always a brand-new folder, so delivery never overwrites or deletes anything.
    private func newDeliveryFolder() -> URL {
        DeliveryExecutor.newFolder(parent: deliverParentFolder, shootName: selectedFolder?.lastPathComponent ?? "Album")
    }

    private func noteDeliverProgress(done: Int, total: Int) {
        deliverProgress = (done, total)
    }

    private func didDeliver(_ report: DeliveryReport) {
        isDelivering = false
        deliverProgress = nil
        lastDelivery = report
        status = report.sidecarsSkipped == 0
            ? "Saved \(report.photoCount) photos."
            : "Saved \(report.photoCount) photos. Left \(report.sidecarsSkipped) existing files untouched."
    }

    private func noteDeliverFailure(_ error: Error) {
        isDelivering = false
        deliverProgress = nil
        errorMessage = error.localizedDescription
        status = "Saving stopped."
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

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

