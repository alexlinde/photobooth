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

    /// A review decoder for `BoothController` that runs on a background thread.
    public static func reviewDecoder(maxPixel: Int) -> BoothController.ReviewDecoder {
        return { data in
            await Task.detached(priority: .userInitiated) { downsample(data, maxPixel: maxPixel) }.value
        }
    }
}

public enum JPEGOrientation {
    /// Rewrites the EXIF orientation of a JPEG to 1 (upright) without recompressing pixels.
    ///
    /// The booth camera is always mounted landscape, but the ZV-E10's tilt sensor tags shots
    /// as rotated (orientation 6) when the camera points up/down, so viewers — the review
    /// screen, Finder, Google Photos — would show them sideways. The guest framed the shot on
    /// the landscape live view, so upright is always right. Returns the input unchanged if
    /// it's already upright or can't be rewritten.
    public static func upright(_ jpeg: Data) -> Data {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let o = props[kCGImagePropertyOrientation] as? Int, o != 1,
              let type = CGImageSourceGetType(src)
        else { return jpeg }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type, 1, nil) else { return jpeg }
        let opts: [CFString: Any] = [
            kCGImageDestinationMergeMetadata: true,
            kCGImageDestinationOrientation: 1,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dst, src, opts as CFDictionary, &error) else {
            BoothLog.error(.storage, "Could not reset EXIF orientation \(o): \(error?.takeRetainedValue().localizedDescription ?? "?")")
            return jpeg
        }
        return out as Data
    }
}
