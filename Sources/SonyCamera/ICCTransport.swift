import Foundation
import ImageCaptureCore
import PTPKit

/// PTP over ImageCaptureCore's pass-through (`requestSendPTPCommand`). We never claim the
/// USB interface ourselves, so there is no fight with `ptpcamerad`.
///
/// All ImageCaptureCore delegate callbacks arrive on the main thread; this type is main-actor
/// isolated to match.
@MainActor
public final class ICCTransport: NSObject, PTPTransport {
    public typealias Logger = @MainActor (String) -> Void

    private let browser = ICDeviceBrowser()
    private var cameras: [ICCameraDevice] = []
    private var device: ICCameraDevice?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var cameraWaiters: [CheckedContinuation<ICCameraDevice?, Never>] = []
    private var transactionID: UInt32 = 1

    public private(set) var isSessionOpen = false
    public var log: Logger = { print($0) }
    /// Logs every command/response in hex when true.
    public var traceTransactions = true
    public var onEvent: (@MainActor (PTPEvent) -> Void)?
    public var onDisconnect: (@MainActor () -> Void)?

    public var deviceName: String? { device?.name }

    public override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
    }

    // MARK: - Discovery

    /// Starts browsing and returns the first camera that accepts PTP pass-through.
    public func waitForCamera(timeout: Duration = .seconds(10)) async throws -> ICCameraDevice {
        if !browser.isBrowsing { browser.start() }
        if let c = cameras.first(where: Self.acceptsPTP) { return c }

        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.cameraWaiters.forEach { $0.resume(returning: nil) }
            self.cameraWaiters.removeAll()
        }
        defer { timer.cancel() }
        guard let cam = await withCheckedContinuation({ cameraWaiters.append($0) }) else {
            throw PTPError.noCameraFound
        }
        return cam
    }

    nonisolated private static func acceptsPTP(_ d: ICCameraDevice) -> Bool {
        d.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
    }

    // MARK: - Session

    public func openSession(_ camera: ICCameraDevice, timeout: Duration = .seconds(10)) async throws {
        if isSessionOpen { closeSession() }
        camera.delegate = self
        device = camera
        transactionID = 1

        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resumeOpen(.failure(PTPError.timeout("the camera session to open")))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            openContinuation = c
            camera.requestOpenSession()
        }
        isSessionOpen = true
    }

    public func closeSession() {
        isSessionOpen = false
        device?.requestCloseSession()
        device = nil
    }

    private func resumeOpen(_ result: Result<Void, Error>) {
        let c = openContinuation
        openContinuation = nil
        c?.resume(with: result)
    }

    // MARK: - Transactions

    public func send(_ code: UInt16, parameters: [UInt32], outData: Data?) async throws -> PTPResponse {
        try await send(code, parameters: parameters, outData: outData, timeout: .seconds(10))
    }

    public func send(_ code: UInt16, parameters: [UInt32], outData: Data?, timeout: Duration) async throws -> PTPResponse {
        guard let device, isSessionOpen else { throw PTPError.notConnected }
        let tid = transactionID
        transactionID &+= 1
        let command = PTPCodec.command(code: code, transactionID: tid, parameters: parameters)
        let label = "\(PTPOperation.name(code))(\(hex16(code)))"
        if traceTransactions {
            log("→ \(label) params=\(parameters.map(hex32)) cmd=\(hexPreview(command))"
                + (outData.map { " out=\(hexPreview($0))" } ?? ""))
        }

        let once = OnceContinuation<(Data, Data)>()
        let timer = Task {
            try? await Task.sleep(for: timeout)
            once.resume(throwing: PTPError.timeout(label))
        }
        defer { timer.cancel() }

        let (first, second) = try await withCheckedThrowingContinuation { c in
            once.set(c)
            device.requestSendPTPCommand(command, outData: outData) { a, b, error in
                if let error { once.resume(throwing: error) } else { once.resume(returning: (a, b)) }
            }
        }

        // The block's two Data arguments are (data-in, response container). Identify the
        // response container by content in case that order ever differs.
        let parsed: (code: UInt16, transactionID: UInt32, parameters: [UInt32])
        let payload: Data
        if let p = PTPCodec.parseContainer(second, type: PTPContainerType.response) {
            parsed = p; payload = first
        } else if let p = PTPCodec.parseContainer(first, type: PTPContainerType.response) {
            parsed = p; payload = second
        } else {
            log("✗ \(label) unparseable reply: a=\(hexPreview(first)) b=\(hexPreview(second))")
            throw PTPError.badContainer("no response container in reply to \(label)")
        }
        let data = PTPCodec.stripDataHeader(payload)
        if traceTransactions {
            log("← \(label) \(PTPResponseCode.name(parsed.code))(\(hex16(parsed.code))) tid=\(parsed.transactionID)"
                + " params=\(parsed.parameters.map(hex32)) data=\(hexPreview(data, limit: 32))"
                + (data.count != payload.count ? " [stripped \(payload.count - data.count)-byte header]" : ""))
        }
        return PTPResponse(code: parsed.code, transactionID: parsed.transactionID,
                           parameters: parsed.parameters, data: data)
    }
}

