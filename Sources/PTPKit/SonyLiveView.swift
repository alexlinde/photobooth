import Foundation

public enum SonyLiveView {
    /// Extracts the JPEG from a live-view GetObject payload.
    ///
    /// libgphoto2 (library.c:3950) treats the first u32 as the offset to the JPEG and uses it
    /// when it points at an FFD8 SOI marker; otherwise it falls back to scanning. The JPEG is
    /// trimmed at the last FFD9 EOI marker.
    public static func extractJPEG(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return nil }

        var start: Int?
        let offset = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        if offset + 1 < bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] == 0xD8 {
            start = offset
        } else {
            for i in 0..<(bytes.count - 1) where bytes[i] == 0xFF && bytes[i + 1] == 0xD8 {
                start = i
                break
            }
        }
        guard let s = start else { return nil }

        var j = bytes.count - 1
        while j > s + 1 {
            if bytes[j - 1] == 0xFF, bytes[j] == 0xD9 {
                return Data(bytes[s...j])
            }
            j -= 1
        }
        return nil
    }
}
