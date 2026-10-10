import Foundation

/// A decoded PTP property value. Integers are kept as raw bit patterns plus signedness.
public enum PTPValue: Equatable, CustomStringConvertible {
    case int(Int64)
    case uint(UInt64)
    case string(String)
    case array([PTPValue])

    public var uint64: UInt64? {
        switch self {
        case let .uint(v): return v
        case let .int(v): return UInt64(bitPattern: v)
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case let .int(v): return "\(v)"
        case let .uint(v): return v > 9 ? "\(v) (0x\(String(v, radix: 16)))" : "\(v)"
        case let .string(s): return "\"\(s)\""
        case let .array(a): return "[\(a.map(\.description).joined(separator: ", "))]"
        }
    }

    /// Encodes `self` as a data-phase payload of the given PTP type.
    public func encoded(as type: UInt16) -> Data {
        var w = PTPWriter()
        let bits = uint64 ?? 0
        switch type {
        case PTPDataType.int8, PTPDataType.uint8: w.u8(UInt8(truncatingIfNeeded: bits))
        case PTPDataType.int16, PTPDataType.uint16: w.u16(UInt16(truncatingIfNeeded: bits))
        case PTPDataType.int32, PTPDataType.uint32: w.u32(UInt32(truncatingIfNeeded: bits))
        default: w.u64(bits)
        }
        return w.data
    }
}

extension PTPReader {
    public mutating func value(ofType type: UInt16) throws -> PTPValue {
        switch type {
        case PTPDataType.int8: return .int(Int64(Int8(bitPattern: try u8())))
        case PTPDataType.uint8: return .uint(UInt64(try u8()))
        case PTPDataType.int16: return .int(Int64(Int16(bitPattern: try u16())))
        case PTPDataType.uint16: return .uint(UInt64(try u16()))
        case PTPDataType.int32: return .int(Int64(Int32(bitPattern: try u32())))
        case PTPDataType.uint32: return .uint(UInt64(try u32()))
        case PTPDataType.int64: return .int(Int64(bitPattern: try u64()))
        case PTPDataType.uint64: return .uint(try u64())
        case PTPDataType.int128, PTPDataType.uint128:
            let lo = try u64(); _ = try u64()
            return .uint(lo)
        case PTPDataType.string: return .string(try string())
        default:
            if type & 0x4000 != 0 {
                let scalar = type & 0x3FFF
                return .array(try array { try $0.value(ofType: scalar) })
            }
            throw PTPError.unsupportedDataType(type)
        }
    }
}

/// One entry of Sony's GetAllDevicePropData blob.
public struct SonyPropertyDescriptor: Equatable {
    public enum Form: Equatable {
        case none
        case range(min: PTPValue, max: PTPValue, step: PTPValue)
        case enumeration([PTPValue])
    }

    public var code: UInt16
    public var dataType: UInt16
    public var getSet: UInt8
    /// 0 = greyed out, 1 = enabled, 2 = display only.
    public var isEnabled: UInt8
    public var defaultValue: PTPValue
    public var currentValue: PTPValue
    public var form: Form
}

public enum SonyPropertyParser {
    /// Parses the GetAllDevicePropData (0x9209) payload.
    ///
    /// Layout (ptp.c:4451, ptp-pack.c:740-910): u32 count, u32 reserved, then per property:
    /// u16 code, u16 type, u8 getSet, u8 isEnabled, default value, current value, u8 form flag,
    /// form data. Newer bodies may follow an enumeration with a second u16-counted list; it is
    /// detected (as libgphoto2 does) by the next u16 being < 0x200 rather than a property code.
    /// Parsing stops cleanly at the first entry it can't decode.
    public static func parse(_ data: Data) -> [UInt16: SonyPropertyDescriptor] {
        var out: [UInt16: SonyPropertyDescriptor] = [:]
        guard data.count > 8 else { return out }
        var r = PTPReader(data, offset: 8)
        while r.remaining > 6 {
            guard let d = try? parseOne(&r) else { break }
            out[d.code] = d
        }
        return out
    }

    static func parseOne(_ r: inout PTPReader) throws -> SonyPropertyDescriptor {
        let code = try r.u16()
        let type = try r.u16()
        let getSet = try r.u8()
        let enabled = try r.u8()
        let def = try r.value(ofType: type)
        let cur = try r.value(ofType: type)
        var form = SonyPropertyDescriptor.Form.none
        let flag = try r.u8()
        switch flag {
        case 0x01:
            form = .range(min: try r.value(ofType: type), max: try r.value(ofType: type),
                          step: try r.value(ofType: type))
        case 0x02:
            let n = Int(try r.u16())
            var values: [PTPValue] = []
            for _ in 0..<n { values.append(try r.value(ofType: type)) }
            form = .enumeration(values)
            // Secondary ("settable") list on newer bodies: replaces the first, like libgphoto2.
            if let next = r.peekU16(), next < 0x200 {
                let n2 = Int(try r.u16())
                var values2: [PTPValue] = []
                for _ in 0..<n2 { values2.append(try r.value(ofType: type)) }
                form = .enumeration(values2)
            }
        case 0x00:
            break
        default:
            throw PTPError.badContainer("unknown form flag \(flag) for \(hex16(code))")
        }
        return SonyPropertyDescriptor(code: code, dataType: type, getSet: getSet, isEnabled: enabled,
                                      defaultValue: def, currentValue: cur, form: form)
    }
}

public enum SonyExtDeviceInfo {
    /// Parses the GetExtDeviceInfo (0x9202) payload: u16 protocol version, then two
    /// PTP u16 arrays (properties, controls). ptp.c:4341-4359.
    public static func parse(_ data: Data) throws -> (version: UInt16, properties: [UInt16], controls: [UInt16]) {
        var r = PTPReader(data)
        let version = try r.u16()
        let props = try r.array { try $0.u16() }
        let controls = (try? r.array { try $0.u16() }) ?? []
        return (version, props, controls)
    }
}
