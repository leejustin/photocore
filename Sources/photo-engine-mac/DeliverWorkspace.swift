import AppKit
import PhotoEngineCore
import PhotoEngineWorkflow
import SwiftUI
import UniformTypeIdentifiers

struct DeliverWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel
    @State private var choosingFolder = false
    @State private var confirmingCleanup = false
    @State private var showCleanup = false
    @State private var showLightroom = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save")
                        .font(StudioType.display)
                    Text(summary)
                        .font(StudioType.ui)
                        .foregroundStyle(StudioChrome.secondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    row(label: "Folder") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.deliverParentFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(StudioType.ui)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("Finished photos go in a new folder named after this set.")
                                .font(StudioType.caption)
                                .foregroundStyle(StudioChrome.tertiary)
                        }
                        Spacer(minLength: 12)
                        Button("Change…") { choosingFolder = true }
                            .buttonStyle(StudioQuietButtonStyle())
                    }

                    row(label: "Size") {
                        Picker("Size", selection: $model.exportPreset) {
                            Text("Full size").tag(ExportPreset.full)
                            Text("For sharing").tag(ExportPreset.compact)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                        Spacer()
                    }

                    row(label: "Names") {
                        TextField("Rename pattern", text: $model.renamePattern)
                            .textFieldStyle(.plain)
                            .font(StudioType.caption.monospaced())
                            .foregroundStyle(StudioChrome.secondary)
                        Spacer()
                    }
                    if let sample = model.previewRenames(limit: 2).first {
                        Text("e.g. \(sample)")
                            .font(StudioType.caption)
                            .foregroundStyle(StudioChrome.tertiary)
                            .padding(.leading, 68)
                    }

                    Toggle("Build local proof gallery", isOn: $model.buildProofGallery)
                        .toggleStyle(.checkbox)
                        .font(StudioType.caption)
                    Toggle("Portrait retouch on export", isOn: $model.albumRetouchEnabled)
                        .toggleStyle(.checkbox)
                        .font(StudioType.caption)
                }

                Button("Save \(model.deliverRows.count) photos") { model.deliver() }
                    .buttonStyle(StudioButtonStyle(primary: true))
                    .disabled(model.isDelivering || model.deliverRows.isEmpty)

                if let progress = model.deliverProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            .tint(StudioChrome.text)
                        Text("Saving \(progress.done) of \(progress.total)")
                            .font(StudioType.caption.monospacedDigit())
                            .foregroundStyle(StudioChrome.tertiary)
                    }
                }

                if let report = model.lastDelivery, !model.isDelivering {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Text("Saved \(report.photoCount) to \(report.folder.lastPathComponent)")
                                .font(StudioType.ui)
                            Spacer()
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([report.folder])
                            }
                            .buttonStyle(StudioQuietButtonStyle())
                        }
                        if let gallery = model.lastProofGallery {
                            HStack(spacing: 12) {
                                Text("Proof gallery · \(gallery.photoCount) · sneak peek \(gallery.sneakPeekCount)")
                                    .font(StudioType.caption)
                                    .foregroundStyle(StudioChrome.secondary)
                                Spacer()
                                Button("Open gallery") {
                                    NSWorkspace.shared.open(gallery.indexURL)
                                }
                                .buttonStyle(StudioQuietButtonStyle())
                            }
                        }
                        if model.lastCullReportURL != nil {
                            Button("Cull report") { model.exportCullReport() }
                                .buttonStyle(StudioQuietButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }

                if model.tasteProfile.isReady {
                    Text("Taste memory on · \(model.tasteProfile.sampleCount) marks learned")
                        .font(StudioType.caption)
                        .foregroundStyle(StudioChrome.tertiary)
                }

                StudioHairline()
                Button("Export cull report now") { model.exportCullReport() }
                    .buttonStyle(StudioQuietButtonStyle())
                StudioHairline()

                disclosure("Lightroom", isOpen: $showLightroom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Saved photos include star ratings. Lightroom reads them on import.")
                            .font(StudioType.caption)
                            .foregroundStyle(StudioChrome.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Also write ratings next to the original files", isOn: $model.deliverWritesSidecarsBesideOriginals)
                            .toggleStyle(.checkbox)
                            .font(StudioType.caption)
                        Text("Existing sidecars are never replaced.")
                            .font(StudioType.caption)
                            .foregroundStyle(StudioChrome.tertiary)
                    }
                }

                disclosure("Cleanup", isOpen: $showCleanup) {
                    cleanup
                }
            }
            .padding(40)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(StudioChrome.canvas)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.deliverParentFolder = url
            }
        }
        .alert("Move exact duplicates to Trash?", isPresented: $confirmingCleanup) {
            Button("Move to Trash", role: .destructive) { model.executeCleanup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only identical copies of photos you kept are moved. Similar photos stay where they are.")
        }
    }

    private var summary: String {
        let look = model.selectedLook?.name ?? model.style.displayName
        return "\(model.deliverRows.count) photos · \(look) · \(sizeName(model.exportPreset))"
    }

    private func sizeName(_ preset: ExportPreset) -> String {
        switch preset {
        case .full: "full size"
        case .compact: "for sharing"
        }
    }

    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(StudioType.caption)
                .foregroundStyle(StudioChrome.tertiary)
                .frame(width: 52, alignment: .leading)
            content()
        }
    }

    private func disclosure<Content: View>(_ title: String, isOpen: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(isOpen.wrappedValue ? "Hide \(title.lowercased())" : title) {
                withAnimation(StudioChrome.ease) { isOpen.wrappedValue.toggle() }
            }
            .buttonStyle(.plain)
            .font(StudioType.caption)
            .foregroundStyle(StudioChrome.tertiary)
            if isOpen.wrappedValue {
                content()
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var cleanup: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = model.cleanupReport {
                Text("Moved \(report.movedPhotoIDs.count) exact copies to Trash.")
                    .font(StudioType.caption)
                    .foregroundStyle(StudioChrome.secondary)
            } else if let plan = model.cleanupPlan {
                Text("\(plan.candidates.count) exact copies · \(studioByteCount(plan.estimatedBytes))")
                    .font(StudioType.caption)
                    .foregroundStyle(StudioChrome.secondary)
                Button("Move exact copies to Trash", role: .destructive) { confirmingCleanup = true }
                    .buttonStyle(StudioQuietButtonStyle())
                    .disabled(plan.candidates.isEmpty)
            } else {
                Text("Finds identical copies of photos you kept. Nothing moves until you confirm.")
                    .font(StudioType.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                Button("Find exact copies") { model.prepareCleanup() }
                    .buttonStyle(StudioQuietButtonStyle())
            }
        }
    }
}
