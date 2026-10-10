import Foundation

// Values verified against libgphoto2 camlibs/ptp2 (ptp.h, ptp.c, library.c, config.c),
// master as of 2026-10. Line references are to that checkout.

public enum PTPOperation {
    public static let getDeviceInfo: UInt16 = 0x1001
    public static let openSession: UInt16 = 0x1002
    public static let closeSession: UInt16 = 0x1003
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009

    /// ptp.h:702 PTP_OC_SONY_SDIO_Connect. Params (phase, 0, 0); data-in.
    public static let sonySDIOConnect: UInt16 = 0x9201
    /// ptp.h:706 PTP_OC_SONY_SDIO_GetExtDeviceInfo. ptp.c:4335 sends (0x12C, 1).
    public static let sonyGetExtDeviceInfo: UInt16 = 0x9202
    /// ptp.h:710 PTP_OC_SONY_SDIO_SetExtDevicePropValue ("SetControlDeviceA"). Param: propcode; data-out: value.
    public static let sonySetControlDeviceA: UInt16 = 0x9205
    /// ptp.h:713 PTP_OC_SONY_SDIO_ControlDevice ("SetControlDeviceB"). Param: propcode; data-out: value.
    public static let sonySetControlDeviceB: UInt16 = 0x9207
    /// ptp.h:715 PTP_OC_SONY_SDIO_GetAllExtDevicePropInfo.
    public static let sonyGetAllDevicePropData: UInt16 = 0x9209

    public static func name(_ code: UInt16) -> String {
        switch code {
        case getDeviceInfo: return "GetDeviceInfo"
        case openSession: return "OpenSession"
        case closeSession: return "CloseSession"
        case getObjectInfo: return "GetObjectInfo"
        case getObject: return "GetObject"
        case sonySDIOConnect: return "SDIOConnect"
        case sonyGetExtDeviceInfo: return "GetExtDeviceInfo"
        case sonySetControlDeviceA: return "SetControlDeviceA"
        case sonySetControlDeviceB: return "SetControlDeviceB"
        case sonyGetAllDevicePropData: return "GetAllDevicePropData"
        default: return "Op"
        }
    }
}

public enum PTPResponseCode {
    public static let ok: UInt16 = 0x2001
    public static let generalError: UInt16 = 0x2002
    public static let sessionNotOpen: UInt16 = 0x2003
    public static let operationNotSupported: UInt16 = 0x2005
    public static let parameterNotSupported: UInt16 = 0x2006
    public static let invalidObjectHandle: UInt16 = 0x2009
    public static let devicePropNotSupported: UInt16 = 0x200A
    public static let accessDenied: UInt16 = 0x200F
    public static let deviceBusy: UInt16 = 0x2019

    public static func name(_ code: UInt16) -> String {
        switch code {
        case ok: return "OK"
        case generalError: return "GeneralError"
        case sessionNotOpen: return "SessionNotOpen"
        case operationNotSupported: return "OperationNotSupported"
        case parameterNotSupported: return "ParameterNotSupported"
        case invalidObjectHandle: return "InvalidObjectHandle"
        case devicePropNotSupported: return "DevicePropNotSupported"
        case accessDenied: return "AccessDenied"
        case deviceBusy: return "DeviceBusy"
        default: return "Response"
        }
    }
}

public enum PTPEventCode {
    /// ptp.h:1351 PTP_EC_Sony_ObjectAdded
    public static let sonyObjectAdded: UInt16 = 0xC201
    /// ptp.h:1352
    public static let sonyObjectRemoved: UInt16 = 0xC202
    /// ptp.h:1353
    public static let sonyDevicePropChanged: UInt16 = 0xC203
    /// ptp.h:1354
    public static let sonyCapturedEvent: UInt16 = 0xC206

    public static func name(_ code: UInt16) -> String {
        switch code {
        case sonyObjectAdded: return "Sony.ObjectAdded"
        case sonyObjectRemoved: return "Sony.ObjectRemoved"
        case sonyDevicePropChanged: return "Sony.DevicePropChanged"
        case sonyCapturedEvent: return "Sony.CapturedEvent"
        default: return "Event"
        }
    }
}

public enum PTPDataType {
    public static let int8: UInt16 = 0x0001
    public static let uint8: UInt16 = 0x0002
    public static let int16: UInt16 = 0x0003
    public static let uint16: UInt16 = 0x0004
    public static let int32: UInt16 = 0x0005
    public static let uint32: UInt16 = 0x0006
    public static let int64: UInt16 = 0x0007
    public static let uint64: UInt16 = 0x0008
    public static let int128: UInt16 = 0x0009
    public static let uint128: UInt16 = 0x000A
    public static let string: UInt16 = 0xFFFF
}

public enum SonyProperty {
    // Standard PTP properties. On a Sony body in PC Remote mode they are read through
    // GetAllDevicePropData and written with SetControlDeviceA like the vendor ones.

