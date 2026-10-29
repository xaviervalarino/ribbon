import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

extension WindowManager {
    // MARK: - Screen Resolution

    func screen(forFrame frame: CGRect) -> NSScreen? {
        return screen(forQuartzFrame: QuartzRect(frame))
    }

    func screen(forQuartzFrame frame: QuartzRect) -> NSScreen? {
        if NSScreen.screens.count <= 1 {
            return NSScreen.main ?? NSScreen.screens.first
        }
        let primaryScreenHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let screens = NSScreen.screens.map { screen in
            (screen: screen, bounds: QuartzGeometry.toQuartzRect(cocoaFrame: screen.frame, primaryScreenHeight: primaryScreenHeight))
        }

        var bestScreen: NSScreen?
        var maxArea: Double = 0

        for item in screens {
            if let inter = item.bounds.intersection(frame) {
                if inter.area > maxArea {
                    maxArea = inter.area
                    bestScreen = item.screen
                }
            }
        }
        return bestScreen ?? NSScreen.main ?? NSScreen.screens.first
    }

    func screen(forDisplayID id: CGDirectDisplayID) -> NSScreen? {
        return NSScreen.screens.first(where: { $0.displayID == id }) ?? NSScreen.main
    }

    // MARK: - Debounced Retile

    func scheduleRetile() {
        if retileWork != nil { return }
        let work = DispatchWorkItem { [weak self] in
            self?.retileWork = nil
            self?.retile()
        }
        retileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
    }

    func retileNow(allSpaces: Bool = false, focusWindowID: CGWindowID? = nil, animated: Bool = false) {
        retileWork?.cancel()
        retileWork = nil
        retile(allSpaces: allSpaces, focusWindowID: focusWindowID, animated: animated)
    }

    /// A failed AX write leaves the window where it was: its cached frame is dropped and a retile
    /// 500ms later writes it again, at most `maxWriteRetries` times in a row. After that the cache
    /// keeps the frame, so a hung app is not hammered with writes it cannot answer.
    func writeFailed(id: CGWindowID, frame: CGRect, error: AXError) {
        // A newer plan already replaced the failed frame, and its own write reports separately.
        guard lastAppliedFrames[id] == frame else { return }

        let maxWriteRetries = 3
        let now = DispatchTime.now()
        var retry = writeRetries[id] ?? (count: 0, last: now)
        // Failures 10s apart are unrelated, so each starts a fresh run of retries.
        if now > retry.last + .seconds(10) { retry.count = 0 }
        retry.count += 1
        retry.last = now
        writeRetries[id] = retry
        guard retry.count <= maxWriteRetries else {
            RibbonLog.log("AX write retries exhausted wid=\(id) err=\(error.rawValue)", category: "layout")
            return
        }

        lastAppliedFrames.removeValue(forKey: id)
        RibbonLog.log("AX write retry \(retry.count)/\(maxWriteRetries) wid=\(id) err=\(error.rawValue)", category: "layout")
        DispatchQueue.main.asyncAfter(deadline: now + .milliseconds(500)) { [weak self] in
            // A sliding window's final write reports for itself; a retile now would restart the slide.
            guard let self, !self.scrollAnimator.isAnimating(id) else { return }
            self.scheduleRetile()
        }
    }

    // MARK: - Layout & Retile

