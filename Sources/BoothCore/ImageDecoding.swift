import CoreGraphics
import Foundation
import ImageIO

public enum ImageDecoding {
    /// Decodes and downsamples a JPEG so its longest side is at most `maxPixel`, applying
    /// EXIF orientation. Call off the main thread (it is nonisolated and synchronous).
    static func downsample(_ jpeg: Data, maxPixel: Int) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, srcOpts) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// The same for a file, without reading it all into memory first.
    static func downsample(_ url: URL, maxPixel: Int) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Mean brightness (0–255) below which a strobe-lit photo counts as a missed flash. With the
    /// black backdrop good photos measure about 55–70; when the strobes don't fire, 0.
    public static let missedFlashThreshold = 8.0

    /// Mean luminance of a JPEG, 0–255, measured on a ~64 px thumbnail drawn into an 8-bit grey
    /// context. nil if it can't be decoded. Synchronous: call off the main thread.
    public static func meanLuminance(_ jpeg: Data, maxPixel: Int = 64) -> Double? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, srcOpts) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = thumb.width, h = thumb.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        var sum = 0
        for y in 0..<h {
            let row = bytes + y * ctx.bytesPerRow
            for x in 0..<w { sum += Int(row[x]) }
        }
        return Double(sum) / Double(w * h)
    }

    /// The strobes didn't fire: the frame is (near) black. Only meaningful with `lighting: strobes`.
    public static func isMissedFlash(meanLuminance: Double) -> Bool { meanLuminance < missedFlashThreshold }

    /// A review decoder for `BoothController` that runs on a background thread.
    public static func reviewDecoder(maxPixel: Int) -> BoothController.ReviewDecoder {
        return { data in
            await Task.detached(priority: .userInitiated) { downsample(data, maxPixel: maxPixel) }.value
        }
    }
}
