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
    @Published var mode: CurationMode = .everyday
    @Published var targetCount: Double = 40
    @Published var status = "Choose a folder of photos to begin."
    @Published var isRunning = false
    @Published var result: PipelineResult?
    @Published var errorMessage: String?
    @Published var progress: PipelineProgress?
    @Published var rows: [CuratedRow] = []

    private let runner = PhotoPipelineRunner()
    private var processingTask: Task<Void, Never>?

    var targetCountInt: Int { max(1, Int(targetCount.rounded())) }

    func process() {
        guard let selectedFolder else { return }
        let mode = mode
        let targetCount = targetCountInt
        let outputURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("PhotoEngine Exports", isDirectory: true)
            .appendingPathComponent(selectedFolder.lastPathComponent + "-curated", isDirectory: true)

        isRunning = true
        result = nil
        rows = []
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
                profile.targetCount = targetCount
                let result = try runner.run(
                    folder: selectedFolder,
                    outputDirectory: outputURL,
                    profile: profile,
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
        let warningSuffix = result.warnings.isEmpty ? "" : " \(result.warnings.count) file(s) could not be read."
        status = "Selected \(result.shortlist.selectedIDs.count) of \(result.imported.count) photos." + warningSuffix
        processingTask = nil
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
        return result.shortlist.decisions.compactMap { decision in
            guard let analyzed = analyzedByID[decision.photoID] else { return nil }
            return CuratedRow(
                id: decision.photoID,
                bucket: decision.bucket,
                rank: decision.rank,
                relativePath: analyzed.asset.relativePath,
                reasons: scoreByID[decision.photoID]?.reasons ?? decision.reasons,
                score: decision.score,
                sourceURL: analyzed.asset.url
            )
        }
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
}

struct ContentView: View {
    @StateObject private var model = PhotoEngineViewModel()
    @State private var showingFolderPicker = false
    @State private var visibleBucket: SelectionBucket = .selected

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
                model.status = "Ready to process \(urls.first?.lastPathComponent ?? "folder")."
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
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

            Spacer()
        }
        .padding(16)
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
                    DisclosureGroup("\(result.warnings.count) file(s) could not be imported") {
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
                    summaryStat(title: "Alternates", value: result.shortlist.decisions.filter { $0.bucket == .alternate }.count)
                    summaryStat(title: "Review", value: result.shortlist.decisions.filter { $0.bucket == .review }.count)
                    summaryStat(title: "Hidden", value: result.shortlist.decisions.filter { $0.bucket == .hidden }.count)
                    Spacer()
                }

                Picker("Bucket", selection: $visibleBucket) {
                    Text("Selected").tag(SelectionBucket.selected)
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
                            LocalPhotoThumbnail(url: row.sourceURL)
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
