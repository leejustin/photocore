import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Lays a finished book out as a print-ready PDF: 8 x 8 inch square pages with
/// a 0.125 inch bleed, the size most photo-book printers (Lulu, Blurb and
/// similar) accept as an upload. Photos come from the book's own finished JPEGs,
/// so the PDF matches the web book exactly, and can be made at any time.
public enum BookPrinter {
    public struct Options: Sendable {
        /// Trim size in points (72 per inch).
        public var trim: CGFloat = 576
        public var bleed: CGFloat = 9
        public var margin: CGFloat = 54
        public var footer: String?

        public init(footer: String? = nil) {
            self.footer = footer
        }
    }

    public struct Report: Sendable {
        public var url: URL
        public var pages: Int
        public var photos: Int
    }

    public enum PrintError: Error {
        case cannotCreate
    }

    public static func pdf(book: TripBook, folder: URL, to url: URL, options: Options = Options()) throws -> Report {
        let page = options.trim + options.bleed * 2
        var mediaBox = CGRect(x: 0, y: 0, width: page, height: page)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, [
            kCGPDFContextTitle: book.title,
            kCGPDFContextCreator: "Photocore"
        ] as CFDictionary) else { throw PrintError.cannotCreate }

        let trimBox = CGRect(x: options.bleed, y: options.bleed, width: options.trim, height: options.trim)
        let pageInfo = [
            kCGPDFContextMediaBox: data(mediaBox),
            kCGPDFContextBleedBox: data(mediaBox),
            kCGPDFContextTrimBox: data(trimBox)
        ] as CFDictionary
        let safe = trimBox.insetBy(dx: options.margin, dy: options.margin)
        var pages = 0, photos = 0
        func newPage(_ draw: () -> Void) {
            context.beginPDFPage(pageInfo)
            context.setFillColor(CGColor(red: 0.985, green: 0.975, blue: 0.955, alpha: 1))
            context.fill(mediaBox)
            draw()
            context.endPDFPage()
            pages += 1
        }
        func image(_ photo: BookPhoto) -> CGImage? {
            let url = folder.appendingPathComponent(BookRenderer.photoPath(photo))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        // Cover: the cover photo to the edge of the bleed, the title over a shade.
        let all = book.allPhotos
        let cover = all.first { $0.id == book.coverPhotoID } ?? all.first
        newPage {
            if let cover, let picture = image(cover) {
                fill(context, picture, in: mediaBox)
                photos += 1
                context.setFillColor(CGColor(gray: 0, alpha: 0.38))
                context.fill(CGRect(x: 0, y: 0, width: page, height: page * 0.36))
            }
            let ink = cover == nil ? ink : CGColor(gray: 1, alpha: 1)
            var y = trimBox.minY + options.margin
            if let line = book.creditLine {
                y += draw(context, line, font: sans(11), color: ink, in: CGRect(x: safe.minX, y: y, width: safe.width, height: 20))
            }
            if !book.dateRange.isEmpty {
                y += draw(context, book.dateRange.uppercased(), font: sans(10, bold: true), color: ink, in: CGRect(x: safe.minX, y: y + 4, width: safe.width, height: 18)) + 4
            }
            _ = draw(context, book.title, font: serif(34, bold: true), color: ink, in: CGRect(x: safe.minX, y: y + 6, width: safe.width, height: 130))
        }

        // The intro on its own page.
        if !book.intro.isEmpty {
            newPage {
                _ = draw(context, book.intro, font: serif(19), color: ink, in: safe.insetBy(dx: 24, dy: 120), centered: true)
            }
        }

        for (index, section) in book.sections.enumerated() {
            var pictures = section.photos
            if pictures.count > 1, let cover, pictures.first?.id == cover.id { pictures.removeFirst() }
            // Chapter opener: number, when and where, heading and diary.
            newPage {
                var y = safe.maxY - 60
                func line(_ text: String, _ font: CTFont, _ color: CGColor, height: CGFloat, gap: CGFloat) {
                    guard !text.isEmpty else { return }
                    y -= height
                    _ = draw(context, text, font: font, color: color, in: CGRect(x: safe.minX, y: y, width: safe.width, height: height))
                    y -= gap
                }
                line(String(format: "%02d", index + 1), serif(40), accent, height: 48, gap: 10)
                line([section.dateLine, section.place ?? ""].filter { !$0.isEmpty }.joined(separator: " · ").uppercased(), sans(9.5, bold: true), muted, height: 16, gap: 8)
                line(section.heading, serif(26, bold: true), ink, height: 70, gap: 18)
                if !section.diary.isEmpty {
                    // Set right under the heading, not at the foot of the page.
                    _ = draw(context, section.diary, font: serif(15, italic: true), color: ink, in: CGRect(x: safe.minX, y: safe.minY, width: safe.width * 0.86, height: y - safe.minY), top: true)
                }
            }
            // Photos: landscapes one to a page, portraits in pairs.
            for row in BookRenderer.rows(for: pictures) {
                let tall = row.count == 2 && row.allSatisfy(\.isPortrait)
                let pair = tall ? [row] : row.map { [$0] }
                for group in pair {
                    newPage {
                        let captionHeight: CGFloat = group.contains { !$0.caption.isEmpty || $0.credit != nil } ? 40 : 0
                        let area = CGRect(x: safe.minX, y: safe.minY + captionHeight, width: safe.width, height: safe.height - captionHeight)
                        let gap: CGFloat = 12
                        let width = (area.width - gap * CGFloat(group.count - 1)) / CGFloat(group.count)
                        for (i, photo) in group.enumerated() {
                            let frame = CGRect(x: area.minX + CGFloat(i) * (width + gap), y: area.minY, width: width, height: area.height)
                            var drawn = frame
                            if let picture = image(photo) {
                                drawn = fit(context, picture, in: frame)
                                photos += 1
                            }
                            var caption = photo.caption
                            if book.contributors != nil, let credit = photo.credit { caption += (caption.isEmpty ? "" : "  ·  ") + "by " + credit }
                            if !caption.isEmpty {
                                // Directly under the photo, aligned with its left edge.
                                _ = draw(context, caption, font: sans(10), color: muted, in: CGRect(x: drawn.minX, y: drawn.minY - captionHeight, width: drawn.width, height: captionHeight - 8), top: true)
                            }
                        }
                    }
                }
            }
        }

        // Closing page: who took the photos.
        newPage {
            var text = book.creditLine ?? ""
            if let footer = options.footer { text += (text.isEmpty ? "" : "\n\n") + footer }
            if !text.isEmpty {
                _ = draw(context, text, font: serif(14), color: muted, in: safe.insetBy(dx: 40, dy: 200), centered: true)
            }
        }
        context.closePDF()
        return Report(url: url, pages: pages, photos: photos)
    }

