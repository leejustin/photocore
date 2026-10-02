import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// One moment in a highlight reel: a still (shown with a slow push-in) or a
/// short video such as a Live Photo's motion.
public struct ReelClip: Sendable {
    public enum Source: Sendable {
        case still(CGImage)
        case video(URL)
    }

    public var source: Source
    /// Where the subject is, so the vertical crop keeps it in frame.
    public var focus: NormalizedCrop?

    public init(_ source: Source, focus: NormalizedCrop? = nil) {
        self.source = source
        self.focus = focus
    }
}

/// Builds a short vertical video from a trip's keepers with AVFoundation and
/// Core Image: Ken Burns stills, Live Photo motion, crossfades, a title card and
/// an end card. Frames are rendered one at a time, so memory stays flat.
public enum HighlightReel {
    public struct Options: Sendable {
        public var size: CGSize = CGSize(width: 1080, height: 1920)
        public var framesPerSecond: Int32 = 30
        public var stillSeconds: Double = 2.2
        public var videoSeconds: Double = 2.6
        public var fadeSeconds: Double = 0.35
        public var title: String?
        public var subtitle: String?
        public var endCard: String? = "Made with Photocore"

        public init(title: String? = nil, subtitle: String? = nil) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    public struct Result: Sendable {
        public var url: URL
        public var duration: Double
        public var frames: Int
    }

    public enum ReelError: Error {
        case noClips
        case writerFailed(String)
    }

    public static func render(clips: [ReelClip], to url: URL, options: Options = Options()) async throws -> Result {
        guard !clips.isEmpty else { throw ReelError.noClips }
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = Int(options.size.width), height = Int(options.size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoExpectedSourceFrameRateKey: options.framesPerSecond]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw ReelError.writerFailed(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        let canvas = CGRect(origin: .zero, size: options.size)
        let fps = Double(options.framesPerSecond)
        var frameIndex: Int64 = 0

        func append(_ image: CIImage) async throws {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw ReelError.writerFailed("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw ReelError.writerFailed("pixel buffer") }
            context.render(image.cropped(to: canvas), to: buffer, bounds: canvas, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let time = CMTime(value: frameIndex, timescale: CMTimeScale(options.framesPerSecond))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw ReelError.writerFailed(writer.error?.localizedDescription ?? "append")
            }
            frameIndex += 1
        }

        var previousLast: CIImage?
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            let frames = try frameSource(for: clip, options: options)
            var first = true
            var count = 0
            let total = clip.isVideo ? Int(options.videoSeconds * fps) : Int(options.stillSeconds * fps)
            while count < total, var frame = try frames.next(count, total) {
                if index == 0, let title = options.title {
                    frame = overlayTitle(title, subtitle: options.subtitle, on: frame, size: options.size, progress: Double(count) / Double(total))
                }
                if first, let previous = previousLast {
                    // Crossfade from the last frame of the previous clip.
                    let fadeFrames = Int(options.fadeSeconds * fps)
                    for step in 0..<fadeFrames {
                        let t = Double(step + 1) / Double(fadeFrames + 1)
                        try await append(dissolve(from: previous, to: frame, t: t))
                    }
                }
                first = false
                try await append(frame)
                previousLast = frame
                count += 1
            }
        }
        if let end = options.endCard {
            let card = endCard(end, size: options.size)
            let fadeFrames = Int(options.fadeSeconds * fps)
            if let previous = previousLast {
                for step in 0..<fadeFrames { try await append(dissolve(from: previous, to: card, t: Double(step + 1) / Double(fadeFrames + 1))) }
            }
            for _ in 0..<Int(1.2 * fps) { try await append(card) }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ReelError.writerFailed(writer.error?.localizedDescription ?? "finish") }
        return Result(url: url, duration: Double(frameIndex) / fps, frames: Int(frameIndex))
    }

    // MARK: Frames

    final class FrameSource {
        let next: (Int, Int) throws -> CIImage?
        init(_ next: @escaping (Int, Int) throws -> CIImage?) { self.next = next }
    }

    static func frameSource(for clip: ReelClip, options: Options) throws -> FrameSource {
        switch clip.source {
        case .still(let cg):
            let base = CIImage(cgImage: cg)
            return FrameSource { index, total in
                // A slow push-in from 100% to 108%, centered on the subject.
                let progress = Double(index) / Double(max(total - 1, 1))
                return fill(base, size: options.size, focus: clip.focus, zoom: 1 + 0.08 * easeInOut(progress))
            }
        case .video(let url):
            let asset = AVURLAsset(url: url)
            let reader = try AVAssetReader(asset: asset)
            guard let track = asset.tracks(withMediaType: .video).first else { return FrameSource { _, _ in nil } }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { return FrameSource { _, _ in nil } }
            let transform = track.preferredTransform
            var last: CIImage?
            return FrameSource { _, _ in
                // The closure keeps the reader alive; without it the output is invalid.
                if reader.status == .reading, let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
                    let upright = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                    let normalized = upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
                    last = fill(normalized, size: options.size, focus: clip.focus, zoom: 1)
                    return last
                }
                // A short Live Photo ends early: hold its last frame.
                return last
            }
        }
    }