    /// Recomputes and applies layouts. `focusWindowID` is focused by its AppDriver
    /// after that driver's moves land, so the window is never focused while off-screen.
    /// `animated` slides moving windows instead of jumping them (command-driven scrolls).
    public func retile(allSpaces: Bool = false, focusWindowID: CGWindowID? = nil, animated: Bool = false) {
        guard !isDisplayReconfiguring else { return }
        guard !NSScreen.screens.isEmpty else { return }
        // In AppKit, (0, 0) is at the bottom-left of the primary display.
        // The primary display's height serves as the universal Y-axis reflection plane.
        let primaryScreenHeight = Double(NSScreen.screens.first?.frame.height ?? (NSScreen.main?.frame.height ?? 0))

        let topology = SpaceManager.currentTopology()
        for (sID, dID) in topology.displayBySpace {
            displayBySpaceID[sID] = dID
        }

        var spacesToTile = Set<SpaceID>()
        if allSpaces {
            spacesToTile.formUnion(ribbons.keys)
        } else {
            for screen in NSScreen.screens {
                let sID = topology.activeSpaceByDisplay[screen.displayID]
                    ?? currentActiveSpaceID(forDisplayID: screen.displayID)
                spacesToTile.insert(sID)
                displayBySpaceID[sID] = screen.displayID
            }
            if spacesToTile.isEmpty {
                spacesToTile.insert(currentActiveSpaceID())
            }
        }

        var framesToApply: [(id: CGWindowID, pid: pid_t, frame: CGRect, isStashed: Bool)] = []
        var naturalFrames: [CGWindowID: CGRect] = [:]
        var displayFrames: [CGWindowID: CGRect] = [:]

        let allDisplayBounds: [DisplayBounds] = NSScreen.screens.map { s in
            let full = QuartzGeometry.toQuartzRect(cocoaFrame: s.frame, primaryScreenHeight: primaryScreenHeight)
            let vis = QuartzGeometry.toQuartzRect(cocoaFrame: s.visibleFrame, primaryScreenHeight: primaryScreenHeight)
            return DisplayBounds(id: s.displayID, frame: full, visibleFrame: vis, scaleFactor: Double(s.backingScaleFactor))
        }

        for sID in spacesToTile {
            guard var r = ribbons[sID], !r.columns.isEmpty else { continue }
            let dID = displayBySpaceID[sID] ?? activeDisplayID ?? NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID ?? CGMainDisplayID()
            guard let screen = screen(forDisplayID: dID) ?? NSScreen.screens.first else {
                RibbonLog.log("retile skipped space=\(sID): no screen for displayID=\(dID)", category: "retile")
                continue
            }

            let targetDisplay = allDisplayBounds.first(where: { $0.id == dID })
            let screenQuartzFrame = targetDisplay?.visibleFrame ?? QuartzGeometry.toQuartzRect(cocoaFrame: screen.visibleFrame, primaryScreenHeight: primaryScreenHeight)
            let screenFullQuartzFrame = targetDisplay?.frame ?? QuartzGeometry.toQuartzRect(cocoaFrame: screen.frame, primaryScreenHeight: primaryScreenHeight)

            let canvasW = screenQuartzFrame.width - (config.edgeMargin * 2)
            let sharedEdges = SharedEdges(screenFrame: screenQuartzFrame, config: config,
                                          targetDisplay: targetDisplay, allDisplays: allDisplayBounds)
            r.viewportOffset = LayoutEngine.minimalScrollOffset(for: r, canvasWidth: canvasW, config: config,
                                                                sharedEdges: sharedEdges)
            ribbons[sID] = r

            let plan = LayoutEngine.computePlan(
                for: r,
                screenFrame: screenQuartzFrame,
                config: config,
                targetDisplay: targetDisplay,
                allDisplays: allDisplayBounds
            )

            var windowPID: [CGWindowID: pid_t] = [:]
            for col in r.columns {
                for win in col.windows {
                    windowPID[win.id] = win.pid
                }
            }

            for placement in plan.placements {
                guard let pid = windowPID[placement.windowID] else { continue }
                framesToApply.append((id: placement.windowID, pid: pid, frame: placement.frame, isStashed: placement.isStashed))
                naturalFrames[placement.windowID] = placement.naturalFrame
                displayFrames[placement.windowID] = screenFullQuartzFrame.cgRect
            }
        }

        applyFrames(framesToApply, naturalFrames: naturalFrames, displayFrames: displayFrames,
                    focusWindowID: focusWindowID, animated: animated)
    }