    /// ptp.h:1945 standard WhiteBalance, uint16. config.c:1454-1495 (`whitebalance[]`, with the
    /// PTP_VENDOR_SONY rows): 2 Auto, 4 Daylight, 6 Tungsten, 7 Flash, 0x8010 Cloudy, 0x8011 Shade.
    public static let whiteBalance: UInt16 = 0x5005
    /// ptp.h:1947 standard FNumber, uint16: f-number × 100 (800 = f/8). Values depend on lens/zoom.
    public static let fNumber: UInt16 = 0x5007
    /// ptp.h:1950 standard FocusMode, uint16. config.c:6746-6765 (`focusmodes[]`): 1 Manual,
    /// 2 Automatic (AF-S on Sony), 0x8004 AF-C, 0x8005 AF-A, 0x8006 DMF.
    public static let focusMode: UInt16 = 0x500A
    /// ptp.h:1952 standard FlashMode, uint16. config.c:5087-5115 (`flash_mode[]`): 1 Auto,
    /// 2 Off, 3 Fill, 0x8001 Slow Sync, 0x8003 Rear Curtain Sync (Sony rows).
    public static let flashMode: UInt16 = 0x500C
    /// ptp.h:1954 standard ExposureProgramMode; uint32 on Sony protocol 3 (config.c:12224).
    /// config.c:4492-4557 (`sony_exposure_program_32_modes[]`): 0x1 M, 0x10002 P, 0x20003 A,
    /// 0x30004 S, 0x48000 Intelligent Auto, 0x48001 Superior Auto, 0x7805x Movie.
    public static let exposureProgramMode: UInt16 = 0x500E
    /// ptp.h:1956 standard ExposureBiasCompensation, int16: EV × 1000 in 1/3 steps
    /// (…, 700, 300, 0, -300, …). config.c:2011 `_get_ExpCompensation` divides by 1000.
    public static let exposureBiasCompensation: UInt16 = 0x5010

    /// ptp.h:3520 PTP_DPC_SONY_DPCCompensation: flash compensation, int16, EV × 1000 like
    /// 0x5010 (not in config.c; encoding verified on the ZV-E10).
    public static let flashCompensation: UInt16 = 0xD200
    /// ptp.h:3523; uint32 (numerator << 16) | denominator, 0 = Bulb (config.c:5979-6020).
    public static let shutterSpeed: UInt16 = 0xD20D
    /// ptp.h:3528, config.c:7782 — 1 unlocked, 2 locked, 3 no focus, 5 tracking acquire,
    /// 6 tracking focused, 7 tracking no focus.
    public static let focusFound: UInt16 = 0xD213
    /// ptp.h:3530 — >= 0x8000 means a captured object is ready at 0xFFFFC001.
    public static let objectInMemory: UInt16 = 0xD215
    /// ptp.h:3533 PTP_DPC_SONY_BatteryLevel, int8 range -1...100: percent, -1 = unknown
    /// (config.c:8182 `_get_SONY_BatteryLevel`).
    public static let batteryLevel: UInt16 = 0xD218
    /// ptp.h:3538 PTP_DPC_SONY_ISO, uint32 (config.c:12082). Low 24 bits are the ISO,
    /// 0xFFFFFF = Auto; the top byte flags extended ISO / multi-frame NR (config.c:3674).
    public static let iso: UInt16 = 0xD21E
    /// ptp.h:3540
    public static let liveViewStatus: UInt16 = 0xD221
    /// ptp.h:3541
    public static let stillImageStoreDestination: UInt16 = 0xD222
    /// ptp.h:3552, config.c:7763 — uint8: 1 = On, 2 = Off. Writable only in an exposure mode
    /// that exposes it (M/A/S/P on the ZV-E10; display-only in Intelligent Auto).
    public static let liveViewSettingEffect: UInt16 = 0xD231
    /// ptp.h:3578 — library.c:761 sets int8 1 ("application") right after the handshake.
    public static let priorityMode: UInt16 = 0xD25A
    /// ptp.h:3605 half-press: 2 = press, 1 = release (uint16, via SetControlDeviceB).
    public static let shutterHalfRelease: UInt16 = 0xD2C1
    /// ptp.h:3606 full-press: 2 = press, 1 = release (uint16, via SetControlDeviceB).
    public static let shutterRelease: UInt16 = 0xD2C2
}

public enum SonyHandle {
    /// library.c:5052 — captured image in camera RAM.
    public static let capturedImage: UInt32 = 0xFFFF_C001
    /// library.c:3914 — live-view frame.
    public static let liveView: UInt32 = 0xFFFF_C002
}

public enum SonyProtocol {
    /// ptp.c:4304 SONY_PROTOCOL_2_00 ("models earlier than 2020").
    public static let version2: UInt32 = 0x00C8
    /// ptp.c:4311 SONY_PROTOCOL_3_00 ("2020 models or later"). Cameras that don't
    /// support it answer with their max version.
    public static let version3: UInt32 = 0x012C
}
