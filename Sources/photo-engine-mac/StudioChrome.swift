import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI

enum LoupeZoom: String {
    case fit
    case actual
    case face
}

enum AlbumMode: String {
    case grid
    case loupe
}

enum StudioWorkspace: String, CaseIterable, Identifiable {
    case album
    case confirm
    case look
    case adjust
    case deliver

    var id: String { rawValue }

    static let steps: [StudioWorkspace] = [.confirm, .look, .deliver]

    var title: String {
        switch self {
        case .album: "Album"
        case .confirm: "Check"
        case .look: "Style"
        case .adjust: "Adjust"
        case .deliver: "Save"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case album
    case alternates
    case needsLook
    case hidden
    case unusable
    case all
    case picked
    case starred

    static let library: [LibraryFilter] = [.album, .alternates, .needsLook, .hidden, .unusable, .all]
    static let marks: [LibraryFilter] = [.picked, .starred]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .album: "Album"
        case .alternates: "Similar shots"
        case .needsLook: "Not sure"
        case .hidden: "Hidden"
        case .unusable: "Blurry or blank"
        case .all: "All photos"
        case .picked: "Favorites"
        case .starred: "Starred"
        }
    }

    var symbol: String {
        switch self {
        case .album: "photo.stack"
        case .alternates: "rectangle.on.rectangle"
        case .needsLook: "questionmark.circle"
        case .hidden: "eye.slash"
        case .unusable: "exclamationmark.triangle"
        case .all: "square.grid.2x2"
        case .picked: "flag.fill"
        case .starred: "star.fill"
        }
    }

    var isIndented: Bool { self == .unusable }
}

enum StudioChrome {
    /// True black behind photographs. Chrome sits slightly above.
    static let photo = Color.black
    static let canvas = Color(red: 0.06, green: 0.06, blue: 0.058)
    static let panel = Color(red: 0.10, green: 0.10, blue: 0.095)
    static let elevated = Color.white.opacity(0.04)
    static let hairline = Color.white.opacity(0.08)
    static let text = Color(red: 0.94, green: 0.94, blue: 0.93)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    /// Reserved for pick stars/flags. Primary CTAs use `text` on black.
    static let pick = Color(red: 0.82, green: 0.70, blue: 0.42)
    static let reject = Color(red: 0.78, green: 0.36, blue: 0.32)
    static let focus = Color.white.opacity(0.92)
    static let ease = Animation.easeOut(duration: 0.15)
    static let easeSlow = Animation.easeOut(duration: 0.22)
}

enum StudioType {
    /// Brand / welcome moments only.
    static let brand = Font.system(size: 54, weight: .semibold, design: .serif)
    static let hero = Font.system(size: 36, weight: .semibold, design: .serif)
    static let display = Font.system(size: 26, weight: .semibold, design: .serif)
    static let title = Font.system(size: 18, weight: .semibold, design: .serif)
    /// Quiet UI chrome.
    static let ui = Font.system(size: 13)
    static let uiMedium = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 11)
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
        case .selected: "In album"
        case .protected: "Protected"
        case .alternate: "Alternate"
        case .review: "Needs a look"
        case .hidden: "Hidden"
        }
    }
}

struct StudioSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(StudioChrome.tertiary)
    }
}

/// Flat paper button. System bordered styles read as a settings panel.
struct StudioButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        StudioButtonLabel(configuration: configuration, primary: primary)
    }
}

private struct StudioButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    var primary: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .medium : .regular))
            .foregroundStyle(primary ? StudioChrome.canvas : StudioChrome.text.opacity(configuration.isPressed ? 1 : 0.8))
            .padding(.horizontal, primary ? 14 : 2)
            .padding(.vertical, primary ? 7 : 2)
            .background {
                if primary {
                    Rectangle().fill(StudioChrome.text.opacity(configuration.isPressed ? 0.82 : 1))
                }
            }
            .opacity(isEnabled ? 1 : 0.35)
    }
}

/// Text control that sits on a photograph, with no chrome.
struct StudioQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(StudioChrome.text.opacity(configuration.isPressed ? 1 : 0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 1200
    }

    func cachedImage(url: URL, maxPixelSize: Int) -> NSImage? {
        let key = "\(maxPixelSize)|\(url.path)" as NSString
        return cache.object(forKey: key)
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

    /// Warm the next screenful so scrolling and loupe never flash empty cells.
    func prewarm(urls: [URL], maxPixelSize: Int) {
        let unique = Array(Set(urls.map(\.path))).prefix(48).compactMap { path -> URL? in
            URL(fileURLWithPath: path)
        }
        for url in unique {
            let key = "\(maxPixelSize)|\(url.path)" as NSString
            if cache.object(forKey: key) != nil { continue }
            Task.detached(priority: .utility) {
                _ = await ThumbnailCache.shared.image(url: url, maxPixelSize: maxPixelSize)
            }
        }
    }
}

struct CachedThumbnail: View {
    let url: URL
    var maxPixelSize: Int = 360
    var contentMode: ContentMode = .fit

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            StudioChrome.photo
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(StudioChrome.ease, value: image != nil)
        .task(id: "\(maxPixelSize)|\(url.path)") {
            if let warm = ThumbnailCache.shared.cachedImage(url: url, maxPixelSize: maxPixelSize) {
                image = warm
            }
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
