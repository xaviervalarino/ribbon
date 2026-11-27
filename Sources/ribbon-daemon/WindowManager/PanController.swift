import Foundation
import CoreGraphics

/// Pans the active Space's strip horizontally while a pan is held (`pan begin` to `pan end`), or
/// while three fingers scrub the trackpad, flushing position updates at most every 8ms. A released
/// hold snaps to the column `LayoutEngine.panSnapColumn` picks; a lifted scrub glides on its
/// velocity and snaps to the column edge `LayoutEngine.swipeSnap` picks.
final class PanController {
    /// Pointer travel below this many points pans nothing, so key chords with a resting hand stay still.
    private static let deadZone: Double = 40
    /// Motion after a pause this long starts the dead zone over, so slow drift never adds up to a pan.
    private static let idleTimeoutNs: UInt64 = 300_000_000
    /// Holds expire 10s after `pan begin`, or 10s after a pan's last motion, so a lost `pan end`
    /// cannot leave pointer motion panning.
    private static let holdTimeoutNs: UInt64 = 10_000_000_000
    /// Canvas widths a lifting scrub must push past the strip's end to run that edge's command.
    private static let edgeOvershoot = 0.5

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
    /// Tracks a trackpad scrub from its first motion until it ends, on an empty Space too, where no
    /// pan runs; nil for a caps hold.
    private var scrubTracker: SwipeTracker?
    var isScrubbing: Bool { scrubTracker != nil }
    /// Scrub travel the strip's ends clamped away since the last inward motion; positive past the
    /// right end.
    private var scrubOverscroll = 0.0
    private var lastScrubDX = 0.0

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
        // Caps takes the strip over from a scrub, from where the fingers left it.
        if isScrubbing { endPan(snap: false) }
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
        guard scrubTracker == nil, !expireHoldIfNeeded(), dx != 0 else { return }
        let now = DispatchTime.now()
        if !isPanning, now.uptimeNanoseconds - lastMotionTime.uptimeNanoseconds >= Self.idleTimeoutNs {
            accumulatedDX = 0
        }
        lastMotionTime = now
        accumulatedDX += dx
        guard abs(accumulatedDX) >= Self.deadZone else { return }
        applyPan(dx: dx)
    }

    /// Moves the strip by `fraction` of the trackpad's width of finger travel at `time` (seconds,
    /// monotonic). Ignored while a caps hold is on.
    func scrub(fraction: Double, time: Double) {
        guard heldSince == nil, let wm = windowManager,
              let canvasWidth = wm.canvasWidth(forSpace: panningSpaceID ?? wm.currentActiveSpaceID()) else { return }
        let dx = fraction * wm.config.swipeFollowScale * canvasWidth
        // A scrub on an empty Space runs no pan to expire it, so a lost lift leaves its state behind.
        if isScrubbing, !isPanning, DispatchTime.now().uptimeNanoseconds - lastMotionTime.uptimeNanoseconds >= Self.holdTimeoutNs {
            scrubTracker = nil
            scrubOverscroll = 0
        }
        // An empty Space has no strip to move: all of its travel pushes past an edge.
        let overflow = applyPan(dx: dx) ?? -dx
        scrubOverscroll = overflow * scrubOverscroll > 0 ? scrubOverscroll + overflow : overflow
        lastScrubDX = dx
        lastMotionTime = .now()
        if scrubTracker == nil { scrubTracker = SwipeTracker() }
        scrubTracker?.push(delta: dx, time: time)
    }

    /// Ends a scrub when its fingers lift at `time`: the strip glides and snaps to a column. Returns
    /// the edge whose command should run when the scrub pushed far enough past it. Focus then stays
    /// where it was, and the strip settles back on it: activating a window on this Space after the
    /// Space switch would pull macOS back to it.
    func liftScrub(time: Double) -> SwipeStepper.Step? {
        guard isScrubbing, let wm = windowManager else { return nil }
        // A pause before the lift leaves no velocity: samples older than the history drop out.
        scrubTracker?.push(delta: 0, time: time)
        let edge = scrubEdge(glide: scrubTracker?.glide ?? 0, wm: wm)
        endPan(snap: true, focus: edge == nil)
        return edge
    }

    /// The edge a lifting scrub pushed `edgeOvershoot` canvas widths past, by its overscroll while
    /// pinned or its glide past the end, whichever is larger, when its last motion was outward.
    private func scrubEdge(glide: Double, wm: WindowManager) -> SwipeStepper.Step? {
        let sID = panningSpaceID ?? wm.currentActiveSpaceID()
        guard wm.config.swipeEdgeSteps > 0, let canvasWidth = wm.canvasWidth(forSpace: sID) else { return nil }
        let ribbon = wm.ribbons[sID] ?? Ribbon()
        let stripEnd = LayoutEngine.columnGeometry(for: ribbon, canvasWidth: canvasWidth, config: wm.config)
            .last.map { $0.x + $0.width } ?? 0
        let maxOffset = max(0, stripEnd - canvasWidth)
        let projected = ribbon.viewportOffset - glide
        let glidePast = projected > maxOffset ? projected - maxOffset : min(0, projected)
        let overshoot = abs(glidePast) > abs(scrubOverscroll) ? glidePast : scrubOverscroll
        // Past the right end (positive) the fingers moved left (negative dx).
        guard abs(overshoot) >= Self.edgeOvershoot * canvasWidth, overshoot * lastScrubDX < 0 else { return nil }
        return overshoot > 0 ? .focusRight : .focusLeft
    }

    /// Moves the strip by `dx`, starting a pan if none runs. Returns the part of the move the
    /// strip's ends clamped away (positive past the right end), or nil when the Space has no strip.
    @discardableResult
    private func applyPan(dx: Double) -> Double? {
        guard let wm = windowManager else { return nil }
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
              let canvasWidth = wm.canvasWidth(forSpace: sID) else { return nil }

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
        let target = r.viewportOffset - dx
        r.viewportOffset = max(0, min(target, maxOffset))
        wm.ribbons[sID] = r
        needsFlush = true
        return target - r.viewportOffset
    }

    /// Ends any pan. `snap` settles the strip on a column, which takes focus unless `focus` is false.
    func endPan(snap: Bool, focus: Bool = true) {
        let scrub = scrubTracker
        scrubTracker = nil
        scrubOverscroll = 0
        lastScrubDX = 0
        // A scrub ended by anything but its lift (a command, a click, a Space change, caps) ignores
        // the rest of its gesture.
        if scrub != nil && !snap { windowManager?.swipeStepper.cancel() }
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
            let snapColumn: Int?
            if let scrub {
                // `dx` moves the offset the other way, so the glide subtracts.
                let projected = r.viewportOffset - scrub.glide
                let target = LayoutEngine.swipeSnap(geometry: geometry, projectedOffset: projected, canvasWidth: canvasWidth)
                snapColumn = target?.column
                r.viewportOffset = target?.offset ?? r.viewportOffset
            } else {
                snapColumn = LayoutEngine.panSnapColumn(geometry: geometry, offset: r.viewportOffset,
                                                        canvasWidth: canvasWidth, activeIndex: r.activeColumnIndex)
            }
            if focus, let snapColumn, let winID = r.columns[snapColumn].activeWindow?.id, winID != r.activeWindow?.id {
                r.focus(windowID: winID)
                targetWindowID = winID
            }
            if scrub == nil {
                r.viewportOffset = LayoutEngine.panReleaseOffset(for: r, canvasWidth: canvasWidth, config: wm.config)
            }
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
        guard scrubTracker != nil || !expireHoldIfNeeded(), isPanning, let wm = windowManager else {
            stopFlushTimer()
            return
        }
        // A scrub whose lift never arrived (a dropped event) ends like an idle hold.
        if isScrubbing, DispatchTime.now().uptimeNanoseconds - lastMotionTime.uptimeNanoseconds >= Self.holdTimeoutNs {
            RibbonLog.log("scrub expired", category: "pan")
            endPan(snap: true)
            return
        }
        if needsFlush {
            needsFlush = false
            flushCount += 1
            wm.retileNow(animated: false, quiet: true)
        }
    }
}
