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

    private let runner = PhotoPipelineRunner()

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
        errorMessage = nil
        status = "Processing (selectedFolder.lastPathComponent)…"

        let runner = runner
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var profile = ScoringProfile.default(for: mode)
                profile.targetCount = targetCount
                let result = try runner.run(folder: selectedFolder, outputDirectory: outputURL, profile: profile)
                await self?.finish(result: result, outputURL: outputURL)
            } catch {
                await self?.fail(error)
            }
        }
    }

    func finish(result: PipelineResult, outputURL: URL) {
        self.result = result
        isRunning = false
        status = "Selected (result.shortlist.selectedIDs.count) of (result.imported.count) photos."
    }

    func fail(_ error: Error) {
        isRunning = false
        errorMessage = error.localizedDescription
        status = "Processing failed."
    }

    func revealExports() {
        guard let result else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.manifestURL])
    }
}

struct ContentView: View {
    @StateObject private var model = PhotoEngineViewModel()
    @State private var showingFolderPicker = false

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
            Button(model.isRunning ? "Processing…" : "Curate Photos") { model.process() }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedFolder == nil || model.isRunning)
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

                List(Array(result.shortlist.selectedIDs.enumerated()), id: \.element) { index, photoID in
                    if let analyzed = result.analyzed.first(where: { $0.id == photoID }),
                       let score = result.scored.first(where: { $0.id == photoID }) {
                        HStack(spacing: 12) {
                            Text(String(format: "%02d", index + 1))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(analyzed.asset.relativePath)
                                    .lineLimit(1)
                                Text(score.score.reasons.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.2f", score.score.total))
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.vertical, 3)
                    }
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
}