    // MARK: Drawing

    static let ink = CGColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1)
    static let muted = CGColor(red: 0.43, green: 0.40, blue: 0.37, alpha: 1)
    static let accent = CGColor(red: 0.72, green: 0.33, blue: 0.18, alpha: 1)

    static func serif(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
        let name = bold ? "Georgia-Bold" : (italic ? "Georgia-Italic" : "Georgia")
        return CTFontCreateWithName(name as CFString, size, nil)
    }

    static func sans(_ size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
    }

    static func data(_ rect: CGRect) -> CFData {
        var box = rect
        return Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
    }

    /// Draws text in `rect`, at its foot unless centered or `top`; returns the height it used.
    @discardableResult
    static func draw(_ context: CGContext, _ text: String, font: CTFont, color: CGColor, in rect: CGRect, centered: Bool = false, top: Bool = false) -> CGFloat {
        var alignment: CTTextAlignment = centered ? .center : .left
        var spacing: CGFloat = CTFontGetSize(font) * 0.3
        let settings = [
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: &alignment),
            CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: &spacing)
        ]
        let style = CTParagraphStyleCreate(settings, settings.count)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: rect.width, height: rect.height), nil)
        let height = min(rect.height, ceil(fitted.height))
        let y = centered ? rect.midY - height / 2 : (top ? rect.maxY - height : rect.minY)
        let box = CGRect(x: rect.minX, y: y, width: rect.width, height: height)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
        context.saveGState()
        CTFrameDraw(frame, context)
        context.restoreGState()
        return height
    }

    /// Fills the rectangle, cropping the edges (for the cover).
    static func fill(_ context: CGContext, _ image: CGImage, in rect: CGRect) {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.saveGState()
        context.clip(to: rect)
        context.draw(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        context.restoreGState()
    }

    /// Fits the whole photo inside the rectangle, centered; returns where it went.
    @discardableResult
    static func fit(_ context: CGContext, _ image: CGImage, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let placed = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        context.draw(image, in: placed)
        return placed
    }
}
