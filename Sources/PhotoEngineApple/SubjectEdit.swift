import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Vision

/// How strongly the subject-aware edit separates subject from background.
public struct SubjectEditSettings: Codable, Sendable, Equatable {
    /// Exposure added to the subject, in stops.
    public var subjectLift: Double
    /// Vibrance added to the subject. Vibrance protects skin better than saturation.
    public var subjectVibrance: Double
    /// Exposure change for the background, in stops; negative quiets it.
    public var backgroundExposure: Double
    /// Background saturation multiplier; below 1 calms busy surroundings.
    public var backgroundSaturation: Double
    /// Background blur as a fraction of the short side; 0 keeps it sharp.
    public var backgroundBlur: Double

    public init(subjectLift: Double = 0.22, subjectVibrance: Double = 0.18, backgroundExposure: Double = -0.12, backgroundSaturation: Double = 0.92, backgroundBlur: Double = 0) {
        self.subjectLift = subjectLift
        self.subjectVibrance = subjectVibrance
        self.backgroundExposure = backgroundExposure
        self.backgroundSaturation = backgroundSaturation
        self.backgroundBlur = backgroundBlur
    }

    public static let natural = SubjectEditSettings()
    /// A light separation only: without a depth map a strong blur melts
    /// foreground objects that frame the subject, which reads as fake.
    public static let portrait = SubjectEditSettings(subjectLift: 0.25, subjectVibrance: 0.15, backgroundExposure: -0.15, backgroundSaturation: 0.9, backgroundBlur: 0.003)
}

public enum SubjectMaskSource: String, Codable, Sendable {
    case foreground
    case person
    case none
}

/// Finds the subject of a photo as a soft mask the size of the image.
public enum SubjectMask {
    public static func mask(for cgImage: CGImage) -> (mask: CIImage, source: SubjectMaskSource)? {
        VisionCompute.gate.wait()
        defer { VisionCompute.gate.signal() }
        let extent = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let foreground = VNGenerateForegroundInstanceMaskRequest()
        VisionCompute.prepare([foreground])
        if (try? handler.perform([foreground])) != nil,
           let observation = foreground.results?.first,
           !observation.allInstances.isEmpty,
           let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) {
            return (scaled(CIImage(cvPixelBuffer: buffer), to: extent), .foreground)
        }

        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .balanced
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        VisionCompute.prepare([person])
        if (try? handler.perform([person])) != nil, let buffer = person.results?.first?.pixelBuffer {
            let mask = scaled(CIImage(cvPixelBuffer: buffer), to: extent)
            if coverage(of: mask) > 0.01 { return (mask, .person) }
        }
        return nil
    }

    static func scaled(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let sx = extent.width / max(mask.extent.width, 1)
        let sy = extent.height / max(mask.extent.height, 1)
        return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: extent)
    }

    /// Share of the frame the mask covers, measured on a small render.
    public static func coverage(of mask: CIImage, context: CIContext = CIContext()) -> Double {
        let side = 32
        let small = mask.transformed(by: CGAffineTransform(scaleX: Double(side) / max(mask.extent.width, 1), y: Double(side) / max(mask.extent.height, 1)))
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        context.render(small, toBitmap: &pixels, rowBytes: side * 4, bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: nil)
        var total = 0
        for index in stride(from: 0, to: pixels.count, by: 4) { total += Int(pixels[index]) }
        return Double(total) / Double(side * side * 255)
    }
}

/// The hosted finish's local edit: the subject is lifted and the background
/// quieted through a feathered Vision mask, so faces brighten without blowing
/// out the sky. Photos with no subject get the global edit only.
public enum SubjectAwareEdit {
    public struct Output {
        public var image: CIImage
        public var maskSource: SubjectMaskSource
    }

    public static func apply(to image: CIImage, visionImage: CGImage, settings: SubjectEditSettings = .natural) -> Output {
        guard let found = SubjectMask.mask(for: visionImage) else { return Output(image: image, maskSource: .none) }
        let extent = image.extent
        var mask = SubjectMask.scaled(found.mask, to: extent)
        let feather = min(extent.width, extent.height) * 0.015
        mask = mask.clampedToExtent().applyingGaussianBlur(sigma: feather).cropped(to: extent)

        let subject = image
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.subjectLift])
            .applyingFilter("CIVibrance", parameters: ["inputAmount": settings.subjectVibrance])
        var background = image
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.backgroundExposure])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: settings.backgroundSaturation])
        if settings.backgroundBlur > 0 {
            let sigma = min(extent.width, extent.height) * settings.backgroundBlur
            background = background.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        }
        let blended = subject.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ]).cropped(to: extent)
        return Output(image: blended, maskSource: found.source)
    }
}

/// Renders a keeper the way the paid finish delivers it: Core Image's automatic
/// adjustments, then the subject-aware edit, written as a full-quality JPEG.
public enum FinishRenderer {
    public struct Output: Sendable {
        public var jpeg: Data
        public var maskSource: SubjectMaskSource
        public var width: Int
        public var height: Int
    }

    public static func render(url: URL, maxPixel: Int = 3072, settings: SubjectEditSettings = .natural, crop: NormalizedCrop? = nil, outputSize: CGSize? = nil, context: CIContext = CIContext()) throws -> Output {
        guard let cg = CGImage.photocoreThumbnail(url: url, maxPixel: maxPixel),
              let vision = CGImage.photocoreThumbnail(url: url, maxPixel: 1024) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var image = CIImage(cgImage: cg)
        let filters = VisionCompute.shared { image.autoAdjustmentFilters(options: [.redEye: true, .crop: false, .level: false]) }
        for filter in filters {
            filter.setValue(image, forKey: kCIInputImageKey)
            if let output = filter.outputImage { image = output.cropped(to: CIImage(cgImage: cg).extent) }
        }
        let edited = SubjectAwareEdit.apply(to: image, visionImage: vision, settings: settings)
        var final = edited.image
        if let crop {
            // NormalizedCrop is top-left origin; Core Image is bottom-left.
            let rect = crop.pixelRect(width: cg.width, height: cg.height)
            let flipped = CGRect(x: rect.minX, y: CGFloat(cg.height) - rect.maxY, width: rect.width, height: rect.height)
            final = final.cropped(to: flipped).transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
        }
        if let outputSize, final.extent.width > 0, final.extent.height > 0 {
            // Exact social sizes such as 1080 x 1350. Upscaling a small source is
            // allowed here because the platforms would do it anyway, less carefully.
            let origin = final.extent.origin
            final = final
                .transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
                .transformed(by: CGAffineTransform(scaleX: outputSize.width / final.extent.width, y: outputSize.height / final.extent.height))
                .cropped(to: CGRect(origin: .zero, size: outputSize))
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let data = context.jpegRepresentation(of: final, colorSpace: colorSpace, options: [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92
        ]) else { throw CocoaError(.fileWriteUnknown) }
        return Output(jpeg: data, maskSource: edited.maskSource, width: Int(final.extent.width), height: Int(final.extent.height))
    }
}
