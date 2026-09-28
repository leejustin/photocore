import Foundation
import ImageIO
import PhotoEngineCore

/// Embeds Lightroom-readable stars and color labels in a JPEG without re-encoding it.
public enum JPEGRatingStamp {
    public static func stamp(_ mark: PhotoReviewMark, into url: URL) throws {
        let label = mark.color.lightroomLabel
        guard mark.stars > 0 || label != nil else { return }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else {
            throw PhotoEngineError.invalidArgument("Could not read \(url.lastPathComponent) to add its rating.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw PhotoEngineError.invalidArgument("Could not rewrite \(url.lastPathComponent).")
        }
        let metadata = CGImageMetadataCreateMutable()
        if mark.stars > 0 {
            CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, String(min(5, mark.stars)) as CFString)
        }
        if let label {
            CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, label as CFString)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: kCFBooleanTrue as Any
        ]
        var error: Unmanaged<CFError>?
        // CopyImageSource finalizes the destination itself; do not call CGImageDestinationFinalize.
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            throw PhotoEngineError.invalidArgument("Could not add the rating to \(url.lastPathComponent).")
        }
        try (output as Data).write(to: url, options: .atomic)
    }
}
