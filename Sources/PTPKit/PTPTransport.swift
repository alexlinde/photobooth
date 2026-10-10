import Foundation

/// Sends one PTP transaction. Implemented over ImageCaptureCore in SonyCamera; can be
/// faked in tests with recorded fixtures.
public protocol PTPTransport: AnyObject {
    /// - Parameters:
    ///   - outData: data-out phase payload (for SetControlDevice*), or nil.
    /// - Returns: the response; `data` holds the data-in phase, header stripped.
    func send(_ code: UInt16, parameters: [UInt32], outData: Data?) async throws -> PTPResponse
}

extension PTPTransport {
    /// Sends and throws `PTPError.deviceResponse` on a non-OK response.
    @discardableResult
    public func transact(_ code: UInt16, _ parameters: [UInt32] = [], outData: Data? = nil) async throws -> PTPResponse {
        let r = try await send(code, parameters: parameters, outData: outData)
        guard r.isOK else { throw PTPError.deviceResponse(code: r.code, operation: code) }
        return r
    }
}
