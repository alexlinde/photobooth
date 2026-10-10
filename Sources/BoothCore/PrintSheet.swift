import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Geometry of the one print layout: a 100 x 148 mm sheet (SELPHY postcard, portrait) holding
/// two identical 50 x 148 mm photo-booth strips side by side, cut apart by hand. Each strip has
/// three 3:2 photo windows and a caption area underneath. All rects use a top-left origin.
public enum PrintLayout {
    /// Render resolution: 12 px/mm (304.8 dpi), so the sheet is 1200 x 1776 px.
    public static let pixelsPerMM: CGFloat = 12
    /// Same aspect as the paper, so `print-scaling=fill` crops nothing.
    public static let sheetMM = CGSize(width: 100, height: 148)
    public static let stripMM = CGSize(width: 50, height: 148)
    public static let stripCount = 2
    /// Photo windows in strip-local mm, top to bottom.
    public static let photoWindowsMM: [CGRect] = [4, 35, 66].map { CGRect(x: 4, y: $0, width: 42, height: 28) }
    public static let captionAreaMM = CGRect(x: 0, y: 94, width: 50, height: 54)
    /// Caption text keeps this far from the caption area's edges.
    public static let captionInsetMM: CGFloat = 4
    public static var photosPerStrip: Int { photoWindowsMM.count }

    public static func sheetPixels(scale: CGFloat = 1) -> (width: Int, height: Int) {
        (Int((sheetMM.width * pixelsPerMM * scale).rounded()), Int((sheetMM.height * pixelsPerMM * scale).rounded()))
    }

    /// Strip `i` (0 = left) on the sheet, in px.
    public static func stripRect(_ i: Int, scale: CGFloat = 1) -> CGRect {
        px(CGRect(x: CGFloat(i) * stripMM.width, y: 0, width: stripMM.width, height: stripMM.height), scale)
    }

    /// Photo window `k` of strip `i` on the sheet, in px.
    public static func photoWindow(strip i: Int, _ k: Int, scale: CGFloat = 1) -> CGRect {
        px(photoWindowsMM[k].offsetBy(dx: CGFloat(i) * stripMM.width, dy: 0), scale)
    }

    /// All photo windows, strip by strip (left strip's three first).
    public static func photoWindows(scale: CGFloat = 1) -> [CGRect] {
        (0..<stripCount).flatMap { i in (0..<photosPerStrip).map { photoWindow(strip: i, $0, scale: scale) } }
    }

    /// Strip `i`'s caption area, in px.
    public static func captionArea(strip i: Int, scale: CGFloat = 1) -> CGRect {
        px(captionAreaMM.offsetBy(dx: CGFloat(i) * stripMM.width, dy: 0), scale)
    }

    static func px(_ mm: CGRect, _ scale: CGFloat) -> CGRect {
        let k = pixelsPerMM * scale
        return CGRect(x: mm.minX * k, y: mm.minY * k, width: mm.width * k, height: mm.height * k)
    }

    /// Where an image of `size` goes to fill `rect` (aspect fill, centred; the overflow is cropped).
    public static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

/// Renders print sheets: per strip the artwork (scaled to fill the strip), then each photo
/// aspect-filled into its window. Without artwork the strip is white with the caption centred
/// in the caption area. Pure CoreGraphics/CoreText, sRGB; safe off the main thread.
public enum PrintSheet {
    /// Photos are downsampled to this on load (a window is 504 x 336 px), never decoded at 6000 px.
    public static let photoMaxPixel = 1200
    public static let jpegQuality = 0.92
    /// Empty windows in the preview.
    static let placeholderGray: CGFloat = 0.82
    static let captionGray: CGFloat = 0.25
    /// The largest / smallest caption size, in mm.
    static let captionMaxMM: CGFloat = 8
    static let captionMinMM: CGFloat = 1.5
    static let captionFont = "AvenirNext-Medium"

    public struct RenderError: Error, CustomStringConvertible {
        public var description: String
    }

    /// Strip artwork as loaded, with a warning for the print window (odd aspect, unreadable).
    public struct Artwork: @unchecked Sendable {
        public var image: CGImage?
        public var warning: String?
        public init(image: CGImage?, warning: String?) {
            self.image = image
            self.warning = warning
        }
    }

    /// Loads the strip artwork. A missing file is not an error (the caption is printed instead);
    /// an unreadable one or one that isn't 50:148 (within 2%) gives a warning. An odd aspect
    /// still renders, stretched to fill the strip.
    public static func loadArtwork(_ url: URL?) -> Artwork {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return Artwork(image: nil, warning: nil) }
        guard let img = ImageDecoding.downsample(url, maxPixel: 4096) else {
            return Artwork(image: nil, warning: "Couldn't read the artwork \(url.lastPathComponent); printing the caption instead.")
        }
        return Artwork(image: img, warning: artworkWarning(width: img.width, height: img.height))
    }

