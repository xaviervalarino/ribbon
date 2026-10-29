import Foundation
import AppKit
import CoreGraphics

/// Pans the active Space's strip horizontally while Caps Lock is held, flushing position
/// updates at most every 8ms and snapping to the most visible column when the pan ends.
final class PanController {
    /// Pointer travel below this many points pans nothing, so caps chords with a resting hand stay still.
    private static let deadZone: Double = 40
    private static let idleTimeoutNs: UInt64 = 300_000_000

    private weak var windowManager: WindowManager?
    private(set) var isPanning = false
    private var accumulatedDX = 0.0
    private var lastMotionTime: DispatchTime = .now()
    private var needsFlush = false
    private var flushTimer: DispatchSourceTimer?

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    func resetIfIdle() {
        guard !isPanning else { return }
        accumulatedDX = 0
    }

    func handleMotion(dx: Double) {
        guard dx != 0, let wm = windowManager else { return }
        lastMotionTime = .now()
        accumulatedDX += dx
        guard abs(accumulatedDX) >= Self.deadZone else { return }

        let sID = wm.panningSpaceID ?? wm.currentActiveSpaceID()
        guard var r = wm.ribbons[sID], !r.columns.isEmpty else { return }
        let dID = wm.displayBySpaceID[sID] ?? wm.activeDisplayID ?? NSScreen.main?.displayID ?? 0
        guard let screen = wm.screen(forDisplayID: dID) else { return }
        let canvasWidth = Double(screen.visibleFrame.width) - (wm.config.edgeMargin * 2)
        guard canvasWidth > 0 else { return }

        let wasPanning = isPanning
        if !wasPanning {
            isPanning = true
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
        stopFlushTimer()

        guard isPanning, let wm = windowManager else {
            isPanning = false
            windowManager?.panningSpaceID = nil
            return
        }
        isPanning = false
        let sID = wm.panningSpaceID ?? wm.currentActiveSpaceID()
        wm.panningSpaceID = nil

        guard snap, var r = wm.ribbons[sID], !r.columns.isEmpty else { return }
        let dID = wm.displayBySpaceID[sID] ?? wm.activeDisplayID ?? NSScreen.main?.displayID ?? 0
        let canvasWidth = wm.screen(forDisplayID: dID).map {
            Double($0.visibleFrame.width) - (wm.config.edgeMargin * 2)
        } ?? 0

        var targetWindowID = r.activeWindow?.id
        if canvasWidth > 0 {
            let geometry = LayoutEngine.columnGeometry(for: r, canvasWidth: canvasWidth, config: wm.config)
            let offset = r.viewportOffset
            func visibleWidth(at index: Int) -> Double {
                let col = geometry[index]
                let left = max(0, col.x - offset)
                let right = min(canvasWidth, col.x - offset + col.width)
                return max(0, right - left)
            }
            var bestIndex = max(0, min(r.activeColumnIndex, geometry.count - 1))
            var bestWidth = visibleWidth(at: bestIndex)
            for index in geometry.indices {
                let width = visibleWidth(at: index)
                if width > bestWidth {
                    bestWidth = width
                    bestIndex = index
                }
            }
            if let winID = r.columns[bestIndex].activeWindow?.id {
                _ = r.focus(windowID: winID)
                targetWindowID = winID
            }
            wm.ribbons[sID] = r
        }

        RibbonLog.log("pan ended focus wid=\(targetWindowID ?? 0)", category: "pan")
        wm.retileNow(focusWindowID: targetWindowID, animated: true)
    }

    func stop() {
        isPanning = false
        accumulatedDX = 0
        needsFlush = false
        stopFlushTimer()
        windowManager?.panningSpaceID = nil
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
        guard isPanning, let wm = windowManager else {
            stopFlushTimer()
            return
        }
        if needsFlush {
            needsFlush = false
            wm.retileNow(animated: false)
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - lastMotionTime.uptimeNanoseconds
        if elapsedNs >= Self.idleTimeoutNs,
           !CGEventSource.buttonState(.combinedSessionState, button: .left) {
            endPan(snap: true)
        }
    }
}
