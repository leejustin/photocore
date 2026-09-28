import AppKit
import PhotoEngineCore
import PhotoEngineWorkflow
import SwiftUI
import UniformTypeIdentifiers

struct DeliverWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel
    @State private var choosingFolder = false
    @State private var confirmingCleanup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deliver")
                        .font(StudioType.display)
                    Text(summary)
                        .foregroundStyle(StudioChrome.secondary)
                }
                outputCard
                HStack {
                    Spacer()
                    Button("Export \(model.deliverRows.count) photos") { model.deliver() }
                        .buttonStyle(.borderedProminent)
                        .tint(StudioChrome.pick)
                        .controlSize(.large)
                        .disabled(model.isDelivering || model.deliverRows.isEmpty)
                }
                if let progress = model.deliverProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            .tint(StudioChrome.pick)
                        Text("Exporting \(progress.done) of \(progress.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(StudioChrome.secondary)
                    }
                }
                if let report = model.lastDelivery, !model.isDelivering {
                    delivered(report)
                }
                DisclosureGroup("Tidy up the source folder") {
                    cleanup
                        .padding(.top, 8)
                }
                .foregroundStyle(StudioChrome.secondary)
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
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
            Text("Only byte-identical copies with a verified retained photo are moved. Near-duplicates stay put.")
        }
    }

    private var summary: String {
        let look = model.selectedLook?.name ?? model.style.displayName
        return "\(model.deliverRows.count) photos · Look: \(look) · \(model.exportPreset.displayName)"
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioSectionHeader(title: "Output")
            HStack(alignment: .firstTextBaseline) {
                Text("Folder")
                    .foregroundStyle(StudioChrome.secondary)
                    .frame(width: 60, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.deliverParentFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("A new folder named after the shoot is created each time.")
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
                    ForEach(ExportPreset.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Also write Lightroom sidecars beside the originals", isOn: $model.deliverWritesSidecarsBesideOriginals)
                    .toggleStyle(.checkbox)
                Text("Stars, labels, and pick keywords as .xmp next to each RAW/HEIC. Existing .xmp files are never replaced.")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                    .padding(.leading, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Stars and color labels are embedded in each exported JPEG. Lightroom reads them on import.")
                .font(.caption)
                .foregroundStyle(StudioChrome.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(StudioChrome.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func delivered(_ report: DeliveryReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(StudioChrome.pick)
            Text("Exported \(report.photoCount) photos to \(report.folder.lastPathComponent)")
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([report.folder])
            }
        }
        .padding(12)
        .background(StudioChrome.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                Text("Finds byte-identical copies of photos you kept. Nothing moves until you confirm.")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                Button("Find exact copies") { model.prepareCleanup() }
            }
        }
    }
}
