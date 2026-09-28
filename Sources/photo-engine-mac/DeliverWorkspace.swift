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
            VStack(alignment: .leading, spacing: 22) {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(StudioChrome.secondary)
                outputCard
                HStack {
                    Spacer()
                    Button("Save \(model.deliverRows.count) photos") { model.deliver() }
                        .buttonStyle(StudioButtonStyle(primary: true))
                        .disabled(model.isDelivering || model.deliverRows.isEmpty)
                }
                if let progress = model.deliverProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        Text("Saving \(progress.done) of \(progress.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(StudioChrome.secondary)
                    }
                }
                if let report = model.lastDelivery, !model.isDelivering {
                    delivered(report)
                }
                Button(showCleanup ? "Hide cleanup" : "Remove exact copies") {
                    showCleanup.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(StudioChrome.tertiary)
                if showCleanup {
                    cleanup
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .buttonStyle(StudioQuietButtonStyle())
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

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioSectionHeader(title: "Save to")
            HStack(alignment: .firstTextBaseline) {
                Text("Folder")
                    .foregroundStyle(StudioChrome.secondary)
                    .frame(width: 60, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.deliverParentFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Finished photos go in a new folder named after this set.")
                        .font(.caption)
                        .foregroundStyle(StudioChrome.tertiary)
                }
                Spacer()
                Button("Change…") { choosingFolder = true }
            }
            HStack {
                Text("Size")
                    .foregroundStyle(StudioChrome.secondary)
                    .frame(width: 60, alignment: .leading)
                Picker("Size", selection: $model.exportPreset) {
                    Text("Full size").tag(ExportPreset.full)
                    Text("For sharing").tag(ExportPreset.compact)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
            }
            Button(showLightroom ? "Hide Lightroom options" : "Lightroom options") {
                showLightroom.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(StudioChrome.tertiary)
            if showLightroom {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved photos include star ratings. Lightroom can read them when you import the folder.")
                        .font(.caption)
                        .foregroundStyle(StudioChrome.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Also write those ratings next to the original files", isOn: $model.deliverWritesSidecarsBesideOriginals)
                        .toggleStyle(.checkbox)
                    Text("Existing files next to the originals are never replaced.")
                        .font(.caption)
                        .foregroundStyle(StudioChrome.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func sizeName(_ preset: ExportPreset) -> String {
        switch preset {
        case .full: "full size"
        case .compact: "for sharing"
        }
    }

    private func delivered(_ report: DeliveryReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .foregroundStyle(StudioChrome.text)
            Text("Saved \(report.photoCount) photos to \(report.folder.lastPathComponent)")
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([report.folder])
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var cleanup: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let report = model.cleanupReport {
                Text("Moved \(report.movedPhotoIDs.count) exact copies to Trash.")
                    .font(.caption)
            } else if let plan = model.cleanupPlan {
                Text("\(plan.candidates.count) exact copies · \(studioByteCount(plan.estimatedBytes))")
                    .font(.caption)
                Button("Move exact copies to Trash", role: .destructive) { confirmingCleanup = true }
                    .disabled(plan.candidates.isEmpty)
            } else {
                Text("Finds identical copies of photos you kept. Nothing moves until you confirm.")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                Button("Find exact copies") { model.prepareCleanup() }
            }
        }
    }
}
