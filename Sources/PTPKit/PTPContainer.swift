import Foundation

/// PTP (ISO 15740) container types.
public enum PTPContainerType {
    public static let command: UInt16 = 1
    public static let data: UInt16 = 2
    public static let response: UInt16 = 3
    public static let event: UInt16 = 4
}

public enum PTPError: Error, CustomStringConvertible, Equatable {
    case truncated(needed: Int, available: Int)
    case badContainer(String)
    case deviceResponse(code: UInt16, operation: UInt16)
    case notConnected
    case unsupportedDataType(UInt16)
    case timeout(String)
    case handshakeFailed(String)
    case noCameraFound
    case captureFailed(String)

    public var description: String {
        switch self {
        case let .truncated(n, a): return "truncated PTP payload (needed \(n), had \(a))"
        case let .badContainer(why): return "malformed PTP container: \(why)"
        case let .deviceResponse(code, op):
            return "camera answered \(PTPResponseCode.name(code)) (\(hex16(code))) to \(PTPOperation.name(op)) (\(hex16(op)))"
        case .notConnected: return "no camera session open"
        case let .unsupportedDataType(t): return "unsupported PTP data type \(hex16(t))"
        case let .timeout(what): return "timed out waiting for \(what)"
        case let .handshakeFailed(why): return "Sony handshake failed: \(why)"
        case .noCameraFound: return "no camera found"
        case let .captureFailed(why): return "capture failed: \(why)"
        }
    }
}

public func hex16(_ v: UInt16) -> String { String(format: "0x%04X", v) }
public func hex32(_ v: UInt32) -> String { String(format: "0x%08X", v) }

/// Hex dump of the first `limit` bytes, for logs.
public func hexPreview(_ data: Data, limit: Int = 48) -> String {
    let shown = data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    return data.count > limit ? "\(shown) … (\(data.count) bytes)" : "\(shown) (\(data.count) bytes)"
}

/// Little-endian cursor over a PTP payload.
public struct PTPReader {
    private let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ data: Data, offset: Int = 0) {
        bytes = [UInt8](data)
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= n else { throw PTPError.truncated(needed: n, available: remaining) }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }

    public func peekU16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    public mutating func skip(_ n: Int) throws { _ = try take(n) }
    public mutating func u8() throws -> UInt8 { try take(1).first! }

    public mutating func u16() throws -> UInt16 {
        let b = Array(try take(2))
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    public mutating func u32() throws -> UInt32 {
        let b = Array(try take(4))
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    public mutating func u64() throws -> UInt64 {
        let lo = UInt64(try u32())
        return lo | (UInt64(try u32()) << 32)
    }

    /// PTP string: u8 character count (including NUL), then UTF-16LE code units.
    public mutating func string() throws -> String {
        let count = Int(try u8())
        var units: [UInt16] = []
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// PTP array: u32 element count followed by elements.
    public mutating func array<T>(_ element: (inout PTPReader) throws -> T) throws -> [T] {
        let count = Int(try u32())
        guard count <= remaining else {
            throw PTPError.badContainer("array length \(count) exceeds \(remaining) remaining bytes")
        }
        var out: [T] = []
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(try element(&self)) }
        return out
    }
}

/// Little-endian byte builder.
public struct PTPWriter {
    public private(set) var data = Data()
    public init() {}
    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
}

/// A decoded response (or event) container.
public struct PTPResponse: Equatable {
    public var code: UInt16
    public var transactionID: UInt32
    public var parameters: [UInt32]
    /// Data-phase payload (data-in), with any container header stripped.
    public var data: Data

    public init(code: UInt16, transactionID: UInt32 = 0, parameters: [UInt32] = [], data: Data = Data()) {
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
        self.data = data
    }

    public var isOK: Bool { code == PTPResponseCode.ok }
}

public struct PTPEvent: Equatable, CustomStringConvertible {
    public var code: UInt16
    public var transactionID: UInt32
    public var parameters: [UInt32]

    public var description: String {
        "\(PTPEventCode.name(code)) (\(hex16(code))) params=\(parameters.map(hex32))"
    }
}

/// Encoding and decoding of the containers exchanged with ImageCaptureCore.
public enum PTPCodec {
    /// Command container: length, type=1, code, transaction ID, params.
    public static func command(code: UInt16, transactionID: UInt32 = 0, parameters: [UInt32] = []) -> Data {
        precondition(parameters.count <= 5, "PTP allows at most 5 parameters")
        var w = PTPWriter()
        w.u32(UInt32(12 + parameters.count * 4))
        w.u16(PTPContainerType.command)
        w.u16(code)
        w.u32(transactionID)
        parameters.forEach { w.u32($0) }
        return w.data
    }

    /// Parses a container of the given type (response or event). Returns nil if the
    /// blob is not a well-formed container of that type.
    public static func parseContainer(_ data: Data, type expected: UInt16)
        -> (code: UInt16, transactionID: UInt32, parameters: [UInt32])?
    {
        guard data.count >= 12 else { return nil }
        var r = PTPReader(data)
        guard let length = try? r.u32(), let type = try? r.u16(),
              let code = try? r.u16(), let tid = try? r.u32(),
              type == expected, length >= 12, Int(length) <= data.count,
              (Int(length) - 12) % 4 == 0
        else { return nil }
        var params: [UInt32] = []
        for _ in 0..<((Int(length) - 12) / 4) {
            guard let p = try? r.u32() else { break }
            params.append(p)
        }
        return (code, tid, params)
    }

    public static func parseEvent(_ data: Data) -> PTPEvent? {
        parseContainer(data, type: PTPContainerType.event).map {
            PTPEvent(code: $0.code, transactionID: $0.transactionID, parameters: $0.parameters)
        }
    }

    /// Strips a data-container header if present; otherwise returns the input unchanged.
    public static func stripDataHeader(_ data: Data) -> Data {
        guard data.count >= 12 else { return data }
        var r = PTPReader(data)
        guard let length = try? r.u32(), let type = try? r.u16(),
              type == PTPContainerType.data, length >= 12, Int(length) == data.count
        else { return data }
        return data.subdata(in: data.startIndex + 12 ..< data.startIndex + Int(length))
    }
}
