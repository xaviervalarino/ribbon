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

    func retileNow(allSpaces: Bool = false) {
        retileWork?.cancel()
        retileWork = nil
        retile(allSpaces: allSpaces)
    }

    // MARK: - Layout & Retile

    public func retile(allSpaces: Bool = false) {
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

        for sID in spacesToTile {
            guard var r = ribbons[sID], !r.columns.isEmpty else { continue }
            let dID = displayBySpaceID[sID] ?? activeDisplayID ?? NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID ?? CGMainDisplayID()
            guard let screen = screen(forDisplayID: dID) ?? NSScreen.screens.first else {
                RibbonLog.log("retile skipped space=\(sID): no screen for displayID=\(dID)", category: "retile")
                continue
            }

            let screenQuartzFrame = QuartzGeometry.toQuartzRect(cocoaFrame: screen.visibleFrame, primaryScreenHeight: primaryScreenHeight)
            let screenFullQuartzFrame = QuartzGeometry.toQuartzRect(cocoaFrame: screen.frame, primaryScreenHeight: primaryScreenHeight)

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

        applyFrames(framesToApply)
    }

    /// Groups window mutations by target process and dispatches them asynchronously
    /// to per-PID AppDriver actors, keeping the main thread free from AX IPC stalls.
    func applyFrames(_ frames: [(id: CGWindowID, pid: pid_t, frame: CGRect, isStashed: Bool)]) {
        var mutationsByPID: [pid_t: [AppDriver.WindowMutation]] = [:]

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

            var needsFullFrame = true
            if let last = lastAppliedFrames[entry.id] {
                let dx = abs(last.origin.x - entry.frame.origin.x)
                let dy = abs(last.origin.y - entry.frame.origin.y)
                let dw = abs(last.size.width - entry.frame.size.width)
                let dh = abs(last.size.height - entry.frame.size.height)
                let stashedChanged = (lastStashedState[entry.id] ?? false) != entry.isStashed

                needsFullFrame = dw >= 0.5 || dh >= 0.5 || stashedChanged
                if dx < 0.5 && dy < 0.5 && !needsFullFrame {
                    continue
                }
            }

            lastStashedState[entry.id] = entry.isStashed
            lastAppliedFrames[entry.id] = entry.frame
            pendingFrameEchoes[entry.id] = .now() + .milliseconds(200)

            let mutation = AppDriver.WindowMutation(
                element: elem,
                windowID: entry.id,
                frame: entry.frame,
                needsFullFrame: needsFullFrame
            )
            mutationsByPID[entry.pid, default: []].append(mutation)
        }

        for (pid, mutations) in mutationsByPID {
            let driver = appDriver(for: pid)
            Task {
                await driver.enqueue(mutations)
            }
        }
    }
}
