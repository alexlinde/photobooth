import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import BoothCore

// MARK: - Helpers

private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, width: Int = 160, height: Int = 90) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// RGBA bytes of `image` in sRGB; row 0 is the top.
private struct Pixels {
    let width: Int, height: Int
    let data: [UInt8]
    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var d = [UInt8](repeating: 0, count: width * height * 4)
        d.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        data = d
    }
    /// (r, g, b) at a top-left-origin point.
    subscript(_ p: CGPoint) -> (Int, Int, Int) {
        let i = (Int(p.y) * width + Int(p.x)) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
}

private func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int = 12) -> Bool {
    abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
}

private func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("print-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

// MARK: - Geometry

@Test func sheetIsTwelvePixelsPerMillimetre() {
    #expect(PrintLayout.sheetPixels() == (1200, 1776))
    #expect(PrintLayout.sheetPixels(scale: 0.5) == (600, 888))
    #expect(PrintLayout.stripRect(0) == CGRect(x: 0, y: 0, width: 600, height: 1776))
    #expect(PrintLayout.stripRect(1) == CGRect(x: 600, y: 0, width: 600, height: 1776))
}

@Test func photoWindowsInPixels() {
    let w = PrintLayout.photoWindows()
    #expect(w.count == 6)
    #expect(w[0] == CGRect(x: 48, y: 48, width: 504, height: 336))
    #expect(w[1] == CGRect(x: 48, y: 420, width: 504, height: 336))
    #expect(w[2] == CGRect(x: 48, y: 792, width: 504, height: 336))
    #expect(w[3] == CGRect(x: 648, y: 48, width: 504, height: 336))
    #expect(w[5] == CGRect(x: 648, y: 792, width: 504, height: 336))
    #expect(PrintLayout.captionArea(strip: 1) == CGRect(x: 600, y: 1128, width: 600, height: 648))
}

@Test func photoWindowsAreThreeByTwoInsideTheirStripAndDontOverlap() {
    let windows = PrintLayout.photoWindows()
    for (n, r) in windows.enumerated() {
        let strip = PrintLayout.stripRect(n / PrintLayout.photosPerStrip)
        #expect(strip.contains(r), "window \(n) \(r) outside strip \(strip)")
        #expect(abs(r.width / r.height - 1.5) < 0.0001, "window \(n) aspect \(r.width / r.height)")
        #expect(r.maxY <= PrintLayout.captionArea(strip: 0).minY, "window \(n) runs into the caption")
        for (m, s) in windows.enumerated() where m != n {
            #expect(!r.intersects(s), "windows \(n) and \(m) overlap")
        }
    }
}

@Test func aspectFillCoversTheWindowCentred() {
    let window = CGRect(x: 48, y: 48, width: 504, height: 336)
    let r = PrintLayout.aspectFill(CGSize(width: 6000, height: 3376), in: window)
    #expect(abs(r.height - 336) < 0.01 && r.width > 504)
    #expect(abs(r.midX - window.midX) < 0.01 && abs(r.midY - window.midY) < 0.01)
    let tall = PrintLayout.aspectFill(CGSize(width: 400, height: 600), in: window)
    #expect(abs(tall.width - 504) < 0.01 && tall.height > 336)
}

// MARK: - Rendering

@Test func photosLandInTheirWindowsOnBothStrips() throws {
    let red = solid(1, 0, 0), green = solid(0, 1, 0), blue = solid(0, 0, 1)
    let sheet = try #require(PrintSheet.render(photos: [red, green, blue], artwork: nil, caption: "Test"))
    #expect(sheet.width == 1200 && sheet.height == 1776)
    let px = Pixels(sheet)
    let expected = [(255, 0, 0), (0, 255, 0), (0, 0, 255)]
    for i in 0..<2 {
        for k in 0..<3 {
            let w = PrintLayout.photoWindow(strip: i, k)
            #expect(near(px[center(w)], expected[k]), "strip \(i) window \(k): \(px[center(w)])")
            // Just inside each corner too (the photo fills the whole window).
            #expect(near(px[CGPoint(x: w.minX + 2, y: w.minY + 2)], expected[k]))
            #expect(near(px[CGPoint(x: w.maxX - 3, y: w.maxY - 3)], expected[k]))
            // And not outside it.
            #expect(near(px[CGPoint(x: w.minX - 3, y: w.midY)], (255, 255, 255)))
        }
    }
}

@Test func noArtworkMeansWhiteStripWithCaption() throws {
    let photo = solid(0.5, 0.5, 0.5)
    let sheet = try #require(PrintSheet.render(photos: [photo, photo, photo], artwork: nil, caption: "Anna & Ben\nOctober 10"))
    let px = Pixels(sheet)
    for i in 0..<2 {
        let area = PrintLayout.captionArea(strip: i)
        // The caption inset is blank.
        #expect(near(px[CGPoint(x: area.minX + 10, y: area.minY + 10)], (255, 255, 255)))
        #expect(near(px[CGPoint(x: area.maxX - 10, y: area.maxY - 10)], (255, 255, 255)))
        // Some dark grey text somewhere in the area.
        var dark = 0
        for y in stride(from: Int(area.minY), to: Int(area.maxY), by: 2) {
            for x in stride(from: Int(area.minX), to: Int(area.maxX), by: 2) where px[CGPoint(x: x, y: y)].0 < 128 { dark += 1 }
        }
        #expect(dark > 200, "strip \(i): \(dark) caption pixels")
    }
}

@Test func artworkFillsTheStripUnderThePhotos() throws {
    let art = solid(1, 1, 0, width: 600, height: 1776)
    let photo = solid(0, 0, 1)
    let sheet = try #require(PrintSheet.render(photos: [photo, photo, photo], artwork: art, caption: "ignored"))
    let px = Pixels(sheet)
    for i in 0..<2 {
        #expect(near(px[center(PrintLayout.captionArea(strip: i))], (255, 255, 0)))
        #expect(near(px[CGPoint(x: PrintLayout.stripRect(i).minX + 5, y: 5)], (255, 255, 0)))
        #expect(near(px[center(PrintLayout.photoWindow(strip: i, 1))], (0, 0, 255)))
    }
}

@Test func missingPhotosArePlaceholdersAtPreviewScale() throws {
    let sheet = try #require(PrintSheet.render(photos: [solid(1, 0, 0)], artwork: nil, caption: "x", scale: 0.5))
    #expect(sheet.width == 600 && sheet.height == 888)
    let px = Pixels(sheet)
    #expect(near(px[center(PrintLayout.photoWindow(strip: 1, 0, scale: 0.5))], (255, 0, 0)))
    let g = Int(PrintSheet.placeholderGray * 255)
    #expect(near(px[center(PrintLayout.photoWindow(strip: 0, 2, scale: 0.5))], (g, g, g)))
}

@Test func artworkAspectWarning() {
    #expect(PrintSheet.artworkWarning(width: 600, height: 1776) == nil)
    #expect(PrintSheet.artworkWarning(width: 591, height: 1748) == nil)  // 300 dpi export
    #expect(PrintSheet.artworkWarning(width: 1200, height: 3552) == nil)
    #expect(PrintSheet.artworkWarning(width: 600, height: 1600) != nil)
    #expect(PrintSheet.artworkWarning(width: 1776, height: 600) != nil)
}

@Test func artworkLoadingReportsOddShapesAndToleratesMissingFiles() throws {
    let dir = tempDir()
    #expect(PrintSheet.loadArtwork(dir.appendingPathComponent("nope.png")).image == nil)
    #expect(PrintSheet.loadArtwork(dir.appendingPathComponent("nope.png")).warning == nil)
    let odd = dir.appendingPathComponent("odd.jpg")
    try #require(PrintSheet.jpegData(solid(1, 1, 1, width: 600, height: 1200))).write(to: odd)
    let art = PrintSheet.loadArtwork(odd)
    #expect(art.image != nil && art.warning != nil)
    let bad = dir.appendingPathComponent("bad.png")
    try Data("not an image".utf8).write(to: bad)
    #expect(PrintSheet.loadArtwork(bad).image == nil && PrintSheet.loadArtwork(bad).warning != nil)
}

@Test func photoLoadingHonoursEXIFOrientation() throws {
    // Stored 60 x 40, left half red, right half blue, EXIF orientation 6 (rotate 90° clockwise to
    // display): it should load as 40 x 60 with red on top.
    let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
    ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 30, y: 0, width: 30, height: 40))
    let url = tempDir().appendingPathComponent("rotated.jpg")
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))

    let img = try #require(PrintSheet.loadPhoto(url))
    #expect(img.width == 40 && img.height == 60)
    let px = Pixels(img)
    #expect(near(px[CGPoint(x: 20, y: 10)], (255, 0, 0), tolerance: 40))
    #expect(near(px[CGPoint(x: 20, y: 50)], (0, 0, 255), tolerance: 40))
}

