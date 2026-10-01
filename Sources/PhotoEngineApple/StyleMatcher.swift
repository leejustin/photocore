import CoreImage
import Foundation
import ImageIO
import PhotoEngineCore

/// Learns a simple album look from reference JPEGs the photographer already graded.
public struct MatchedStyle: Sendable, Equatable {
    public var name: String
    public var recipe: EditRecipe
    public var sampleCount: Int

    public init(name: String, recipe: EditRecipe, sampleCount: Int) {
        self.name = name
        self.recipe = recipe
        self.sampleCount = sampleCount
    }
}

public enum StyleMatcher {
    /// Estimate exposure / contrast / saturation / warmth deltas from graded references
    /// versus a neutral decode of the same files when possible, else absolute look stats.
    public static func match(from references: [URL], name: String = "Your style") -> MatchedStyle? {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        var exposures: [Double] = []
        var contrasts: [Double] = []
        var sats: [Double] = []
        var temps: [Double] = []
        for url in references.prefix(40) {
            guard let image = loadCIImage(url) else { continue }
            let stats = sampleStats(image, context: context)
            // Map average luminance to a gentle exposure bias around mid-gray.
            exposures.append((0.45 - stats.luma) * 1.4)
            contrasts.append((stats.contrast - 0.18) * 1.2)
            sats.append((stats.saturation - 0.22) * 1.1)
            temps.append((stats.warmth - 0.5) * 1.6)
        }
        guard !exposures.isEmpty else { return nil }
        func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, v)) }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }

        var recipe = EditRecipe(style: .natural, styleIntensity: 0.55)
        recipe.exposure = clamp(mean(exposures), -0.6, 0.6)
        recipe.contrast = clamp(mean(contrasts), -0.45, 0.45)
        recipe.saturation = clamp(mean(sats), -0.4, 0.4)
        recipe.temperature = clamp(mean(temps), -0.7, 0.7)
        recipe.highlights = clamp(-mean(exposures) * 0.25, -0.4, 0.2)
        recipe.shadows = clamp(mean(exposures) * 0.2, -0.2, 0.45)
        return MatchedStyle(name: name, recipe: recipe, sampleCount: exposures.count)
    }

    private struct Stats {
        var luma: Double
        var contrast: Double
        var saturation: Double
        var warmth: Double
    }

    private static func loadCIImage(_ url: URL) -> CIImage? {
        if let image = CIImage(contentsOf: url) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CIImage(cgImage: cg)
    }

    private static func sampleStats(_ image: CIImage, context: CIContext) -> Stats {
        let extent = image.extent.integral
        let target = CGRect(x: 0, y: 0, width: 64, height: 64)
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: target.width / max(extent.width, 1),
            y: target.height / max(extent.height, 1)
        ))
        var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
        context.render(
            scaled,
            toBitmap: &rgba,
            rowBytes: 64 * 4,
            bounds: target,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        var lumaSum = 0.0
        var satSum = 0.0
        var warmSum = 0.0
        var lumas: [Double] = []
        lumas.reserveCapacity(64 * 64)
        let count = 64 * 64
        for i in 0..<count {
            let o = i * 4
            let r = Double(rgba[o]) / 255
            let g = Double(rgba[o + 1]) / 255
            let b = Double(rgba[o + 2]) / 255
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let sat = maxC > 0 ? (maxC - minC) / maxC : 0
            lumaSum += luma
            satSum += sat
            warmSum += (r - b + 1) / 2
            lumas.append(luma)
        }
        lumas.sort()
        let p20 = lumas[Int(Double(count) * 0.2)]
        let p80 = lumas[Int(Double(count) * 0.8)]
        return Stats(
            luma: lumaSum / Double(count),
            contrast: max(0, p80 - p20),
            saturation: satSum / Double(count),
            warmth: warmSum / Double(count)
        )
    }
}

/// Nudge every keeper toward a shared white-balance / exposure center.
public enum AlbumConsistency {
    public static func center(of photos: [AnalyzedPhoto]) -> (temperature: Double, exposure: Double) {
        guard !photos.isEmpty else { return (0, 0) }
        let brightness = photos.map(\.signals.brightness)
        let meanB = brightness.reduce(0, +) / Double(brightness.count)
        // Target mid exposure; temperature left neutral unless caller pairs with StyleMatcher.
        let exposure = min(0.35, max(-0.35, (0.5 - meanB) * 0.8))
        return (0, exposure)
    }

    public static func apply(to recipe: EditRecipe, temperature: Double, exposure: Double, strength: Double = 0.65) -> EditRecipe {
        var next = recipe
        next.temperature += temperature * strength
        next.exposure += exposure * strength
        return next
    }
}
