import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI

enum LoupeZoom: String {
    case fit
    case actual
    case face
}

enum StudioWorkspace: String, CaseIterable, Identifiable {
    case album
    case confirm
    case look
    case adjust

    var id: String { rawValue }

    var title: String {
        switch self {
        case .album: "Album"
        case .confirm: "Confirm"
        case .look: "Look"
        case .adjust: "Adjust"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case picks
    case alternates
    case review
    case closeHidden
    case trash
    case duplicates
    case rejected
    case myPicks
    case starred

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All photos"
        case .picks: "AI picks"
        case .alternates: "Alternates"
        case .review: "Close calls"
        case .closeHidden: "Hidden but close"
        case .trash: "Technical trash"
        case .duplicates: "Similar"
        case .rejected: "Rejected"
        case .myPicks: "My picks"
        case .starred: "Starred"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .picks: "sparkles"
        case .alternates: "rectangle.on.rectangle"
        case .review: "questionmark.circle"
        case .closeHidden: "eye.slash"
        case .trash: "trash"
        case .duplicates: "square.on.square"
        case .rejected: "xmark"
        case .myPicks: "flag.fill"
        case .starred: "star.fill"
        }
    }
}

enum StudioChrome {
    static let canvas = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let panel = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let elevated = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.38)
    static let pick = Color(red: 0.95, green: 0.76, blue: 0.34)
    static let reject = Color(red: 0.89, green: 0.34, blue: 0.31)
}

extension ReviewColor {
    var swatch: Color {
        switch self {
        case .none: Color.white.opacity(0.28)
        case .red: Color(red: 0.86, green: 0.28, blue: 0.27)
        case .yellow: Color(red: 0.93, green: 0.75, blue: 0.22)
        case .green: Color(red: 0.35, green: 0.72, blue: 0.42)
        case .blue: Color(red: 0.32, green: 0.52, blue: 0.90)
        case .purple: Color(red: 0.62, green: 0.42, blue: 0.86)
        }
    }
}

extension SelectionBucket {
    var displayName: String {
        switch self {
        case .selected: "AI pick"
        case .protected: "Protected"
        case .alternate: "Alternate"
        case .review: "Close call"
        case .hidden: "Rejected"
        }
    }
}

struct StudioSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(StudioChrome.tertiary)
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 500
    }

    func image(url: URL, maxPixelSize: Int) async -> NSImage? {
        let key = "\(maxPixelSize)|\(url.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let data = await Task.detached(priority: .utility) { () -> Data? in
            (try? PreviewDiskCache.shared.jpegPreview(for: url, maxPixelSize: maxPixelSize))
                ?? (try? PhotoThumbnailProvider.data(for: url, maxPixelSize: maxPixelSize))
        }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct CachedThumbnail: View {
    let url: URL
    var maxPixelSize: Int = 360

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(maxPixelSize)|\(url.path)") {
            image = await ThumbnailCache.shared.image(url: url, maxPixelSize: maxPixelSize)
        }
    }
}

func studioByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct ZoomableLoupe: View {
    let image: NSImage
    let zoom: LoupeZoom
    var face: CGRectCodable?

    var body: some View {
        GeometryReader { geo in
            let pixels = pixelSize(of: image)
            let fitted = fittedSize(pixels, in: geo.size)
            let scale = displayScale(pixels: pixels, fitted: fitted)
            let shift = pan(fitted: fitted, in: geo.size, scale: scale)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(scale)
                .offset(shift)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
    }

    private func pixelSize(of image: NSImage) -> CGSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    private func fittedSize(_ pixels: CGSize, in view: CGSize) -> CGSize {
        guard pixels.width > 1, pixels.height > 1, view.width > 1, view.height > 1 else { return view }
        let imageAspect = pixels.width / pixels.height
        let viewAspect = view.width / view.height
        if viewAspect > imageAspect {
            return CGSize(width: view.height * imageAspect, height: view.height)
        }
        return CGSize(width: view.width, height: view.width / imageAspect)
    }

    private func displayScale(pixels: CGSize, fitted: CGSize) -> CGFloat {
        switch zoom {
        case .fit:
            return 1
        case .actual:
            let screen = NSScreen.main?.backingScaleFactor ?? 2
            guard fitted.width > 1 else { return 1 }
            return max(1, (pixels.width / fitted.width) / screen)
        case .face:
            let fraction = max(face?.width ?? 0.22, 0.08)
            return min(6, max(1.8, 0.42 / fraction))
        }
    }

    private func pan(fitted: CGSize, in view: CGSize, scale: CGFloat) -> CGSize {
        guard zoom == .face, let face, scale > 1 else { return .zero }
        let imageOrigin = CGPoint(x: (view.width - fitted.width) / 2, y: (view.height - fitted.height) / 2)
        let focus = CGPoint(
            x: (face.x + face.width / 2) * fitted.width,
            y: (1 - (face.y + face.height / 2)) * fitted.height
        )
        let focusInView = CGPoint(x: imageOrigin.x + focus.x, y: imageOrigin.y + focus.y)
        let center = CGPoint(x: view.width / 2, y: view.height / 2)
        let scaled = CGPoint(
            x: center.x + (focusInView.x - center.x) * scale,
            y: center.y + (focusInView.y - center.y) * scale
        )
        return CGSize(width: center.x - scaled.x, height: center.y - scaled.y)
    }
}
