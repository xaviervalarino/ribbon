import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

extension WindowManager {
    // MARK: - Screen Resolution

    func screen(forFrame frame: CGRect) -> NSScreen? {
        if NSScreen.screens.count <= 1 {
            return NSScreen.main ?? NSScreen.screens.first
        }
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryScreenHeight - (frame.origin.y + frame.height)
        let cocoaFrame = CGRect(x: frame.origin.x, y: cocoaY, width: frame.width, height: frame.height)

        var bestScreen: NSScreen?
        var maxArea: CGFloat = 0

        for screen in NSScreen.screens {
            let inter = screen.frame.intersection(cocoaFrame)
            if !inter.isNull {
                let area = inter.width * inter.height
                if area > maxArea {
                    maxArea = area
                    bestScreen = screen
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
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? (NSScreen.main?.frame.height ?? 0)

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

            let cocoaFrame = screen.visibleFrame
            let windowServerFrame = CGRect(
                x: cocoaFrame.minX,
                y: primaryScreenHeight - cocoaFrame.maxY,
                width: cocoaFrame.width,
                height: cocoaFrame.height
            )

            var leftAdjacent = false
            var rightAdjacent = false
            for other in NSScreen.screens where other != screen {
                let yOverlap = max(other.frame.minY, screen.frame.minY) < min(other.frame.maxY, screen.frame.maxY)
                if yOverlap {
                    if abs(other.frame.maxX - screen.frame.minX) < 1.0 {
                        leftAdjacent = true
                    }
                    if abs(other.frame.minX - screen.frame.maxX) < 1.0 {
                        rightAdjacent = true
                    }
                }
            }

            let canvasW = windowServerFrame.width - (config.edgeMargin * 2)
            r.viewportOffset = LayoutEngine.minimalScrollOffset(for: r, canvasWidth: canvasW, config: config)
            ribbons[sID] = r

            let plan = LayoutEngine.computePlan(
                for: r,
                screenFrame: windowServerFrame,
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

    func applyFrames(_ frames: [(id: CGWindowID, pid: pid_t, frame: CGRect, isStashed: Bool)]) {
        var placementsByPID: [pid_t: [(elem: AXElement, id: CGWindowID, frame: CGRect, needsFullFrame: Bool)]] = [:]
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

            let actualPos = elem.position
            let actualSize = elem.size
            let posMismatch: Bool = {
                guard let p = actualPos else { return true }
                return abs(p.x - entry.frame.origin.x) >= 1.5 || abs(p.y - entry.frame.origin.y) >= 1.5
            }()
            let sizeMismatch: Bool = {
                guard let s = actualSize else { return true }
                return abs(s.width - entry.frame.size.width) >= 1.5 || abs(s.height - entry.frame.size.height) >= 1.5
            }()

            var needsFullFrame = sizeMismatch
            if let last = lastAppliedFrames[entry.id] {
                let dx = abs(last.origin.x - entry.frame.origin.x)
                let dy = abs(last.origin.y - entry.frame.origin.y)
                let dw = abs(last.size.width - entry.frame.size.width)
                let dh = abs(last.size.height - entry.frame.size.height)
                let stashedChanged = (lastStashedState[entry.id] ?? false) != entry.isStashed
                if dw >= 0.5 || dh >= 0.5 || stashedChanged {
                    needsFullFrame = true
                }
                if dx < 0.5 && dy < 0.5 && !needsFullFrame && !posMismatch && !sizeMismatch {
                    continue
                }
            } else {
                needsFullFrame = true
            }

            lastStashedState[entry.id] = entry.isStashed
            placementsByPID[entry.pid, default: []].append((elem: elem, id: entry.id, frame: entry.frame, needsFullFrame: needsFullFrame))
        }

        for (pid, entries) in placementsByPID {
            let appElem = AXElement.application(pid: pid)
            let wasEnhanced = appElem.enhancedUserInterface
            // VoiceOver animates window bounds when AXEnhancedUserInterface is active,
            // causing visible frame stutter during batch programmatic positioning.
            if wasEnhanced {
                appElem.enhancedUserInterface = false
            }
            for entry in entries {
                if entry.needsFullFrame {
                    entry.elem.setFrame(entry.frame)
                } else {
                    entry.elem.position = entry.frame.origin
                }
                lastAppliedFrames[entry.id] = entry.frame
                pendingFrameEchoes[entry.id] = .now() + .milliseconds(200)
                RibbonLog.log(
                    "AX applied wid=\(entry.id) pid=\(pid) full=\(entry.needsFullFrame) target=\(entry.frame.integral)",
                    category: "ax"
                )
            }
            if wasEnhanced {
                appElem.enhancedUserInterface = true
            }
        }
    }
}