@Test func renderFromFilesAndSaveIntoPrints() throws {
    let dir = tempDir()
    let urls = try (0..<3).map { i -> URL in
        let u = dir.appendingPathComponent("2026101\(i)-120000.jpg")
        try #require(PrintSheet.jpegData(solid(0, 1, 0, width: 6000 / 10, height: 3376 / 10))).write(to: u)
        return u
    }
    var config = BoothConfig()
    config.printTemplate = ""
    let jpeg = try PrintSheet.renderJPEG(photoURLs: urls, config: config)
    let prints = dir.appendingPathComponent("prints")
    let date = Date(timeIntervalSince1970: 1_791_000_000)
    let a = try PrintSheet.save(jpeg, in: prints, date: date)
    let b = try PrintSheet.save(jpeg, in: prints, date: date)
    #expect(a.lastPathComponent.hasPrefix("print-") && a.pathExtension == "jpg")
    #expect(b.lastPathComponent == a.deletingPathExtension().lastPathComponent + "-2.jpg")
    let src = try #require(CGImageSourceCreateWithURL(a as CFURL, nil))
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    #expect(props[kCGImagePropertyPixelWidth] as? Int == 1200)
    #expect(props[kCGImagePropertyPixelHeight] as? Int == 1776)
    #expect(throws: PrintSheet.RenderError.self) { try PrintSheet.renderJPEG(photoURLs: Array(urls.prefix(2)), config: config) }
    #expect(throws: PrintSheet.RenderError.self) {
        try PrintSheet.renderJPEG(photoURLs: [urls[0], urls[1], dir.appendingPathComponent("gone.jpg")], config: config)
    }
}

