import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws labelled thumbnails in a grid and writes a JPEG. Tooling only.
enum ContactSheet {
    struct Cell {
        let url: URL
        let label: String
    }

    static func thumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func write(_ cells: [Cell], columns: Int, cellSize: Int, to output: URL) throws {
        let labelHeight = 22
        let rows = (cells.count + columns - 1) / columns
        let width = columns * cellSize
        let height = max(1, rows) * (cellSize + labelHeight)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, cell) in cells.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = column * cellSize
            let top = height - row * (cellSize + labelHeight)
            if let image = thumbnail(cell.url, maxPixelSize: cellSize) {
                let scale = min(Double(cellSize - 4) / Double(image.width), Double(cellSize - 4) / Double(image.height))
                let w = Double(image.width) * scale
                let h = Double(image.height) * scale
                context.draw(image, in: CGRect(x: Double(x) + (Double(cellSize) - w) / 2, y: Double(top - cellSize) + (Double(cellSize) - h) / 2, width: w, height: h))
            }
            (cell.label as NSString).draw(
                at: CGPoint(x: x + 4, y: top - cellSize - labelHeight + 4),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]
            )
        }
        NSGraphicsContext.current = nil
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
