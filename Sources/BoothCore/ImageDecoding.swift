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

    /// A review decoder for `BoothController` that runs on a background thread.
    public static func reviewDecoder(maxPixel: Int) -> BoothController.ReviewDecoder {
        return { data in
            await Task.detached(priority: .userInitiated) { downsample(data, maxPixel: maxPixel) }.value
        }
    }
}