    /// Aspect-fill into the vertical frame, keeping the focus region in view.
    static func fill(_ image: CIImage, size: CGSize, focus: NormalizedCrop?, zoom: Double) -> CIImage {
        let extent = image.extent
        let scale = max(size.width / extent.width, size.height / extent.height) * zoom
        let scaledW = extent.width * scale, scaledH = extent.height * scale
        let focus = focus ?? .full
        // Focus is top-left normalized; Core Image is bottom-left.
        let cx = (focus.x + focus.width / 2) * scaledW
        let cy = (1 - (focus.y + focus.height * 0.45)) * scaledH
        let originX = min(max(cx - size.width / 2, 0), scaledW - size.width)
        let originY = min(max(cy - size.height / 2, 0), scaledH - size.height)
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    static func easeInOut(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    static func dissolve(from a: CIImage, to b: CIImage, t: Double) -> CIImage {
        b.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputImageKey: a, kCIInputTimeKey: t])
    }

    // MARK: Text

    static func text(_ string: String, size: CGFloat, font: String) -> CIImage? {
        CIFilter(name: "CITextImageGenerator", parameters: [
            "inputText": string, "inputFontName": font, "inputFontSize": size, "inputScaleFactor": 1.0
        ])?.outputImage
    }

    /// Core Image draws text in black; titles over photos need white.
    static func white(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)
        ])
    }

    static func overlayTitle(_ title: String, subtitle: String?, on frame: CIImage, size: CGSize, progress: Double) -> CIImage {
        // Fade the title out over the first clip.
        let alpha = progress < 0.7 ? 1.0 : max(0, 1 - (progress - 0.7) / 0.3)
        let shade = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35 * alpha)).cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.32))
        var out = shade.composited(over: frame)
        if let titleImage = text(title, size: size.width * 0.085, font: "Georgia-Bold").map(white) {
            let x = max((size.width - titleImage.extent.width) / 2, 40)
            let placed = titleImage.transformed(by: CGAffineTransform(translationX: x, y: size.height * 0.14))
            out = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)]).composited(over: out)
        }
        if let subtitle, let subImage = text(subtitle, size: size.width * 0.04, font: "HelveticaNeue").map(white) {
            let x = max((size.width - subImage.extent.width) / 2, 40)
            let placed = subImage.transformed(by: CGAffineTransform(translationX: x, y: size.height * 0.09))
            out = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha * 0.9)]).composited(over: out)
        }
        return out.cropped(to: CGRect(origin: .zero, size: size))
    }

    static func endCard(_ string: String, size: CGSize) -> CIImage {
        let paper = CIImage(color: CIColor(red: 0.97, green: 0.95, blue: 0.92)).cropped(to: CGRect(origin: .zero, size: size))
        guard let words = text(string, size: size.width * 0.045, font: "Georgia") else { return paper }
        let placed = words.transformed(by: CGAffineTransform(translationX: (size.width - words.extent.width) / 2, y: size.height / 2))
        return placed.composited(over: paper).cropped(to: CGRect(origin: .zero, size: size))
    }
}

extension ReelClip {
    var isVideo: Bool {
        if case .video = source { return true }
        return false
    }
}
