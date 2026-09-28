import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: PhotoEngineViewModel
    @AppStorage("PhotoEngine.sidebarVisible") private var sidebarVisible = true
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                ErrorBanner(message: error) { model.errorMessage = nil }
            }
            HStack(spacing: 0) {
                if sidebarVisible && model.result != nil {
                    sidebar
                        .frame(width: 248)
                    Rectangle().fill(StudioChrome.hairline).frame(width: 1)
                }
                workspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if model.result != nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { sidebarVisible.toggle() }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("Show or hide the sidebar (⌃⌘S)")
                    .keyboardShortcut("s", modifiers: [.command, .control])
                }
            }
            ToolbarItem(placement: .principal) {
                if model.result != nil {
                    StepNavigator(model: model)
                } else {
                    Text("Photocore").font(.headline)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                } else if model.result != nil {
                    Button {
                        model.workspace = .album
                        model.albumMode = .grid
                    } label: {
                        Label("Album", systemImage: "square.grid.2x2")
                    }
                    .help("Browse every photo (⌘4)")
                }
            }
        }
        .toolbarBackground(StudioChrome.panel, for: .windowToolbar)
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !model.isRunning else { return false }
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
        .overlay {
            if isDropTargeted {
                ZStack {
                    StudioChrome.canvas.opacity(0.6)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(StudioChrome.pick, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .padding(12)
                    Label("Drop to open this folder", systemImage: "folder.badge.plus")
                        .font(.title3.weight(.semibold))
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if model.result != nil && !model.isRunning {
                StatusToast(message: model.status)
            }
        }
        .sheet(isPresented: $model.showingShortcuts) { ShortcutsSheet() }
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
                if model.albumMode == .loupe {
                    CullWorkspace(model: model)
                } else {
                    LibraryWorkspace(model: model)
                }
            case .confirm:
                ConfirmWorkspace(model: model)
            case .look:
                LookWorkspace(model: model)
            case .adjust:
                AdjustWorkspace(model: model)
            case .deliver:
                DeliverWorkspace(model: model)
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { model.showingChooser = true } label: {
                    Label(model.selectedFolder?.lastPathComponent ?? "Choose a folder", systemImage: "folder")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                if model.result != nil {
                    filterSection
                }
                DisclosureGroup("Run again with new settings") {
                    CurationSettingsForm(model: model)
                        .padding(.top, 8)
                    Button("Run again") { model.process() }
                        .disabled(model.isRunning || model.selectedFolder == nil)
                }
                .font(.callout)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StudioChrome.panel)
        .scrollIndicators(.hidden)
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                StudioSectionHeader(title: "Library")
                ForEach(LibraryFilter.library) { filterButton($0) }
            }
            VStack(alignment: .leading, spacing: 2) {
                StudioSectionHeader(title: "Your marks")
                ForEach(LibraryFilter.marks) { filterButton($0) }
            }
        }
    }

    private func filterButton(_ filter: LibraryFilter) -> some View {
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
            .padding(.leading, filter.isIndented ? 18 : 0)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(model.filter == filter ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

}

struct CurationSettingsForm: View {
    @ObservedObject var model: PhotoEngineViewModel

    var body: some View {
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
            Text("\(cullDescription) \(model.mode.cullHint)")
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

private struct StepNavigator: View {
    @ObservedObject var model: PhotoEngineViewModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(StudioWorkspace.steps.enumerated()), id: \.element) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(StudioChrome.hairline)
                        .frame(width: 20, height: 1)
                }
                Button {
                    model.workspace = step
                } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(fill(for: step))
                                .frame(width: 18, height: 18)
                            if model.isStepDone(step) && model.workspace != step {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(.black)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(model.workspace == step ? .black : StudioChrome.secondary)
                            }
                        }
                        Text(step.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(model.workspace == step ? StudioChrome.text : StudioChrome.secondary)
                        if step == .confirm, !model.pendingConfirmations.isEmpty {
                            Text("\(model.pendingConfirmations.count)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(StudioChrome.pick.opacity(0.25), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fill(for step: StudioWorkspace) -> Color {
        if model.workspace == step { return StudioChrome.pick }
        if model.isStepDone(step) { return Color.white.opacity(0.75) }
        return Color.white.opacity(0.10)
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: PhotoEngineViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                if let folder = model.selectedFolder {
                    ready(folder)
                } else {
                    intro
                }
                if !model.recentFolders.isEmpty {
                    recent
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .background(StudioChrome.canvas)
    }

    private var intro: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("We cull it.\nYou confirm the close calls.")
                    .font(StudioType.hero)
                    .multilineTextAlignment(.center)
                Text("Drop a folder. Photocore keeps the strong frames, hides the rest, and only asks when two photos are actually close.")
                    .foregroundStyle(StudioChrome.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            HStack(spacing: 18) {
                welcomeStep("1", "Run", "Bursts collapse. Blurry and blank frames drop out.")
                welcomeStep("2", "Confirm", "A short queue of close calls. Return keeps the suggestion.")
                welcomeStep("3", "Deliver", "Finished JPEGs with stars and labels Lightroom reads.")
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
        }
        .padding(.top, 40)
    }

    private func ready(_ folder: URL) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(StudioChrome.pick)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.lastPathComponent)
                        .font(StudioType.display)
                    Text(countLine)
                        .foregroundStyle(model.folderHasNoPhotos ? StudioChrome.reject : StudioChrome.secondary)
                }
            }
            if !model.folderHasNoPhotos {
                CurationSettingsForm(model: model)
                Button {
                    model.process()
                } label: {
                    Text(curateTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioChrome.pick)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isCountingPhotos)
            }
            Button("Choose a different folder…") { model.showingChooser = true }
                .buttonStyle(.link)
        }
        .padding(24)
        .frame(maxWidth: 520)
        .background(StudioChrome.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 40)
    }

    private var countLine: String {
        if model.isCountingPhotos { return "Counting photos…" }
        if model.folderHasNoPhotos { return "No JPEG, HEIC, or RAW photos in this folder." }
        return model.shortlistEstimateText ?? ""
    }

    private var curateTitle: String {
        guard let count = model.sourcePhotoCount, count > 0 else { return "Curate" }
        return "Curate \(count.formatted()) photos"
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            StudioSectionHeader(title: "Recent")
            ForEach(model.recentFolders, id: \.self) { url in
                Button {
                    model.selectFolder(url)
                } label: {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(StudioChrome.secondary)
                        Text(url.lastPathComponent)
                        Spacer()
                        Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption)
                            .foregroundStyle(StudioChrome.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(StudioChrome.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 520)
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
                .font(StudioType.display)
            Text(model.status)
                .foregroundStyle(StudioChrome.secondary)
            if let progress = model.progress, progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .tint(StudioChrome.pick)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            if let progress = model.progress, progress.total > 0 {
                HStack {
                    Text("\(progress.completed.formatted()) of \(progress.total.formatted())")
                        .monospacedDigit()
                    Spacer()
                    if let eta = etaText {
                        Text(eta)
                    }
                }
                .font(.caption)
                .foregroundStyle(StudioChrome.secondary)
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
            Button("Cancel") { model.cancel() }
        }
        .padding(36)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioChrome.canvas)
    }

    private var etaText: String? {
        guard let progress = model.progress, progress.stage == .analyzing,
              progress.completed >= 5, progress.total > progress.completed,
              let started = model.stageStartedAt else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        let remaining = elapsed / Double(progress.completed) * Double(progress.total - progress.completed)
        let text = Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))
        return "About \(text) left"
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

private struct StatusToast: View {
    let message: String
    @State private var visible = false

    var body: some View {
        Group {
            if visible {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(StudioChrome.hairline))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 18)
        .animation(.easeOut(duration: 0.2), value: visible)
        .task(id: message) {
            visible = true
            try? await Task.sleep(for: .seconds(3))
            visible = false
        }
        .allowsHitTesting(false)
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StudioChrome.reject)
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(StudioChrome.reject.opacity(0.14))
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
            key("p") { model.pressPick() }
            key("x") { model.pressReject() }
            key("u") { model.flagFocused(.unflagged, advance: false) }
            key("z") { model.undoMark() }
            key("s") {
                if model.workspace == .album, model.albumMode == .loupe { model.toggleSurvey() }
            }
            key(.space) { model.toggleLoupe() }
            key("g") {
                if model.workspace == .album {
                    model.albumMode = .grid
                    model.surveying = false
                }
            }
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