    /// nil when `width x height` is the strip's 50:148 aspect within 2%.
    public static func artworkWarning(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return "The artwork is empty." }
        let expected = PrintLayout.stripMM.width / PrintLayout.stripMM.height
        let ratio = (CGFloat(width) / CGFloat(height)) / expected
        if abs(ratio - 1) <= 0.02 { return nil }
        return "The artwork is \(width) x \(height) px, not the strip's 50:148 shape (600 x 1776 px), so it's stretched to fit."
    }

    /// Loads a photo for printing: downsampled with ImageIO, EXIF orientation applied.
    public static func loadPhoto(_ url: URL, maxPixel: Int = photoMaxPixel) -> CGImage? {
        ImageDecoding.downsample(url, maxPixel: maxPixel)
    }

    /// Renders a full-size sheet from three photo files.
    public static func render(photoURLs: [URL], artwork: CGImage?, caption: String) throws -> CGImage {
        let n = PrintLayout.photosPerStrip
        guard photoURLs.count == n else { throw RenderError(description: "A sheet needs exactly \(n) photos (got \(photoURLs.count)).") }
        let photos = try photoURLs.map { url in
            guard let img = loadPhoto(url) else { throw RenderError(description: "Couldn't read \(url.lastPathComponent).") }
            return img
        }
        guard let sheet = render(photos: photos, artwork: artwork, caption: caption) else {
            throw RenderError(description: "Couldn't render the sheet.")
        }
        return sheet
    }

    /// Renders a sheet at `scale` (1 = 1200 x 1776 px). A nil photo leaves a grey placeholder
    /// (the print window's preview before three are picked).
    public static func render(photos: [CGImage?], artwork: CGImage?, caption: String, scale: CGFloat = 1) -> CGImage? {
        let (w, h) = PrintLayout.sheetPixels(scale: scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // Layout rects are top-left; CoreGraphics is bottom-left.
        let height = CGFloat(h)
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<PrintLayout.stripCount {
            if let artwork {
                ctx.draw(artwork, in: flip(PrintLayout.stripRect(i, scale: scale)))
            } else {
                let area = PrintLayout.captionArea(strip: i, scale: scale)
                let inset = PrintLayout.captionInsetMM * PrintLayout.pixelsPerMM * scale
                drawCaption(caption, in: flip(area.insetBy(dx: inset, dy: inset)), scale: scale, ctx)
            }
            for k in 0..<PrintLayout.photosPerStrip {
                let window = flip(PrintLayout.photoWindow(strip: i, k, scale: scale))
                if k < photos.count, let photo = photos[k] {
                    ctx.saveGState()
                    ctx.clip(to: window)
                    ctx.draw(photo, in: PrintLayout.aspectFill(CGSize(width: photo.width, height: photo.height), in: window))
                    ctx.restoreGState()
                } else {
                    ctx.setFillColor(gray: placeholderGray, alpha: 1)
                    ctx.fill(window)
                }
            }
        }
        return ctx.makeImage()
    }

    /// Centres the caption's lines in `rect` (CoreGraphics coordinates), at the largest size up to
    /// `captionMaxMM` at which every line fits. Lines break only at "\n".
    static func drawCaption(_ text: String, in rect: CGRect, scale: CGFloat, _ ctx: CGContext) {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { !$0.isEmpty }) else { return }
        let mm = PrintLayout.pixelsPerMM * scale
        let color = CGColor(gray: captionGray, alpha: 1)
        var size = captionMaxMM * mm
        var laidOut: (lines: [CTLine], lineHeight: CGFloat, ascent: CGFloat, descent: CGFloat) = ([], 0, 0, 0)
        while true {
            let font = CTFontCreateWithName(captionFont as CFString, size, nil)
            let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as [CFString: Any] as CFDictionary
            let ctLines = lines.map { CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, $0 as CFString, attrs)) }
            let widest = ctLines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
            let lineHeight = size * 1.25
            laidOut = (ctLines, lineHeight, CTFontGetAscent(font), CTFontGetDescent(font))
            if (widest <= rect.width && lineHeight * CGFloat(lines.count) <= rect.height) || size <= captionMinMM * mm { break }
            size *= 0.95
        }
        // Each line's glyphs are centred in its line box; the block of lines is centred in `rect`.
        let block = laidOut.lineHeight * CGFloat(laidOut.lines.count)
        let glyphs = laidOut.ascent + laidOut.descent
        var baseline = rect.midY + block / 2 - (laidOut.lineHeight - glyphs) / 2 - laidOut.ascent
        ctx.saveGState()
        ctx.textMatrix = .identity
        for line in laidOut.lines {
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: rect.midX - width / 2, y: baseline)
            CTLineDraw(line, ctx)
            baseline -= laidOut.lineHeight
        }
        ctx.restoreGState()
    }

    /// JPEG with 304.8 dpi metadata (12 px/mm), so the file says 100 x 148 mm.
    public static func jpegData(_ image: CGImage, quality: Double = jpegQuality) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let dpi = PrintLayout.pixelsPerMM * 25.4
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Renders three photos with the configured artwork / caption, as JPEG data.
    public static func renderJPEG(photoURLs: [URL], config: BoothConfig) throws -> Data {
        let art = loadArtwork(config.printTemplateURL)
        let sheet = try render(photoURLs: photoURLs, artwork: art.image, caption: config.printCaptionText)
        guard let jpeg = jpegData(sheet) else { throw RenderError(description: "Couldn't encode the sheet as JPEG.") }
        return jpeg
    }

    /// Saves a rendered sheet as `<directory>/print-YYYYMMDD-HHMMSS.jpg` (`-2`, `-3`, … on
    /// collisions). The local file is what gets printed.
    public static func save(_ jpeg: Data, in directory: URL, date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "print-" + LocalFolderPhotoSink.baseName(for: date)
        for n in 1...999 {
            let url = directory.appendingPathComponent(n == 1 ? "\(base).jpg" : "\(base)-\(n).jpg")
            if fm.fileExists(atPath: url.path) { continue }
            try jpeg.write(to: url, options: .atomic)
            return url
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: directory.path])
    }
}