    /// Groups window mutations by target process and dispatches them asynchronously
    /// to per-PID AppDriver actors, keeping the main thread free from AX IPC stalls.
    func applyFrames(
        _ frames: [(id: CGWindowID, pid: pid_t, frame: CGRect, isStashed: Bool)],
        naturalFrames: [CGWindowID: CGRect] = [:],
        displayFrames: [CGWindowID: CGRect] = [:],
        focusWindowID: CGWindowID? = nil,
        animated: Bool = false
    ) {
        var mutationsByPID: [pid_t: [AppDriver.WindowMutation]] = [:]
        var slidesByID: [CGWindowID: ScrollAnimator.Slide] = [:]
        var focusEnqueued = false
        var settledFocus: (pid: pid_t, mutation: AppDriver.WindowMutation)?
        let slideMs = config.scrollAnimationMs

        for entry in frames {
            // The window under the mouse is placed at mouse-up.
            if entry.id == draggingWindowID && inputTap.isRunning {
                continue
            }

            var elem = trackedWindows[entry.id]
            if elem == nil {
                let appElem = AXElement.application(pid: entry.pid)
                if let found = appElem.windows.first(where: { $0.windowID == entry.id }) {
                    trackedWindows[entry.id] = found
                    windowIDsByElement[found.rawElement] = entry.id
                    observer.observeWindow(element: found, pid: entry.pid)
                    elem = found
                    RibbonLog.log("applyFrames: on-demand re-tracked wid=\(entry.id) pid=\(entry.pid)", category: "ax")
                }
            }
            guard let elem = elem else {
                RibbonLog.log("applyFrames: missing AXElement in trackedWindows for wid=\(entry.id) pid=\(entry.pid)", category: "ax")
                continue
            }

            let isFocusTarget = entry.id == focusWindowID
            if isFocusTarget {
                focusEnqueued = true
                AppDriver.focusRequested(entry.id)
                // Focus lands after the driver's AX writes, so the echo window covers their latency.
                expectFocusEcho(id: entry.id, pid: entry.pid, ms: 300)
            }
            // Focus at slide end is held here and handed to the animator once the slides are known.
            let shouldFocus = isFocusTarget && config.focusTiming == .start
            if isFocusTarget && !shouldFocus {
                settledFocus = (entry.pid, AppDriver.WindowMutation(
                    element: elem, windowID: entry.id, frame: entry.frame,
                    needsFullFrame: false, needsMove: false, shouldFocus: true
                ))
            }

            // Strip positions before and after this retile; a sliding window restarts from where it is.
            let previousFrame = lastAppliedFrames[entry.id]
            let wasStashed = lastStashedState[entry.id] ?? false
            let natural = naturalFrames[entry.id] ?? entry.frame
            let previousNatural = scrollAnimator.currentNatural(entry.id)
                ?? lastNaturalFrames[entry.id]?.origin
                ?? previousFrame?.origin
            lastNaturalFrames[entry.id] = natural
            // Windows already sliding keep sliding when retargeted, so a jump never races a slide.
            let slides = slideMs > 0 && (animated || scrollAnimator.isAnimating(entry.id))

            var needsFullFrame = true
            var needsMove = true
            if let last = lastAppliedFrames[entry.id] {
                let dx = abs(last.origin.x - entry.frame.origin.x)
                let dy = abs(last.origin.y - entry.frame.origin.y)
                let dw = abs(last.size.width - entry.frame.size.width)
                let dh = abs(last.size.height - entry.frame.size.height)

                // Free-edge stashing preserves dimensions; only actual (w, h) changes (>= 1.5pt) require AX resizing
                needsFullFrame = dw >= 1.5 || dh >= 1.5
                needsMove = dx >= 0.5 || dy >= 0.5 || needsFullFrame
            }
            guard needsMove || shouldFocus else { continue }

            if needsMove {
                lastStashedState[entry.id] = entry.isStashed
                lastAppliedFrames[entry.id] = entry.frame
                pendingFrameEchoes[entry.id] = .now() + .milliseconds(200 + (slides ? slideMs : 0))
            }

            if slides, needsMove, let fromNatural = previousNatural {
                let startOrigin = scrollAnimator.currentOrigin(entry.id) ?? previousFrame?.origin ?? entry.frame.origin
                let fromSize = previousFrame?.size ?? entry.frame.size
                let grows = entry.frame.width > fromSize.width + 0.5 || entry.frame.height > fromSize.height + 0.5
                let resizeNow = needsFullFrame
                    && (config.resizeMode == .instant || (config.resizeMode == .growFirst && grows))

                slidesByID[entry.id] = ScrollAnimator.Slide(
                    pid: entry.pid,
                    element: elem,
                    fromNatural: fromNatural,
                    toNatural: natural.origin,
                    parking: slideParking(
                        from: wasStashed ? previousFrame : nil,
                        fromNatural: fromNatural,
                        to: entry.isStashed ? entry.frame : nil,
                        toNatural: natural.origin,
                        display: displayFrames[entry.id]
                    ),
                    // A resize sent at the start origin can run past the screen edge, and macOS caps the
                    // width there. The final carries the size too; AppDriver reads the live size and
                    // resizes again only when the start resize came up short.
                    final: AppDriver.WindowMutation(
                        element: elem,
                        windowID: entry.id,
                        frame: entry.frame,
                        needsFullFrame: needsFullFrame,
                        isSlideFinal: true
                    )
                )
                // One start mutation per window: AppDriver merges pending mutations for a window,
                // so a separate focus mutation would carry the final frame into the grow.
                // Resizing now (grow-first, instant) lets neighbors slide out from under a growing window.
                if resizeNow || shouldFocus {
                    mutationsByPID[entry.pid, default: []].append(AppDriver.WindowMutation(
                        element: elem,
                        windowID: entry.id,
                        frame: CGRect(origin: startOrigin, size: resizeNow ? entry.frame.size : fromSize),
                        needsFullFrame: resizeNow,
                        needsMove: resizeNow,
                        shouldFocus: shouldFocus
                    ))
                }
                continue
            }

            let mutation = AppDriver.WindowMutation(
                element: elem,
                windowID: entry.id,
                frame: entry.frame,
                needsFullFrame: needsFullFrame,
                needsMove: needsMove,
                shouldFocus: shouldFocus
            )
            mutationsByPID[entry.pid, default: []].append(mutation)
        }

        if !slidesByID.isEmpty {
            scrollAnimator.animate(
                slidesByID,
                baseDurationMs: Double(slideMs),
                referenceWidth: Double(NSScreen.main?.frame.width ?? 1500)
            )
        }

        if let focus = settledFocus {
            if scrollAnimator.isActive {
                scrollAnimator.focusWhenSettled(focus.mutation, pid: focus.pid)
            } else {
                mutationsByPID[focus.pid, default: []].append(focus.mutation)
            }
        }

        // The focus target has no placement (for example, its space is not visible).
        if let id = focusWindowID, !focusEnqueued {
            focusWindowDirectly(id: id)
        }

        for (pid, mutations) in mutationsByPID {
            let driver = appDriver(for: pid)
            Task {
                await driver.enqueue(mutations)
            }
        }
    }

