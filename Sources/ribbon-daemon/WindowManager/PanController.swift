import Foundation
import CoreGraphics

/// Pans the active Space's strip horizontally while a pan is held (`pan begin` to `pan end`),
/// flushing position updates at most every 8ms and snapping to the column
/// `LayoutEngine.panSnapColumn` picks when the hold ends.
final class PanController {
    /// Pointer travel below this many points pans nothing, so key chords with a resting hand stay still.
    private static let deadZone: Double = 40
    /// Motion after a pause this long starts the dead zone over, so slow drift never adds up to a pan.
    private static let idleTimeoutNs: UInt64 = 300_000_000
    /// Holds expire 10s after `pan begin`, or 10s after a pan's last motion, so a lost `pan end`
    /// cannot leave pointer motion panning.
    private static let holdTimeoutNs: UInt64 = 10_000_000_000

    private weak var windowManager: WindowManager?
    /// The Space being panned; retile keeps its offset where the pan put it.
    private(set) var panningSpaceID: WindowManager.SpaceID?
    var isPanning: Bool { panningSpaceID != nil }
    /// When the current hold began; nil while no hold is active.
    private var heldSince: DispatchTime?
    private var orphanEndAt: DispatchTime?
    private var accumulatedDX = 0.0
    private var lastMotionTime: DispatchTime = .now()
    private var needsFlush = false
    private var flushCount = 0
    private var flushTimer: DispatchSourceTimer?

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    func beginHold() {
        // Each command is its own CLI process, so a quick tap's `pan end` can overtake its
        // `pan begin`; a begin right after an end that found no hold is that stale press.
        if let orphan = orphanEndAt, DispatchTime.now() < orphan + .milliseconds(250) {
            orphanEndAt = nil
            return
        }
        heldSince = .now()
        if !isPanning {
            accumulatedDX = 0
            lastMotionTime = .now()
        }
        windowManager?.inputTap.setPointerMonitoring(true)
    }

    func endHold() {
        orphanEndAt = heldSince == nil ? .now() : nil
        releaseHold()
    }

    private func releaseHold() {
        heldSince = nil
        windowManager?.inputTap.setPointerMonitoring(false)
        endPan(snap: true)
    }

    func handleMotion(dx: Double) {
        guard !expireHoldIfNeeded(), dx != 0, let wm = windowManager else { return }
        let now = DispatchTime.now()
        if !isPanning, now.uptimeNanoseconds - lastMotionTime.uptimeNanoseconds >= Self.idleTimeoutNs {
            accumulatedDX = 0
        }
        lastMotionTime = now
        accumulatedDX += dx
        guard abs(accumulatedDX) >= Self.deadZone else { return }

        let sID = panningSpaceID ?? wm.currentActiveSpaceID()
        if !isPanning, let columns = wm.ribbons[sID]?.columns {
            // Cancelling replays deferred AX events, which edit the ribbon, so it runs before the
            // ribbon is read.
            let spaceWindowIDs = Set(columns.flatMap { $0.windows.map(\.id) })
            for id in spaceWindowIDs where wm.scrollAnimator.isAnimating(id) {
                wm.lastAppliedFrames.removeValue(forKey: id)
            }
            wm.scrollAnimator.cancel(windowIDs: spaceWindowIDs)
        }
        guard var r = wm.ribbons[sID], !r.columns.isEmpty,
              let canvasWidth = wm.canvasWidth(forSpace: sID) else { return }

        if !isPanning {
            panningSpaceID = sID
            flushCount = 0
            r.isOverview = false
            RibbonLog.log("pan started space=\(sID) offset=\(Int(r.viewportOffset))", category: "pan")
            startFlushTimer()
        }

        let geometry = LayoutEngine.columnGeometry(for: r, canvasWidth: canvasWidth, config: wm.config)
        let stripWidth = geometry.last.map { $0.x + $0.width } ?? 0
        let maxOffset = max(0, stripWidth - canvasWidth)
        r.viewportOffset = max(0, min(r.viewportOffset - dx, maxOffset))
        wm.ribbons[sID] = r
        needsFlush = true
    }

    func endPan(snap: Bool) {
        accumulatedDX = 0
        needsFlush = false
        stopFlushTimer()
        guard let sID = panningSpaceID else { return }
        panningSpaceID = nil
        guard let wm = windowManager else { return }

        guard snap, var r = wm.ribbons[sID], !r.columns.isEmpty else {
            RibbonLog.log("pan ended: \(flushCount) flushes", category: "pan")
            return
        }
        // Focus moves only when the snap lands on another column, so a pan that settles back on the
        // active column leaves focus in a floating window or another app.
        var targetWindowID: CGWindowID?
        if let canvasWidth = wm.canvasWidth(forSpace: sID) {
            let geometry = LayoutEngine.columnGeometry(for: r, canvasWidth: canvasWidth, config: wm.config)
            if let bestIndex = LayoutEngine.panSnapColumn(geometry: geometry, offset: r.viewportOffset,
                                                          canvasWidth: canvasWidth, activeIndex: r.activeColumnIndex),
               let winID = r.columns[bestIndex].activeWindow?.id, winID != r.activeWindow?.id {
                r.focus(windowID: winID)
                targetWindowID = winID
            }
            r.viewportOffset = LayoutEngine.panReleaseOffset(for: r, canvasWidth: canvasWidth, config: wm.config)
            wm.ribbons[sID] = r
        }

        RibbonLog.log("pan ended: \(flushCount) flushes focus wid=\(targetWindowID ?? 0)", category: "pan")
        wm.retileNow(focusWindowID: targetWindowID, animated: true)
    }

    /// Ends an expired hold; true when no hold remains.
    private func expireHoldIfNeeded() -> Bool {
        guard let heldSince else { return true }
        // A pan lasts until `pan end`, so pauses mid-pan leave the strip where the pointer put it.
        let holdStart = isPanning ? lastMotionTime : heldSince
        guard DispatchTime.now().uptimeNanoseconds - holdStart.uptimeNanoseconds >= Self.holdTimeoutNs else {
            return false
        }
        RibbonLog.log("pan hold expired", category: "pan")
        releaseHold()
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
        guard !expireHoldIfNeeded(), isPanning, let wm = windowManager else {
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
