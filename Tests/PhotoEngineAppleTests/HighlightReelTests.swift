import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PhotoEngineApple
import Testing
import UniformTypeIdentifiers

extension VisionSuites {
    @Suite("Highlight reel")
    struct HighlightReelTests {
        static func stills(_ count: Int) throws -> [CGImage] {
            let folder = try SyntheticPhotos.makeFolder(count: count)
            defer { try? FileManager.default.removeItem(at: folder) }
            return try (0..<count).map { i in
                try #require(CGImage.photocoreThumbnail(url: folder.appendingPathComponent(String(format: "IMG_%04d.jpg", i)), maxPixel: 1200))
            }
        }

        @Test("stills and a video become a vertical reel of the expected length")
        func reel() async throws {
            let images = try Self.stills(4)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer {
                if ProcessInfo.processInfo.environment["PHOTOCORE_KEEP_REEL"] == nil { try? FileManager.default.removeItem(at: dir) }
            }
            // A one-second clip made from a still stands in for Live Photo motion.
            var short = HighlightReel.Options()
            short.size = CGSize(width: 640, height: 480)
            short.stillSeconds = 1
            short.endCard = nil
            short.fadeSeconds = 0
            let video = try await HighlightReel.render(clips: [ReelClip(.still(images[3]))], to: dir.appendingPathComponent("live.mp4"), options: short)
            #expect(abs(video.duration - 1) < 0.1)

            var options = HighlightReel.Options(title: "Lisbon", subtitle: "June 2026")
            options.size = CGSize(width: 540, height: 960)
            let clips = [ReelClip(.still(images[0])), ReelClip(.still(images[1]), focus: NormalizedCrop(x: 0.6, y: 0.2, width: 0.3, height: 0.3)), ReelClip(.video(video.url)), ReelClip(.still(images[2]))]
            let out = dir.appendingPathComponent("reel.mp4")
            let result = try await HighlightReel.render(clips: clips, to: out, options: options)
            // 3 stills x 2.2 s + video 2.6 s (held) + 4 fades x 0.35 s + 1.2 s end card.
            let expected = 3 * 2.2 + 2.6 + 4 * 0.35 + 1.2
            #expect(abs(result.duration - expected) < 0.2, "reel is \(result.duration) s")
            let asset = AVURLAsset(url: out)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let size = try await track.load(.naturalSize)
            #expect(size == CGSize(width: 540, height: 960))
            let seconds = try await asset.load(.duration).seconds
            #expect(abs(seconds - expected) < 0.2)

            if let keep = ProcessInfo.processInfo.environment["PHOTOCORE_KEEP_REEL"] {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                for (name, t) in [("title", 0.5), ("fade", 2.35), ("video", 6.0), ("end", expected - 0.3)] {
                    let (cg, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
                    let url = URL(fileURLWithPath: keep).appendingPathComponent("reel-\(name).jpg")
                    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, cg, nil)
                    CGImageDestinationFinalize(dest)
                }
            }
        }

        @Test("an empty reel is refused")
        func empty() async {
            await #expect(throws: HighlightReel.ReelError.self) {
                _ = try await HighlightReel.render(clips: [], to: FileManager.default.temporaryDirectory.appendingPathComponent("none.mp4"))
            }
        }
    }
}
