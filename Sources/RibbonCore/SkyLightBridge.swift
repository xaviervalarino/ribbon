import Foundation
import CoreGraphics

/// Pure Swift dynamic linker bridge for private SkyLight / CoreGraphics SPIs.
///
/// Enables zero-latency window translation directly in WindowServer GPU memory
/// without sending blocking Mach IPC messages to target application processes.
public final class SkyLightBridge: @unchecked Sendable {
    public static let shared = SkyLightBridge()
    private let handle: UnsafeMutableRawPointer?

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias MoveWindowFn = @convention(c) (Int32, CGWindowID, UnsafePointer<CGPoint>) -> Int32
    private typealias UpdateFn = @convention(c) (Int32) -> Int32

    private let _cgsDefaultConnection: ConnectionFn?
    private let _cgsMainConnectionID: ConnectionFn?
    private let _slsMoveWindowWithGroup: MoveWindowFn?
    private let _slsDisableUpdate: UpdateFn?
    private let _slsReenableUpdate: UpdateFn?

    public init() {
        self.handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        if let h = self.handle {
            self._cgsDefaultConnection = unsafeBitCast(dlsym(h, "_CGSDefaultConnection"), to: ConnectionFn?.self)
            self._cgsMainConnectionID = unsafeBitCast(dlsym(h, "CGSMainConnectionID"), to: ConnectionFn?.self)
            self._slsMoveWindowWithGroup = unsafeBitCast(dlsym(h, "SLSMoveWindowWithGroup"), to: MoveWindowFn?.self)
            self._slsDisableUpdate = unsafeBitCast(dlsym(h, "SLSDisableUpdate"), to: UpdateFn?.self)
            self._slsReenableUpdate = unsafeBitCast(dlsym(h, "SLSReenableUpdate"), to: UpdateFn?.self)
        } else {
            self._cgsDefaultConnection = nil
            self._cgsMainConnectionID = nil
            self._slsMoveWindowWithGroup = nil
            self._slsDisableUpdate = nil
            self._slsReenableUpdate = nil
        }
    }

    /// Default or main WindowServer connection ID for the current process.
    public var connectionID: Int32 {
        let cid = _cgsDefaultConnection?() ?? 0
        return cid != 0 ? cid : (_cgsMainConnectionID?() ?? 0)
    }

    /// Indicates whether the fast-path WindowServer translation symbol is loaded.
    public var isAvailable: Bool {
        return _slsMoveWindowWithGroup != nil
    }

    /// Moves a window directly in WindowServer compositing memory via Quartz coordinates.
    /// Returns true if WindowServer accepted the move, false if fallback is required.
    @discardableResult
    public func moveWindow(id: CGWindowID, to point: CGPoint) -> Bool {
        guard let moveFn = _slsMoveWindowWithGroup else { return false }
        var pt = point
        let cid = connectionID
        let err = moveFn(cid, id, &pt)
        return err == 0
    }

    /// Disables screen updates during batch translation and reenables them on scope exit.
    public func withBatchUpdates<R>(_ body: () throws -> R) rethrows -> R {
        let cid = connectionID
        if let disable = _slsDisableUpdate {
            _ = disable(cid)
        }
        defer {
            if let reenable = _slsReenableUpdate {
                _ = reenable(cid)
            }
        }
        return try body()
    }
}
