import AppKit
import Foundation
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct PhotoEngineMacApp: App {
    var body: some Scene {
        WindowGroup("Photo Engine") {
            ContentView()
                .frame(minWidth: 920, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
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
    @Published var targetCount: Double = 40 {
        didSet { UserDefaults.standard.set(targetCount, forKey: "PhotoEngine.targetCount") }
    }
    @Published var status = "Choose a folder of photos to begin."
    @Published var isRunning = false
    @Published var result: PipelineResult?
    @Published var errorMessage: String?
    @Published var progress: PipelineProgress?
    @Published var rows: [CuratedRow] = []
    @Published var cleanupPlan: CleanupPlan?
    @Published var cleanupReport: CleanupReport?

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
        if defaults.object(forKey: "PhotoEngine.targetCount") != nil {
            targetCount = min(max(defaults.double(forKey: "PhotoEngine.targetCount"), 5), 150)
        }
    }

    var targetCountInt: Int { max(1, Int(targetCount.rounded())) }

    func process() {
        guard let selectedFolder else { return }
        let mode = mode
        let aggressiveness = aggressiveness
        let style = style
        let styleIntensity = styleIntensity
        let exportSpecification = ExportSpecification(preset: exportPreset)
        let targetCount = targetCountInt
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
                profile.targetCount = targetCount
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
        isRunning = false
        progress = nil
        let warningSuffix = result.warnings.isEmpty ? "" : " \(result.warnings.count) warning(s)."
        let storageSuffix = result.storageSummary.map {
            " Generated \(Self.formatBytes($0.generatedBytes)); cache \(Self.formatBytes($0.cacheBytes))."
        } ?? ""
        status = "Selected \(result.shortlist.selectedIDs.count) of \(result.imported.count) photos." + storageSuffix + warningSuffix
        processingTask = nil
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
            try Self.updateManifest(result.manifestURL, shortlist: updatedShortlist)
            self.result = PipelineResult(
                sessionID: result.sessionID,
                imported: result.imported,
                analyzed: result.analyzed,
                grouping: result.grouping,
                scored: result.scored,
                shortlist: updatedShortlist,
                exports: result.exports,
                manifestURL: result.manifestURL,
                warnings: result.warnings,
                runDirectory: result.runDirectory,
                storageSummary: result.storageSummary,
                metrics: result.metrics,
                exportSpecification: result.exportSpecification
            )
            rows = Self.makeRows(result: self.result!)
            cleanupPlan = nil
            cleanupReport = nil
            status = "Saved your \(bucket.rawValue) override."
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

    private static func updateManifest(_ url: URL, shortlist: Shortlist) throws {
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
            exports: manifest.exports,
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

struct ContentView: View {
    @StateObject private var model = PhotoEngineViewModel()
    @State private var showingFolderPicker = false
    @State private var visibleBucket: SelectionBucket = .selected
    @State private var confirmingCleanup = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 250)
                Divider()
                shortlist
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                model.selectedFolder = urls.first
                model.result = nil
                model.errorMessage = nil
                model.cleanupPlan = nil
                model.cleanupReport = nil
                model.status = "Ready to process \(urls.first?.lastPathComponent ?? "folder")."
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .alert("Move exact duplicates to Trash?", isPresented: $confirmingCleanup) {
            Button("Move to Trash", role: .destructive) { model.executeCleanup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only byte-identical copies with a verified retained occurrence will be moved. Near-duplicate photos are never included.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Photo Engine")
                    .font(.headline)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Choose Folder…") { showingFolderPicker = true }
                .keyboardShortcut("o", modifiers: [.command])
            if model.isRunning {
                Button("Cancel", role: .cancel) { model.cancel() }
            } else {
                Button("Curate Photos") { model.process() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedFolder == nil)
            }
        }
        .padding(18)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            GroupBox("Source") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.selectedFolder?.lastPathComponent ?? "No folder selected", systemImage: "folder")
                        .lineLimit(2)
                    if let folder = model.selectedFolder {
                        Text(folder.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Mode") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(CurationMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()

                    Text("Target shortlist: \(model.targetCountInt)")
                        .font(.caption)
                    Slider(value: $model.targetCount, in: 5...150, step: 1)
                }
                .padding(4)
            }

            GroupBox("Culling") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Aggressiveness", selection: $model.aggressiveness) {
                        ForEach(CullingAggressiveness.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .labelsHidden()
                    Text(cullingDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }

            GroupBox("Look") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Style", selection: $model.style) {
                        ForEach(StylePreset.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .labelsHidden()
                    HStack {
                        Text("Intensity")
                            .font(.caption)
                        Slider(value: $model.styleIntensity, in: 0...1)
                        Text(String(format: "%.0f%%", model.styleIntensity * 100))
                            .font(.caption.monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                .padding(4)
            }

            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Export size", selection: $model.exportPreset) {
                        ForEach(ExportPreset.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .labelsHidden()
                    Text(model.exportPreset == .full
                         ? "Original dimensions, optimized for editing."
                         : "2048px long edge, smaller for sharing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    Text(progress.stage.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

                Spacer(minLength: 8)
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }

    private var shortlist: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Shortlist")
                    .font(.title2.bold())
                Spacer()
                if model.result != nil {
                    Button("Reveal Exports") { model.revealExports() }
                }
            }

            if let result = model.result {
                Text("These are the photos the current profile selected. Source files are unchanged.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !result.warnings.isEmpty {
                    DisclosureGroup("\(result.warnings.count) warning(s)") {
                        ForEach(result.warnings.prefix(10), id: \.path) { warning in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: warning.path).lastPathComponent)
                                    .font(.caption.bold())
                                Text(warning.message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                HStack(spacing: 14) {
                    summaryStat(title: "Selected", value: result.shortlist.decisions.filter { $0.bucket == .selected }.count)
                    summaryStat(title: "Protected", value: result.shortlist.decisions.filter { $0.bucket == .protected }.count)
                    summaryStat(title: "Alternates", value: result.shortlist.decisions.filter { $0.bucket == .alternate }.count)
                    summaryStat(title: "Review", value: result.shortlist.decisions.filter { $0.bucket == .review }.count)
                    summaryStat(title: "Hidden", value: result.shortlist.decisions.filter { $0.bucket == .hidden }.count)
                    Spacer()
                }

                if let summary = result.storageSummary {
                    Text("Source \(formatBytes(summary.sourceBytes)) · generated \(formatBytes(summary.generatedBytes)) · analysis cache \(formatBytes(summary.cacheBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                cleanupSection

                Picker("Bucket", selection: $visibleBucket) {
                    Text("Selected").tag(SelectionBucket.selected)
                    Text("Protected").tag(SelectionBucket.protected)
                    Text("Alternates").tag(SelectionBucket.alternate)
                    Text("Review").tag(SelectionBucket.review)
                    Text("Hidden").tag(SelectionBucket.hidden)
                }
                .pickerStyle(.segmented)

                let visibleRows = model.rows
                    .filter { $0.bucket == visibleBucket }
                    .sorted { ($0.rank ?? .max, -$0.score) < ($1.rank ?? .max, -$1.score) }
                List(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 12) {
                            LocalPhotoThumbnail(url: row.previewURL ?? row.sourceURL)
                            Text(String(format: "%02d", index + 1))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.relativePath)
                                    .lineLimit(1)
                                Text(row.reasons.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.2f", row.score))
                                .font(.caption.monospacedDigit())
                        }
                        .contextMenu {
                            Button("Keep in shortlist") {
                                model.override(photoID: row.id, bucket: .selected)
                            }
                            Button("Protect") {
                                model.override(photoID: row.id, bucket: .protected)
                            }
                            Button("Exclude", role: .destructive) {
                                model.override(photoID: row.id, bucket: .hidden)
                            }
                        }
                        .padding(.vertical, 3)
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    "Nothing curated yet",
                    systemImage: "wand.and.stars",
                    description: Text("Choose a folder, select a mode, and curate the photos.")
                )
            }
        }
        .padding(18)
    }

    private func summaryStat(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cullingDescription: String {
        switch model.aggressiveness {
        case .gentle: "Keeps more useful variations and uncertain moments."
        case .balanced: "Balances quality, coverage, and variety."
        case .highlights: "Builds a compact set with fewer repetitive moments."
        }
    }

    private var cleanupSection: some View {
        GroupBox("Storage") {
            VStack(alignment: .leading, spacing: 7) {
                if let report = model.cleanupReport {
                    Text("Moved \(report.movedPhotoIDs.count) exact duplicate(s) to Trash.")
                        .font(.caption)
                    if !report.skipped.isEmpty {
                        Text("\(report.skipped.count) item(s) were skipped for safety.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let plan = model.cleanupPlan {
                    Text("\(plan.candidates.count) byte-identical copy(s), \(formatBytes(plan.estimatedBytes)) estimated.")
                        .font(.caption)
                    if !plan.warnings.isEmpty {
                        Text("\(plan.warnings.count) safety warning(s) need attention.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Move exact copies to Trash", role: .destructive) {
                        confirmingCleanup = true
                    }
                    .disabled(plan.candidates.isEmpty)
                } else {
                    Text("Sources are never changed automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Review exact-duplicate cleanup") {
                        model.prepareCleanup()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

}

private struct LocalPhotoThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            image = await Task.detached(priority: .utility) {
                guard let data = try? PhotoThumbnailProvider.data(for: url) else { return nil }
                return NSImage(data: data)
            }.value
        }
    }
}
