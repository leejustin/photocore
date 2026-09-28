import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: PhotoEngineViewModel
    @AppStorage("PhotoEngine.sidebarVisible") private var sidebarVisible = true
    @State private var isDropTargeted = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                ErrorBanner(message: error) { model.errorMessage = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if showsStudioBar {
                StudioTopBar(model: model)
                Rectangle().fill(StudioChrome.hairline).frame(height: 1)
            }
            HStack(spacing: 0) {
                if sidebarVisible && showsStudioBar {
                    sidebar
                        .frame(width: 196)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(StudioChrome.hairline).frame(width: 1)
                }
                workspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(workspaceIdentity)
                    .transition(.opacity)
            }
        }
        .animation(StudioChrome.ease, value: sidebarVisible)
        .animation(StudioChrome.ease, value: workspaceIdentity)
        .animation(StudioChrome.ease, value: model.errorMessage)
        .background(StudioChrome.canvas)
        .foregroundStyle(StudioChrome.text)
        .tint(StudioChrome.text)
        .preferredColorScheme(.dark)
        .background {
            CullKeyCommands(model: model)
            Button("") {
                withAnimation(StudioChrome.ease) { sidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .opacity(0.01)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            Button("") { model.showingShortcuts = true }
                .keyboardShortcut("?", modifiers: [])
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
                    StudioChrome.photo.opacity(0.72)
                    VStack(spacing: 8) {
                        Text("Open this folder")
                            .font(StudioType.display)
                        Text("Drop to begin")
                            .font(StudioType.ui)
                            .foregroundStyle(StudioChrome.secondary)
                    }
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(StudioChrome.ease, value: isDropTargeted)
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

    private var showsStudioBar: Bool { model.result != nil && !model.isRunning }

    private var workspaceIdentity: String {
        if model.isRunning { return "processing" }
        if model.result == nil { return "welcome" }
        return "\(model.workspace.rawValue)-\(model.albumMode.rawValue)"
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.result != nil {
                    filterSection
                }
                Button(showSettings ? "Hide settings" : "Settings") {
                    withAnimation(StudioChrome.ease) { showSettings.toggle() }
                }
                    .buttonStyle(.plain)
                    .font(StudioType.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                if showSettings {
                    CurationSettingsForm(model: model)
                    Button("Run again") { model.process() }
                        .buttonStyle(StudioButtonStyle(primary: true))
                        .disabled(model.isRunning || model.selectedFolder == nil)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StudioChrome.canvas)
        .scrollIndicators(.hidden)
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                StudioSectionHeader(title: "Library")
                ForEach(LibraryFilter.library) { filterButton($0) }
            }
            VStack(alignment: .leading, spacing: 2) {
                StudioSectionHeader(title: "Yours")
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
                Text(filter.title)
                    .foregroundStyle(model.filter == filter ? StudioChrome.text : StudioChrome.secondary)
                Spacer()
                Text("\(model.count(filter))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(StudioChrome.tertiary)
            }
            .font(.system(size: 13))
            .padding(.leading, filter.isIndented ? 14 : 0)
            .padding(.vertical, 4)
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
            labeledMenu("How picky") {
                Picker("How picky", selection: $model.aggressiveness) {
                    ForEach(CullingAggressiveness.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            Text(cullDescription)
                .font(.caption2)
                .foregroundStyle(StudioChrome.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            labeledMenu("How many") {
                Picker("How many", selection: $model.sizingMode) {
                    Text("A set number").tag(ShortlistSizingMode.count)
                    Text("A percentage").tag(ShortlistSizingMode.percentage)
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
        case .gentle: "Keeps more of the similar shots."
        case .balanced: "One good photo from each moment."
        case .highlights: "A short set. Repeated shots drop out."
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

private struct StudioTopBar: View {
    @ObservedObject var model: PhotoEngineViewModel

    private var steps: [StudioWorkspace] { [.album] + StudioWorkspace.steps }

    var body: some View {
        ZStack {
            HStack(spacing: 22) {
                ForEach(steps) { step in
                    Button {
                        if step == .album { model.albumMode = .grid }
                        model.workspace = step
                    } label: {
                        HStack(spacing: 6) {
                            Text(step.title)
                            if step == .confirm, !model.pendingConfirmations.isEmpty {
                                Text("\(model.pendingConfirmations.count)")
                                    .foregroundStyle(StudioChrome.tertiary)
                                    .monospacedDigit()
                            }
                        }
                        .font(model.workspace == step ? StudioType.uiMedium : StudioType.ui)
                        .foregroundStyle(model.workspace == step ? StudioChrome.text : StudioChrome.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button { model.showingChooser = true } label: {
                    Text(model.selectedFolder?.lastPathComponent ?? "Photocore")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(StudioChrome.secondary)
                .frame(maxWidth: 200, alignment: .leading)
                Spacer()
                trailing
                    .frame(width: 160, alignment: .trailing)
            }
        }
        .padding(.leading, 78)
        .padding(.trailing, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var trailing: some View {
        if model.workspace == .adjust {
            Button("Done") { model.workspace = model.workspaceBeforeAdjust }
                .buttonStyle(StudioQuietButtonStyle())
        } else if model.workspace == .album, model.albumMode == .grid {
            HStack(spacing: 12) {
                Button("−") { model.cellSize = max(120, model.cellSize - 16) }
                    .buttonStyle(.plain)
                Button("+") { model.cellSize = min(260, model.cellSize + 16) }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 14))
            .foregroundStyle(StudioChrome.tertiary)
        }
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: PhotoEngineViewModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                welcomePhoto
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
                    .clipped()
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.82),
                        Color.black.opacity(0.55),
                        Color.black.opacity(0.08)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: min(760, geo.size.width * 0.68))
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.45)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
                .frame(maxHeight: .infinity, alignment: .bottom)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if let folder = model.selectedFolder {
                            ready(folder)
                        } else {
                            intro
                        }
                        if !model.recentFolders.isEmpty {
                            recent
                        }
                    }
                    .padding(44)
                    .frame(maxWidth: 680, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Color.black)
    }

    private var welcomePhoto: some View {
        Group {
            if let url = Bundle.module.url(forResource: "welcome-macro", withExtension: "jpg"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                StudioChrome.canvas
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Photocore")
                .font(StudioType.brand)
                .foregroundStyle(StudioChrome.text)
            VStack(alignment: .leading, spacing: 12) {
                Text("We cull it.\nYou confirm the close calls.")
                    .font(StudioType.hero)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Drop a folder. Blurry and repeated frames leave. You only decide when two shots are actually close.")
                    .font(StudioType.ui)
                    .foregroundStyle(StudioChrome.secondary)
                    .frame(maxWidth: 420)
            }
            VStack(alignment: .leading, spacing: 10) {
                Button("Choose Folder…") { model.showingChooser = true }
                    .buttonStyle(StudioButtonStyle(primary: true))
                    .controlSize(.large)
                Text("or drop a folder anywhere")
                    .font(StudioType.caption)
                    .foregroundStyle(StudioChrome.tertiary)
            }
        }
        .padding(.top, 48)
    }

    private func ready(_ folder: URL) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Photocore")
                .font(StudioType.caption)
                .tracking(1.2)
                .foregroundStyle(StudioChrome.tertiary)
            VStack(alignment: .leading, spacing: 6) {
                Text(folder.lastPathComponent)
                    .font(StudioType.display)
                Text(countLine)
                    .font(StudioType.ui)
                    .foregroundStyle(model.folderHasNoPhotos ? StudioChrome.reject : StudioChrome.secondary)
            }
            if !model.folderHasNoPhotos {
                CurationSettingsForm(model: model)
                Button {
                    model.process()
                } label: {
                    Text(curateTitle)
                        .frame(maxWidth: 280)
                }
                .buttonStyle(StudioButtonStyle(primary: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isCountingPhotos)
            }
            Button("Choose a different folder…") { model.showingChooser = true }
                .buttonStyle(StudioQuietButtonStyle())
        }
        .padding(.top, 48)
        .frame(maxWidth: 480, alignment: .leading)
    }

    private var countLine: String {
        if model.isCountingPhotos { return "Counting photos…" }
        if model.folderHasNoPhotos { return "No photos in this folder." }
        return model.shortlistEstimateText ?? ""
    }

    private var curateTitle: String {
        guard let count = model.sourcePhotoCount, count > 0 else { return "Curate" }
        return "Curate \(count.formatted()) photos"
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioSectionHeader(title: "Recent")
            ForEach(model.recentFolders, id: \.self) { url in
                Button {
                    model.selectFolder(url)
                } label: {
                    HStack(spacing: 10) {
                        Text(url.lastPathComponent)
                            .font(StudioType.ui)
                        Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(StudioType.caption)
                            .foregroundStyle(StudioChrome.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(StudioChrome.secondary)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 480)
        .padding(.top, 12)
    }
}

private struct ProcessingView: View {
    @ObservedObject var model: PhotoEngineViewModel

    private let stages: [(PipelineProgress.Stage, String)] = [
        (.discovering, "Finding photos"),
        (.analyzing, "Checking sharpness and faces"),
        (.grouping, "Grouping similar photos"),
        (.selecting, "Choosing the keepers"),
        (.exporting, "Preparing the album")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Working")
                .font(StudioType.display)
            Text(currentStageTitle)
                .font(StudioType.ui)
                .foregroundStyle(StudioChrome.secondary)
            if let progress = model.progress, progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .tint(StudioChrome.text)
                HStack {
                    Text("\(progress.completed.formatted()) of \(progress.total.formatted())")
                        .font(StudioType.caption.monospacedDigit())
                    Spacer()
                    if let eta = etaText {
                        Text(eta)
                            .font(StudioType.caption)
                    }
                }
                .foregroundStyle(StudioChrome.tertiary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(StudioChrome.text)
            }
            Button("Cancel") { model.cancel() }
                .buttonStyle(StudioQuietButtonStyle())
                .padding(.top, 8)
        }
        .padding(48)
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(StudioChrome.photo)
    }

    private var currentStageTitle: String {
        guard let stage = model.progress?.stage,
              let title = stages.first(where: { $0.0 == stage })?.1 else {
            return model.status
        }
        return title
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

}

private struct StatusToast: View {
    let message: String
    @State private var visible = false

    var body: some View {
        Group {
            if visible {
                Text(message)
                    .font(StudioType.ui)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(StudioChrome.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(StudioChrome.hairline))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 20)
        .animation(StudioChrome.easeSlow, value: visible)
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
