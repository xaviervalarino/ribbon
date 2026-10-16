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

    func retileNow(allSpaces: Bool = false, focusWindowID: CGWindowID? = nil) {
        retileWork?.cancel()
        retileWork = nil
        retile(allSpaces: allSpaces, focusWindowID: focusWindowID)
    }

    // MARK: - Layout & Retile

    /// Recomputes and applies layouts. `focusWindowID` is focused by its AppDriver
    /// after that driver's moves land, so the window is never focused while off-screen.
    public func retile(allSpaces: Bool = false, focusWindowID: CGWindowID? = nil) {
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

            // Prevent stashed windows from bleeding onto adjacent physical monitors.
            var leftAdjacent = false
            var rightAdjacent = false
            for neighborScreen in NSScreen.screens where neighborScreen != screen {
                let neighborBounds = QuartzGeometry.toQuartzRect(cocoaFrame: neighborScreen.frame, primaryScreenHeight: primaryScreenHeight)
                if QuartzGeometry.isAdjacentLeft(rect: screenFullQuartzFrame, candidate: neighborBounds) {
                    leftAdjacent = true
                }
                if QuartzGeometry.isAdjacentRight(rect: screenFullQuartzFrame, candidate: neighborBounds) {
                    rightAdjacent = true
                }
            }

            let canvasW = screenQuartzFrame.width - (config.edgeMargin * 2)
            r.viewportOffset = LayoutEngine.minimalScrollOffset(for: r, canvasWidth: canvasW, config: config)
            ribbons[sID] = r

            let plan = LayoutEngine.computePlan(
                for: r,
                screenFrame: screenQuartzFrame,
                config: config,
                targetDisplay: targetDisplay,
                allDisplays: allDisplayBounds,
                allowLeftBleed: !leftAdjacent,
                allowRightBleed: !rightAdjacent
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
            }
        }

        applyFrames(framesToApply, focusWindowID: focusWindowID)
    }

    /// Groups window mutations by target process and dispatches them asynchronously
    /// to per-PID AppDriver actors, keeping the main thread free from AX IPC stalls.
    func applyFrames(
        _ frames: [(id: CGWindowID, pid: pid_t, frame: CGRect, isStashed: Bool)],
        focusWindowID: CGWindowID? = nil
    ) {
        var mutationsByPID: [pid_t: [AppDriver.WindowMutation]] = [:]
        var focusEnqueued = false

        for entry in frames {
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

            let shouldFocus = entry.id == focusWindowID
            if shouldFocus {
                focusEnqueued = true
                // Focus lands after the driver's AX writes, so the echo window covers their latency.
                pendingFocusEchoes[entry.id] = .now() + .milliseconds(300)
            }

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
                pendingFrameEchoes[entry.id] = .now() + .milliseconds(200)
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
}
