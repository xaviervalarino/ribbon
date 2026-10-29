import Foundation
import AppKit
import CoreGraphics

/// Pans the active Space's strip horizontally while a pan is held (`pan begin` to `pan end`), flushing position
/// updates at most every 8ms and snapping to the most visible column when the hold ends.
final class PanController {
    /// Pointer travel below this many points pans nothing, so key chords with a resting hand stay still.
    private static let deadZone: Double = 40
    /// Motion after a pause this long starts the dead zone over, so slow drift never adds up to a pan.
    private static let idleTimeoutNs: UInt64 = 300_000_000
    /// Holds expire 10s after `pan begin`, or 10s after a pan's last motion, so a lost `pan end`
    /// cannot leave pointer motion panning.
    private static let holdTimeoutNs: UInt64 = 10_000_000_000

    private weak var windowManager: WindowManager?
    private(set) var isPanning = false
    private var accumulatedDX = 0.0
    private var lastMotionTime: DispatchTime = .now()
    private var needsFlush = false
    private var flushCount = 0
    private var flushTimer: DispatchSourceTimer?

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    func resetIfIdle() {
        guard !isPanning else { return }
        accumulatedDX = 0
        lastMotionTime = .now()
    }

    func handleMotion(dx: Double) {
        guard !expireHoldIfNeeded() else { return }
        guard dx != 0, let wm = windowManager else { return }
        let now = DispatchTime.now()
        if !isPanning, now.uptimeNanoseconds - lastMotionTime.uptimeNanoseconds >= Self.idleTimeoutNs {
            accumulatedDX = 0
        }
        lastMotionTime = now
        accumulatedDX += dx
        guard abs(accumulatedDX) >= Self.deadZone else { return }

        let sID = wm.panningSpaceID ?? wm.currentActiveSpaceID()
        if !isPanning, let columns = wm.ribbons[sID]?.columns {
            // Cancelling replays deferred AX events, which edit the ribbon, so it runs before the
            // ribbon is read.
            let spaceWindowIDs = Set(columns.flatMap { $0.windows.map(\.id) })
            for id in spaceWindowIDs where wm.scrollAnimator.isAnimating(id) {
                wm.lastAppliedFrames.removeValue(forKey: id)
            }
            wm.scrollAnimator.cancel(windowIDs: spaceWindowIDs)
        }
        guard var r = wm.ribbons[sID], !r.columns.isEmpty else { return }
        let dID = wm.displayBySpaceID[sID] ?? wm.activeDisplayID ?? NSScreen.main?.displayID ?? 0
        guard let screen = wm.screen(forDisplayID: dID) else { return }
        let canvasWidth = Double(screen.visibleFrame.width) - (wm.config.edgeMargin * 2)
        guard canvasWidth > 0 else { return }

        let wasPanning = isPanning
        if !wasPanning {
            isPanning = true
            flushCount = 0
            wm.panningSpaceID = sID
            r.isOverview = false
            RibbonLog.log("pan started space=\(sID) offset=\(Int(r.viewportOffset))", category: "pan")
        }

        let geometry = LayoutEngine.columnGeometry(for: r, canvasWidth: canvasWidth, config: wm.config)
        let stripWidth = geometry.last.map { $0.x + $0.width } ?? 0
        let maxOffset = max(0, stripWidth - canvasWidth)
        r.viewportOffset = max(0, min(r.viewportOffset - dx, maxOffset))
        wm.ribbons[sID] = r
        needsFlush = true

        if !wasPanning {
            startFlushTimer()
        }
    }

    func endPan(snap: Bool) {
        accumulatedDX = 0
        needsFlush = false
        let flushes = flushCount
        flushCount = 0
        stopFlushTimer()

        guard isPanning, let wm = windowManager else {
            isPanning = false
            windowManager?.panningSpaceID = nil
            return
        }
        isPanning = false
        let sID = wm.panningSpaceID ?? wm.currentActiveSpaceID()
        wm.panningSpaceID = nil

        guard snap, var r = wm.ribbons[sID], !r.columns.isEmpty else {
            RibbonLog.log("pan ended: \(flushes) flushes", category: "pan")
            return
        }
        let dID = wm.displayBySpaceID[sID] ?? wm.activeDisplayID ?? NSScreen.main?.displayID ?? 0
        let canvasWidth = wm.screen(forDisplayID: dID).map {
            Double($0.visibleFrame.width) - (wm.config.edgeMargin * 2)
        } ?? 0

        var targetWindowID = r.activeWindow?.id
        if canvasWidth > 0 {
            let geometry = LayoutEngine.columnGeometry(for: r, canvasWidth: canvasWidth, config: wm.config)
            if let bestIndex = LayoutEngine.panSnapColumn(geometry: geometry, offset: r.viewportOffset,
                                                          canvasWidth: canvasWidth, activeIndex: r.activeColumnIndex),
               let winID = r.columns[bestIndex].activeWindow?.id {
                _ = r.focus(windowID: winID)
                targetWindowID = winID
            }
            wm.ribbons[sID] = r
        }

        RibbonLog.log("pan ended: \(flushes) flushes focus wid=\(targetWindowID ?? 0)", category: "pan")
        wm.retileNow(focusWindowID: targetWindowID, animated: true)
    }

    func stop() {
        isPanning = false
        accumulatedDX = 0
        needsFlush = false
        flushCount = 0
        stopFlushTimer()
        windowManager?.panningSpaceID = nil
    }

    private func expireHoldIfNeeded() -> Bool {
        guard let wm = windowManager, wm.panHeld else { return true }
        // A pan lasts until `pan end`, so pauses mid-pan leave the strip where the pointer put it.
        let holdStart = isPanning ? lastMotionTime : wm.panHeldSince
        if let holdStart, DispatchTime.now().uptimeNanoseconds - holdStart.uptimeNanoseconds < Self.holdTimeoutNs {
            return false
        }
        wm.panHeld = false
        wm.panHeldSince = nil
        wm.inputTap.setPointerMonitoring(false)
        RibbonLog.log("pan hold expired", category: "pan")
        endPan(snap: true)
        return true
    }

    private func startFlushTimer() {
        guard flushTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        flushTimer = timer
    }

    private func stopFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    private func tick() {
        guard !expireHoldIfNeeded() else {
            stopFlushTimer()
            return
        }
        guard isPanning, let wm = windowManager else {
            stopFlushTimer()
            return
        }
        if needsFlush {
            needsFlush = false
            flushCount += 1
            wm.retileNow(animated: false, quiet: true)
        }
    }
}
