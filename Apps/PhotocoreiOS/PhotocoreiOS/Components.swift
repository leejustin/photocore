import ImageIO
import Photos
import SwiftUI

extension Color {
    static let paper = Color("Paper")
    static let ink = Color("Ink")
}

extension Font {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
}

/// A Photos asset drawn at the size it is shown.
struct AssetImage: View {
    let identifier: String
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.ink.opacity(0.06)
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipped()
            .task(id: identifier) { await load(size: proxy.size) }
        }
    }

    private func load(size: CGSize) async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return }
        let scale = UIScreen.main.scale
        let target = CGSize(width: max(size.width, 80) * scale, height: max(size.height, 80) * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        for await delivered in Self.images(asset: asset, target: target, options: options) {
            image = delivered
        }
    }

    private static func images(asset: PHAsset, target: CGSize, options: PHImageRequestOptions) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { image, info in
                if let image { continuation.yield(image) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { continuation.finish() }
            }
        }
    }
}

/// A local JPEG (the culling copy) drawn as a downsampled thumbnail.
struct FileImage: View {
    let url: URL
    var maxPixel: CGFloat = 600
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Color.ink.opacity(0.06)
                }
            }
            .clipped()
        }
        .task(id: url) {
            let url = url, maxPixel = maxPixel
            image = await Task.detached(priority: .userInitiated) { Self.thumbnail(url: url, maxPixel: maxPixel) }.value
        }
    }

    nonisolated static func thumbnail(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 14))
            .foregroundStyle(.white)
    }
}

/// The quieter action next to a primary one, so two orange buttons never compete.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color.ink.opacity(configuration.isPressed ? 0.12 : 0.07), in: .rect(cornerRadius: 14))
            .foregroundStyle(Color.ink)
    }
}

struct LaunchOptions {
    static var autoOpenFirstTrip: Bool { UserDefaults.standard.bool(forKey: "PhotocoreAutoOpen") }
    static var autoSwipe: Bool { UserDefaults.standard.bool(forKey: "PhotocoreAutoSwipe") }
}
