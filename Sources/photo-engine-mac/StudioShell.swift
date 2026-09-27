import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: PhotoEngineViewModel
    @State private var showingExport = false
    @State private var confirmingCleanup = false
    @State private var confirmingSidecars = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(StudioChrome.hairline).frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 248)
                Rectangle().fill(StudioChrome.hairline).frame(width: 1)
                workspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(StudioChrome.canvas)
        .foregroundStyle(StudioChrome.text)
        .preferredColorScheme(.dark)
        .background { CullKeyCommands(model: model) }
        .fileImporter(isPresented: $model.showingChooser, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let folder = urls.first { model.selectFolder(folder) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                guard let url = object else { return }
                let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
                Task { @MainActor in
                    model.selectFolder(folder)
                }
            }
            return true
        }
        .alert("Move exact duplicates to Trash?", isPresented: $confirmingCleanup) {
            Button("Move to Trash", role: .destructive) { model.executeCleanup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only byte-identical copies with a verified retained photo are moved. Near-duplicates stay put.")
        }
        .alert("Write sidecars next to the originals?", isPresented: $confirmingSidecars) {
            Button("Write Sidecars") { model.writeSidecars(besideOriginals: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photocore adds an .xmp file beside each photo. The image files themselves are not modified. Lightroom reads the stars, color labels, and pick keywords.")
        }
        .sheet(isPresented: $showingExport) {
            ExportSheet(model: model, writeBesideOriginals: { confirmingSidecars = true })
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(StudioChrome.pick)
                    .frame(width: 10, height: 10)
                Text("Photocore")
                    .font(.system(size: 17, weight: .semibold))
            }
            workspaceSwitch
            Spacer()
            Text(model.status)
                .font(.caption)
                .foregroundStyle(StudioChrome.secondary)
                .lineLimit(1)
            if model.result != nil {
                Button("Hand off") { showingExport = true }
            }
            if model.isRunning {
                Button("Cancel", role: .cancel) { model.cancel() }
            } else {
                Button("Curate") { model.process() }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioChrome.pick)
                    .disabled(model.selectedFolder == nil)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(StudioChrome.panel)
    }

    private var workspaceSwitch: some View {
        HStack(spacing: 2) {
            ForEach(StudioWorkspace.allCases) { workspace in
                Button {
                    model.workspace = workspace
                } label: {
                    Text(workspace.title)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(model.workspace == workspace ? Color.white.opacity(0.12) : Color.clear, in: Capsule())
                        .foregroundStyle(model.workspace == workspace ? StudioChrome.text : StudioChrome.secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.result == nil)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.04), in: Capsule())
    }

    @ViewBuilder
    private var workspace: some View {
        if model.isRunning {
            ProcessingView(model: model)
        } else if model.result == nil {
            WelcomeView(model: model)
        } else {
            switch model.workspace {
            case .album:
                LibraryWorkspace(model: model)
            case .confirm:
                ConfirmWorkspace(model: model)
            case .look:
                LookWorkspace(model: model)
            case .adjust:
                AdjustWorkspace(model: model)
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceSection
                if model.result != nil {
                    filterSection
                }
                if model.result == nil {
                    settingsSection
                } else {
                    DisclosureGroup("Adjust and run again") {
                        settingsSection
                            .padding(.top, 8)
                    }
                    .font(.callout)
                    cleanupSection
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(StudioChrome.reject)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StudioChrome.panel)
        .scrollIndicators(.hidden)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioSectionHeader(title: "Shoot")
            Button { model.showingChooser = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text(model.selectedFolder?.lastPathComponent ?? "Choose a folder")
                        .lineLimit(1)
                    Spacer()
                }
                .padding(8)
                .background(StudioChrome.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            if model.isCountingPhotos {
                Text("Counting photos…")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.secondary)
            } else if let estimate = model.shortlistEstimateText {
                Text(estimate)
                    .font(.caption)
                    .foregroundStyle(StudioChrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            StudioSectionHeader(title: "Library")
            ForEach(LibraryFilter.allCases) { filter in
                Button {
                    model.filter = filter
                    model.focusedID = model.visibleRows.first?.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: filter.symbol)
                            .frame(width: 16)
                            .foregroundStyle(model.filter == filter ? StudioChrome.pick : StudioChrome.secondary)
                        Text(filter.title)
                        Spacer()
                        Text("\(model.count(filter))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(StudioChrome.tertiary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(model.filter == filter ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledMenu("Occasion") {
                Picker("Occasion", selection: $model.mode) {
                    ForEach(CurationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            labeledMenu("Cull") {
                Picker("Cull", selection: $model.aggressiveness) {
                    ForEach(CullingAggressiveness.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            Text(cullDescription)
                .font(.caption2)
                .foregroundStyle(StudioChrome.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.mode.cullHint)
                .font(.caption2)
                .foregroundStyle(StudioChrome.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            labeledMenu("Size") {
                Picker("Size", selection: $model.sizingMode) {
                    ForEach(ShortlistSizingMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            switch model.sizingMode {
            case .count:
                captionSlider("Keep \(model.targetCountInt)", value: $model.targetCount, range: 5...150, step: 1)
            case .percentage:
                captionSlider("Keep \(model.keepPercentageInt)%", value: $model.keepPercentage, range: 5...90, step: 1)
            }
            labeledMenu("Look") {
                Picker("Look", selection: $model.style) {
                    ForEach(StylePreset.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            Text("One look for the whole album.")
                .font(.caption2)
                .foregroundStyle(StudioChrome.tertiary)
            labeledMenu("Export") {
                Picker("Export", selection: $model.exportPreset) {
                    ForEach(ExportPreset.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }
    }

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioSectionHeader(title: "Duplicates")
            if let report = model.cleanupReport {
                Text("Moved \(report.movedPhotoIDs.count) exact copies to Trash.")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.secondary)
            } else if let plan = model.cleanupPlan {
                Text("\(plan.candidates.count) exact copies · \(studioByteCount(plan.estimatedBytes))")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.secondary)
                Button("Move exact copies to Trash", role: .destructive) { confirmingCleanup = true }
                    .disabled(plan.candidates.isEmpty)
            } else {
                Text("Sources stay where they are until you ask.")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                Button("Review exact copies") { model.prepareCleanup() }
            }
        }
    }

    private var cullDescription: String {
        switch model.aggressiveness {
        case .gentle: "Keeps more variations and uncertain moments."
        case .balanced: "One strong frame per moment, with coverage."
        case .highlights: "A short album. Repetitive frames drop out."
        }
    }

    private func labeledMenu<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(StudioChrome.secondary)
            content()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func captionSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.monospacedDigit())
                .foregroundStyle(StudioChrome.secondary)
            Slider(value: value, in: range, step: step)
        }
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: PhotoEngineViewModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 10) {
                Text("We cull it.\nYou confirm the close calls.")
                    .font(.system(size: 40, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                Text("Drop a folder. Photocore keeps the strong frames, hides the rest, and only asks when two photos are actually close.")
                    .font(.body)
                    .foregroundStyle(StudioChrome.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            HStack(spacing: 18) {
                welcomeStep("1", "Run", "Bursts collapse. A look is applied to every keeper.")
                welcomeStep("2", "Confirm", "A short queue of close calls. Return keeps the suggestion.")
                welcomeStep("3", "Hand off", "Finished JPEGs, plus stars and flags Lightroom can read.")
            }
            VStack(spacing: 8) {
                Button("Choose Folder…") { model.showingChooser = true }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioChrome.pick)
                    .controlSize(.large)
                Text("or drop a folder anywhere in this window")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioChrome.canvas)
    }

    private func welcomeStep(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(StudioChrome.pick)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(StudioChrome.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 180, alignment: .leading)
        .padding(14)
        .background(StudioChrome.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ProcessingView: View {
    @ObservedObject var model: PhotoEngineViewModel

    private let stages: [(PipelineProgress.Stage, String)] = [
        (.discovering, "Finding photos"),
        (.analyzing, "Reading focus, faces, and light"),
        (.grouping, "Grouping bursts and duplicates"),
        (.selecting, "Choosing the keepers"),
        (.exporting, "Rendering the album")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Working through the shoot")
                .font(.system(size: 28, weight: .semibold, design: .serif))
            Text(model.status)
                .foregroundStyle(StudioChrome.secondary)
            if let progress = model.progress, progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .tint(StudioChrome.pick)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: index))
                            .foregroundStyle(isCurrent(index) ? StudioChrome.pick : StudioChrome.tertiary)
                            .frame(width: 16)
                        Text(stage.1)
                            .foregroundStyle(isCurrent(index) || isPast(index) ? StudioChrome.text : StudioChrome.tertiary)
                    }
                    .font(.callout)
                }
            }
            Spacer()
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(StudioChrome.canvas)
    }

    private var currentIndex: Int {
        guard let stage = model.progress?.stage else { return 0 }
        return stages.firstIndex { $0.0 == stage } ?? 0
    }

    private func isCurrent(_ index: Int) -> Bool { index == currentIndex }
    private func isPast(_ index: Int) -> Bool { index < currentIndex }

    private func symbol(for index: Int) -> String {
        if isPast(index) { return "checkmark" }
        if isCurrent(index) { return "circle.fill" }
        return "circle"
    }
}

private struct ExportSheet: View {
    @ObservedObject var model: PhotoEngineViewModel
    var writeBesideOriginals: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hand this shoot off")
                .font(.title2.weight(.semibold))
            Text("\(model.count(.picks)) AI picks · \(model.count(.myPicks)) of your picks · \(model.count(.trash)) trash · \(model.count(.rejected)) rejected. Stars, colors, and flags are written as XMP. Image pixels stay untouched.")
                .foregroundStyle(StudioChrome.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Button("Pack keepers for Lightroom") {
                    model.prepareHandoffPackage()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioChrome.pick)
                Button("Save sidecars in the export folder") {
                    model.writeSidecars(besideOriginals: false)
                    dismiss()
                }
                Button("Save sidecars next to the originals…") {
                    dismiss()
                    writeBesideOriginals()
                }
                Button("Reveal rendered JPEGs") { model.revealExports() }
            }
            Text("Pack keepers writes finished JPEGs and XMP into handoff/01-keepers. Lightroom reads Rating and Label from the sidecar. Pick and reject become Photocore Pick / Photocore Reject keywords.")
                .font(.caption)
                .foregroundStyle(StudioChrome.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(StudioChrome.panel)
    }
}

private struct CullKeyCommands: View {
    @ObservedObject var model: PhotoEngineViewModel

    var body: some View {
        Group {
            key(.leftArrow) {
                if model.workspace == .confirm { model.focusConfirmation(offset: -1) }
                else if model.surveying { model.focusSibling(offset: -1) }
                else { model.focusPrevious() }
            }
            key(.rightArrow) {
                if model.workspace == .confirm { model.focusConfirmation(offset: 1) }
                else if model.surveying { model.focusSibling(offset: 1) }
                else { model.focusNext() }
            }
            key(.upArrow) { model.focusSibling(offset: -1) }
            key(.downArrow) { model.focusSibling(offset: 1) }
            key("p") {
                if model.workspace == .confirm {
                    if let moment = model.currentConfirmation, let focused = model.focusedID, focused != moment.suggestedID {
                        model.useConfirmationCandidate(focused)
                    } else {
                        model.acceptSuggestion()
                    }
                } else {
                    model.flagFocused(.pick, advance: true)
                }
            }
            key("x") {
                if model.workspace == .confirm { model.skipConfirmation() }
                else { model.flagFocused(.reject, advance: true) }
            }
            key("u") { model.flagFocused(.unflagged, advance: false) }
            key("z") { model.undoMark() }
            key("c") { model.workspace = .confirm }
            key("l") { model.workspace = .look }
            key("d") { model.openAdjust() }
            key("s") { model.toggleSurvey() }
            key("f") { model.cycleLoupeZoom() }
            key("e") { model.zoomToEyes() }
            key("0") { model.setStars(0) }
            key("1") { model.setStars(1) }
            key("2") { model.setStars(2) }
            key("3") { model.setStars(3) }
            key("4") { model.setStars(4) }
            key("5") { model.setStars(5) }
            key("6") { model.setColor(.red) }
            key("7") { model.setColor(.yellow) }
            key("8") { model.setColor(.green) }
            key("9") { model.setColor(.blue) }
            key(KeyEquivalent("\\")) { model.showingOriginal.toggle() }
        }
        .opacity(0.01)
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .disabled(model.result == nil || model.isRunning)
    }

    private func key(_ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: [])
    }
}
