import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Lays a finished book out as a print-ready PDF: square pages with a 0.125
/// inch bleed. The default 8 x 8 inch file is for any photo-book printer; the
/// Lulu preset is 8.5 x 8.5 inches with the cover as its own wraparound PDF.
/// Photos come from the book's own finished JPEGs, so the PDF matches the web
/// book exactly, and can be made at any time.
public enum BookPrinter {
    public struct Options: Sendable {
        /// Trim size in points (72 per inch).
        public var trim: CGFloat = 576
        public var bleed: CGFloat = 9
        public var margin: CGFloat = 54
        public var footer: String?
        /// Whether the first page is the photo cover. Printers that take the
        /// cover as a separate file get a quiet title page instead.
        public var includeCover = true
        /// Blank pages are added before the last page up to this count.
        public var minimumPages = 0
        /// Pad to an even page count, for printers that need one.
        public var evenPages = false

        public init(footer: String? = nil) {
            self.footer = footer
        }

        /// Lulu's 8.5 inch square, cover separate, at least `minimumPages`.
        public static func lulu(minimumPages: Int, footer: String? = nil) -> Options {
            var options = Options(footer: footer)
            options.trim = 612
            options.includeCover = false
            options.minimumPages = minimumPages
            options.evenPages = true
            return options
        }
    }

    /// A wraparound cover: back, spine and front on one sheet, with bleed.
    public struct CoverSize: Sendable, Equatable {
        /// The whole sheet in points, as the printer gives it.
        public var width: CGFloat
        public var height: CGFloat
        /// The trim size of one panel.
        public var trim: CGFloat

        public init(width: CGFloat, height: CGFloat, trim: CGFloat) {
            self.width = width
            self.height = height
            self.trim = trim
        }

        /// What goes past the trim on each edge: bleed, plus the wrap on a hardcover.
        public var edge: CGFloat { max(0, (height - trim) / 2) }
        public var spine: CGFloat { max(0, width - 2 * (trim + edge)) }
        public var back: CGRect { CGRect(x: 0, y: 0, width: trim + edge, height: height) }
        public var spineRect: CGRect { CGRect(x: trim + edge, y: 0, width: spine, height: height) }
        public var front: CGRect { CGRect(x: trim + edge + spine, y: 0, width: trim + edge, height: height) }
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
            kCGPDFContextCreator: "Bound"
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
        if !options.includeCover {
            // A quiet title page; the printed cover is its own file.
            newPage {
                var y = safe.midY - 40
                if let line = book.creditLine {
                    _ = draw(context, line, font: sans(11), color: muted, in: CGRect(x: safe.minX, y: y - 30, width: safe.width, height: 20), centered: true)
                }
                y += draw(context, book.title, font: serif(30, bold: true), color: ink, in: CGRect(x: safe.minX, y: y, width: safe.width, height: 120), centered: true)
                if !book.dateRange.isEmpty {
                    _ = draw(context, book.dateRange.uppercased(), font: sans(10, bold: true), color: accent, in: CGRect(x: safe.minX, y: safe.midY + 70, width: safe.width, height: 18), centered: true)
                }
            }
        } else { newPage {
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
        } }

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

        // Blank pages so the count meets the printer's minimum, then the closing page.
        var target = max(options.minimumPages, pages + 1)
        if options.evenPages, target % 2 == 1 { target += 1 }
        while pages + 1 < target { newPage {} }

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
    static let accent = CGColor(red: 0.702, green: 0.196, blue: 0.169, alpha: 1)
    static let paper = CGColor(red: 0.969, green: 0.949, blue: 0.918, alpha: 1)