/// Resumes a checked continuation at most once (completion vs. timeout race).
final class OnceContinuation<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let p = pending {
            pending = nil
            lock.unlock()
            c.resume(with: p)
        } else {
            continuation = c
            lock.unlock()
        }
    }

    func resume(returning v: T) { finish(.success(v)) }
    func resume(throwing e: Error) { finish(.failure(e)) }

    private func finish(_ r: Result<T, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(with: r)
        } else {
            pending = r
            lock.unlock()
        }
    }
}

// MARK: - ICDeviceBrowserDelegate

extension ICCTransport: ICDeviceBrowserDelegate {
    nonisolated public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        onMain { [self] in
            guard let cam = device as? ICCameraDevice else { return }
            log("browser: found \(cam.name ?? "?") (PTP pass-through: \(Self.acceptsPTP(cam)))")
            if !cameras.contains(where: { $0 === cam }) { cameras.append(cam) }
            if Self.acceptsPTP(cam), !cameraWaiters.isEmpty {
                cameraWaiters.forEach { $0.resume(returning: cam) }
                cameraWaiters.removeAll()
            }
        }
    }

    nonisolated public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        onMain { [self] in
            log("browser: removed \(device.name ?? "?")")
            cameras.removeAll { $0 === device }
            handleRemoval(of: device)
        }
    }

    private func handleRemoval(of d: ICDevice) {
        guard d === device else { return }
        device = nil
        isSessionOpen = false
        onDisconnect?()
    }
}

// MARK: - ICCameraDeviceDelegate

extension ICCTransport: ICCameraDeviceDelegate {
    nonisolated public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        onMain { [self] in
            log("session opened\(error.map { " with error: \($0)" } ?? "")")
            resumeOpen(error.map { .failure($0) } ?? .success(()))
        }
    }

    nonisolated public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        onMain { [self] in isSessionOpen = false }
    }

    nonisolated public func didRemove(_ device: ICDevice) {
        onMain { [self] in handleRemoval(of: device) }
    }

    nonisolated public func device(_ device: ICDevice, didEncounterError error: Error?) {
        onMain { [self] in log("device error: \(String(describing: error))") }
    }

    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        onMain { [self] in
            guard let ev = PTPCodec.parseEvent(eventData) else {
                log("⚡ unparseable event \(hexPreview(eventData))")
                return
            }
            if traceTransactions { log("⚡ \(ev)") }
            onEvent?(ev)
        }
    }

    nonisolated public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        onMain { [self] in log("device ready (catalog complete)") }
    }

    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}
    nonisolated public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
                                         for item: ICCameraItem, error: Error?) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                                         for item: ICCameraItem, error: Error?) {}
}

/// ImageCaptureCore calls most delegate methods on the main thread but delivers PTP events
/// on a private queue. Funnel everything onto the main actor, preserving order.
private func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}