    /// Pins a sliding window at the stash sliver of each stashed end while its strip position
    /// lies beyond it. A top/bottom stash (the side edge is shared with another display) leaves
    /// the strip's row, so the window swaps to it while its strip position lies half past `display`'s edge.
    private func slideParking(
        from parkedFrom: CGRect?,
        fromNatural: CGPoint,
        to parkedTo: CGRect?,
        toNatural: CGPoint,
        display: CGRect?
    ) -> ScrollAnimator.Parking {
        var parking = ScrollAnimator.Parking()
        func pin(_ parked: CGRect?, natural: CGPoint) {
            guard let parked else { return }
            guard abs(parked.minY - natural.y) < 0.5 else {
                // Half past the edge is where macOS takes the window, matching the layout's rule.
                guard let display else { return }
                let half = parked.width / 2
                if natural.x < display.minX {
                    parking.belowMinX = .init(stash: parked.origin, limitX: display.minX - half)
                } else if natural.x > display.maxX - parked.width {
                    parking.aboveMaxX = .init(stash: parked.origin, limitX: display.maxX - half)
                }
                return
            }
            if parked.minX < natural.x {
                parking.maxX = parked.minX
            } else if parked.minX > natural.x {
                parking.minX = parked.minX
            }
        }
        pin(parkedFrom, natural: fromNatural)
        pin(parkedTo, natural: toNatural)
        return parking
    }
}