    /// The wraparound cover: the cover photo across the front, the title on a
    /// shade at its foot, the title down the spine when it's wide enough, and
    /// the credit line on the back.
    @discardableResult
    public static func cover(book: TripBook, folder: URL, to url: URL, size: CoverSize, footer: String? = "Bound · Finish the trip.") throws -> URL {
        var mediaBox = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, [
            kCGPDFContextTitle: book.title + " cover",
            kCGPDFContextCreator: "Bound"
        ] as CFDictionary) else { throw PrintError.cannotCreate }
        context.beginPDFPage([kCGPDFContextMediaBox: data(mediaBox)] as CFDictionary)
        context.setFillColor(paper)
        context.fill(mediaBox)
        let inset = size.edge + 36
        // Front.
        let all = book.allPhotos
        let photo = all.first { $0.id == book.coverPhotoID } ?? all.first
        let front = size.front
        if let photo, let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(BookRenderer.photoPath(photo)) as CFURL, nil),
           let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            fill(context, picture, in: front)
            context.setFillColor(CGColor(gray: 0, alpha: 0.4))
            context.fill(CGRect(x: front.minX, y: 0, width: front.width, height: size.height * 0.34))
        } else {
            context.setFillColor(ink)
            context.fill(front)
        }
        let words = CGRect(x: front.minX + 36, y: inset, width: front.width - 36 - inset, height: size.height * 0.34 - inset)
        var y = words.minY
        if let line = book.creditLine {
            y += draw(context, line, font: sans(11), color: CGColor(gray: 1, alpha: 0.92), in: CGRect(x: words.minX, y: y, width: words.width, height: 20))
        }
        if !book.dateRange.isEmpty {
            y += draw(context, book.dateRange.uppercased(), font: sans(10, bold: true), color: CGColor(gray: 1, alpha: 0.85), in: CGRect(x: words.minX, y: y + 4, width: words.width, height: 18)) + 4
        }
        _ = draw(context, book.title, font: serif(32, bold: true), color: CGColor(gray: 1, alpha: 1), in: CGRect(x: words.minX, y: y + 6, width: words.width, height: max(40, words.maxY - y - 6)))
        // Spine: ink, with the title running down it when there's room.
        let spine = size.spineRect
        if spine.width > 0 {
            context.setFillColor(ink)
            context.fill(spine)
            if spine.width >= 18 {
                context.saveGState()
                context.translateBy(x: spine.midX, y: spine.midY)
                context.rotate(by: -.pi / 2)
                let length = size.height - 2 * inset
                let fontSize = min(14, spine.width * 0.5)
                _ = draw(context, book.title, font: serif(fontSize, bold: true), color: paper, in: CGRect(x: -length / 2, y: -fontSize * 0.7, width: length, height: fontSize * 1.6), centered: true)
                context.restoreGState()
            }
        }
        // Back: the credit line, a ribbon mark and the footer.
        let back = size.back
        let backSafe = CGRect(x: back.minX + inset, y: inset, width: back.width - inset - 36, height: size.height - 2 * inset)
        if let line = book.creditLine {
            _ = draw(context, line, font: serif(15), color: muted, in: backSafe.insetBy(dx: 20, dy: backSafe.height * 0.3), centered: true)
        }
        if let footer {
            _ = draw(context, footer, font: serif(10), color: muted, in: CGRect(x: backSafe.minX, y: backSafe.minY, width: backSafe.width, height: 16), centered: true)
        }
        context.setFillColor(accent)
        let ribbon = CGMutablePath()
        let rx = backSafe.midX - 7, top = backSafe.minY + 70
        ribbon.move(to: CGPoint(x: rx, y: top))
        ribbon.addLine(to: CGPoint(x: rx + 14, y: top))
        ribbon.addLine(to: CGPoint(x: rx + 14, y: top - 26))
        ribbon.addLine(to: CGPoint(x: rx + 7, y: top - 20))
        ribbon.addLine(to: CGPoint(x: rx, y: top - 26))
        ribbon.closeSubpath()
        context.addPath(ribbon)
        context.fillPath()
        context.endPDFPage()
        context.closePDF()
        return url
    }

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
