import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// What a phone-roll frame is, when it is not a photograph worth culling.
public enum UtilityShotKind: String, Codable, Sendable, Equatable {
    case none
    case screenshot
    case document
}

/// Finds receipts, whiteboards, menus and other text-heavy frames in a camera roll.
/// Screenshots are already flagged by Photos; this catches the photographed ones.
public enum UtilityShotDetector {
    /// Share of the frame covered by recognized text (0 to 1) and the number of
    /// confident text lines.
    public static func measureText(_ image: CGImage) -> (coverage: Double, lines: Int) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        VisionCompute.prepare([request])
        VisionCompute.gate.wait()
        defer { VisionCompute.gate.signal() }
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let observations = request.results else { return (0, 0) }
        let confident = observations.filter { $0.confidence >= 0.4 }
        let area = confident.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
        return (min(area, 1), confident.count)
    }

    /// A frame is a document when it holds many separate lines of text covering a
    /// real share of the frame. Line count is the reliable signal: a sign or a
    /// T-shirt is one to three lines, a receipt or menu is dozens, and the fast
    /// recognizer sometimes reports one large false box on plain shapes.
    public static func classify(textCoverage: Double, lineCount: Int) -> UtilityShotKind {
        lineCount >= 6 && textCoverage >= 0.06 ? .document : .none
    }

    public static func classify(_ image: CGImage) -> UtilityShotKind {
        let measured = measureText(image)
        return classify(textCoverage: measured.coverage, lineCount: measured.lines)
    }
}

/// The free tier's edit: Core Image's own automatic adjustments (exposure, vibrance,
/// tone curve, face balance, red eye) at screen resolution. Good on a phone screen,
/// deliberately short of the hosted finish.
public enum AutoEnhance {
    public struct Result: Sendable {
        public var jpeg: Data
        public var appliedFilters: [String]
    }

    public static func render(url: URL, maxPixel: CGFloat = 2048, context: CIContext = CIContext()) throws -> Result {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try render(image: cg, context: context)
    }

    public static func render(image cg: CGImage, context: CIContext = CIContext()) throws -> Result {
        var image = CIImage(cgImage: cg)
        let filters = image.autoAdjustmentFilters(options: [.redEye: true, .crop: false, .level: false])
        var applied: [String] = []
        for filter in filters {
            filter.setValue(image, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                image = output
                applied.append(filter.name)
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let data = context.jpegRepresentation(
            of: image.cropped(to: CIImage(cgImage: cg).extent),
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
        ) else { throw CocoaError(.fileWriteUnknown) }
        return Result(jpeg: data, appliedFilters: applied)
    }
}