// MARK: - Config

@Test func printConfigKeys() {
    let d = BoothConfig()
    #expect(d.printer == "" && d.printMedia == "Postcard.Fullbleed" && d.printCaption == "")
    #expect(d.printTemplateURL == d.outputRootURL.appendingPathComponent("print-strip.png"))
    #expect(d.printCaptionText == d.eventName)
    #expect(d.printsDirectoryURL == d.eventDirectoryURL.appendingPathComponent("prints", isDirectory: true))

    let json = #"{"printer": "Canon_CP910", "printTemplate": "/tmp/art.png", "printCaption": "A\nB", "outputRoot": "/tmp/pb"}"#
    let (c, e) = ConfigLoader.decode(Data(json.utf8))
    #expect(e == nil)
    #expect(c.printer == "Canon_CP910" && c.printCaptionText == "A\nB")
    #expect(c.printTemplateURL?.path == "/tmp/art.png")
    var r = c
    r.printTemplate = "art/strip.png"
    #expect(r.printTemplateURL?.path == "/tmp/pb/art/strip.png")
    r.printTemplate = ""
    #expect(r.printTemplateURL == nil)

    let (back, e2) = ConfigLoader.decode(c.encodedJSON())
    #expect(e2 == nil && back == c)
    let (bad, e3) = ConfigLoader.decode(Data(#"{"printMedia": " "}"#.utf8))
    #expect(e3 != nil && bad == BoothConfig())
}

// MARK: - CUPS parsing

private let idle = """
printer Canon_CP910 is idle.  enabled since Sat Oct 10 11:21:55 2026
\tForm mounted:
\tContent types: any
\tPrinter types: unknown
\tDescription: Canon CP910
\tAlerts: none
\tLocation: \n\tConnection: direct
"""

private let waitingForPaper = """
printer Canon_CP910 now printing Canon_CP910-47.  enabled since Sat Oct 10 11:18:07 2026
\tWaiting for job to complete.
\tForm mounted:
\tContent types: any
\tDescription: Canon CP910
\tAlerts: cups-waiting-for-job-completed media-empty-error media-needed
\tLocation:
"""

private let looking = """
printer Canon_CP910 now printing Canon_CP910-48.  enabled since Sat Oct 10 11:30:00 2026
\tLooking for printer.
\tForm mounted:
\tAlerts: none
"""

private let stopped = """
printer Canon_CP910 disabled since Sat Oct 10 11:40:00 2026 -
\tThe printer is not responding.
\tForm mounted:
\tAlerts: offline-report
"""

@Test func parsesPrinterStatus() throws {
    let a = try #require(PrintQueues.parseStatus(idle, printer: "Canon_CP910"))
    #expect(a.state == .idle && a.message == nil && a.alerts.isEmpty && a.activeJob == nil)

    let b = try #require(PrintQueues.parseStatus(waitingForPaper, printer: "Canon_CP910"))
    #expect(b.state == .printing && b.activeJob == "Canon_CP910-47")
    #expect(b.message == "Waiting for job to complete.")
    #expect(b.alerts == ["cups-waiting-for-job-completed", "media-empty-error", "media-needed"])

    let c = try #require(PrintQueues.parseStatus(looking, printer: "Canon_CP910"))
    #expect(c.isSearching && c.message == "Looking for printer.")

    let d = try #require(PrintQueues.parseStatus(stopped, printer: "Canon_CP910"))
    #expect(d.state == .stopped && d.message == "The printer is not responding." && d.alerts == ["offline-report"])

    #expect(PrintQueues.parseStatus(idle, printer: "Canon") == nil)
    #expect(PrintQueues.parseStatus("lpstat: Invalid destination name in list \"X\".", printer: "X") == nil)
}

@Test func parsesJobsDestinationsAndRequestIDs() {
    let jobs = PrintQueues.parseJobs("""
    Canon_CP910-47          alexlinde         6427648   Sat Oct 10 11:18:07 2026
    Canon_CP910-48          alexlinde         6431000   Sat Oct 10 11:19:30 2026
    """)
    #expect(jobs.map(\.id) == ["Canon_CP910-47", "Canon_CP910-48"])
    #expect(jobs[0].user == "alexlinde" && jobs[0].bytes == 6427648 && jobs[0].submitted == "Sat Oct 10 11:18:07 2026")
    #expect(PrintQueues.parseJobs("").isEmpty)

    #expect(PrintQueues.parseDestinations("Brother_HL_L2460DW\nCanon_CP910\n") == ["Brother_HL_L2460DW", "Canon_CP910"])
    #expect(PrintQueues.parseDestinations("printer Canon_CP910 is idle.  enabled since Sat\n\tLooking for printer.\n") == ["Canon_CP910"])

    #expect(PrintQueues.parseRequestID("request id is Canon_CP910-48 (1 file(s))\n") == "Canon_CP910-48")
    #expect(PrintQueues.parseRequestID("lp: error") == nil)
}

@Test func autoPicksTheSelphy() {
    #expect(PrintQueues.autoPick(["Brother_HL_L2460DW", "Canon_CP910", "Canon_MF750C_Series"]) == "Canon_CP910")
    #expect(PrintQueues.autoPick(["Office", "Canon SELPHY CP1500"]) == "Canon SELPHY CP1500")
    #expect(PrintQueues.autoPick(["Canon_MF750C_Series", "Sinfonia_CHC_S1245___imac"]) == nil)
    #expect(PrintQueues.autoPick([]) == nil)
}

@Test func attendantWording() throws {
    let paper = try #require(PrintQueues.parseStatus(waitingForPaper, printer: "Canon_CP910"))
    #expect(PrintQueues.attention(paper, printer: "Canon_CP910", searchingFor: 0) == PrinterAttention(PrintQueues.paperText, .warning))

    let ink = PrinterStatus(name: "P", state: .printing, alerts: ["marker-supply-empty-error"])
    #expect(PrintQueues.attention(ink, printer: "P", searchingFor: 0).text == PrintQueues.inkText)
    let ribbon = PrinterStatus(name: "P", state: .printing, alerts: ["ribbon-empty"])
    #expect(PrintQueues.attention(ribbon, printer: "P", searchingFor: 0).text == PrintQueues.inkText)

    let search = try #require(PrintQueues.parseStatus(looking, printer: "Canon_CP910"))
    #expect(PrintQueues.attention(search, printer: "Canon_CP910", searchingFor: 5).level == .ready)
    #expect(PrintQueues.attention(search, printer: "Canon_CP910", searchingFor: 25) == PrinterAttention(PrintQueues.unreachableText, .problem))
    let down = try #require(PrintQueues.parseStatus(stopped, printer: "Canon_CP910"))
    #expect(PrintQueues.attention(down, printer: "Canon_CP910", searchingFor: 0).text == PrintQueues.unreachableText)

    let odd = PrinterStatus(name: "P", state: .idle, message: "Hmm.", alerts: ["cover-open"])
    #expect(PrintQueues.attention(odd, printer: "P", searchingFor: 0) == PrinterAttention("Printer reports: cover-open (Hmm.)", .warning))

    let ready = try #require(PrintQueues.parseStatus(idle, printer: "Canon_CP910"))
    #expect(PrintQueues.attention(ready, printer: "Canon_CP910", searchingFor: 0) == PrinterAttention("Ready", .ready))
    #expect(PrintQueues.attention(nil, printer: "Gone", searchingFor: 0).level == .problem)
    #expect(PrintQueues.attention(nil, printer: nil, searchingFor: 0).level == .problem)
}
