import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

extension WindowManager {
    // MARK: - Window Discovery & Admission

    func admits(_ win: AXElement) -> Bool {
        guard win.role == (kAXWindowRole as String),
              win.subrole == (kAXStandardWindowSubrole as String),
              !win.isMinimized,
              !win.isFullscreen else { return false }
        return true
    }

    func onScreenWindowIDs() -> Set<CGWindowID>? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary] else {
            return nil
        }
        var ids = Set<CGWindowID>()
        for dict in windowList {
            if let num = dict[kCGWindowNumber as String] as? NSNumber {
                ids.insert(num.uint32Value)
            }
        }
        return ids
    }

    func discoverExistingWindows() {
        reconcileWindows(sortHorizontally: true)
        syncFocusToFrontmostWindow()
        retile(allSpaces: true)
    }

    func reconcileWindows(sortHorizontally: Bool = false) {
        let topology = SpaceManager.currentTopology()
        for (sID, dID) in topology.displayBySpace {
            displayBySpaceID[sID] = dID
        }

        let allLiveIDs: Set<CGWindowID>
        if let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            allLiveIDs = Set(windowList.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        } else {
            allLiveIDs = []
        }

        if !allLiveIDs.isEmpty {
            let deadIDs = Set(trackedWindows.keys).subtracting(allLiveIDs)
            for id in deadIDs {
                removeTrackedWindow(id: id)
            }
        }

        var discovered: [(
            win: AXElement,
            id: CGWindowID,
            pid: pid_t,
            appName: String,
            bundleId: String?,
            x: CGFloat,
            frame: CGRect
        )] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  !app.isHidden,
                  let appName = app.localizedName,
                  !config.ignoredApps.contains(appName) else { continue }

            let appElem = AXElement.application(pid: app.processIdentifier)
            for win in appElem.windows {
                guard admits(win), let id = win.windowID else { continue }
                if !allLiveIDs.isEmpty && !allLiveIDs.contains(id) { continue }

                let frame = win.frame ?? .zero
                if originalFrames[id] == nil, frame.width > 50 && frame.height > 50 {
                    originalFrames[id] = frame
                }

                discovered.append((
                    win: win,
                    id: id,
                    pid: app.processIdentifier,
                    appName: appName,
                    bundleId: app.bundleIdentifier,
                    x: frame.origin.x,
                    frame: frame
                ))
            }
        }

        if sortHorizontally {
            discovered.sort { $0.x < $1.x }
        }

        for entry in discovered {
            upsertWindow(
                win: entry.win,
                id: entry.id,
                pid: entry.pid,
                appName: entry.appName,
                bundleId: entry.bundleId,
                frame: entry.frame,
                topology: topology,
                activate: false
            )
        }
        persistOriginalFrames()
    }

    @discardableResult
    public func upsertWindow(
        win: AXElement,
        id: CGWindowID,
        pid: pid_t,
        appName: String,
        bundleId: String?,
        frame: CGRect? = nil,
        topology: SpaceManager.SpaceTopology? = nil,
        activate: Bool = false
    ) -> SpaceID? {
        let topo = topology ?? SpaceManager.currentTopology()
        let cgsSpaces = SpaceManager.spaceIDs(for: id)
        let allSpaces = SpaceManager.allManagedSpaceIDs()

        // Windows explicitly assigned to 'All Spaces' report membership across
        // every managed space ID. Skip them to avoid pinning them to one ribbon.
        if allSpaces.count > 1 && cgsSpaces.count >= allSpaces.count {
            return nil
        }

        let winFrame = frame ?? win.frame ?? .zero
        let isStashed = winFrame.width <= 50 || winFrame.height <= 50
        let fallbackScreen = (isStashed ? nil : screen(forFrame: winFrame))
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let fallbackDisplayID = fallbackScreen?.displayID ?? CGMainDisplayID()

        let sID: SpaceID
        if let detectedSID = cgsSpaces.first(where: { topo.displayBySpace[$0] != nil }) ?? cgsSpaces.first {
            sID = detectedSID
        } else if let existingSID = spaceByWindowID[id] {
            sID = existingSID
        } else if let activeSID = topo.activeSpaceByDisplay[fallbackDisplayID] {
            sID = activeSID
        } else {
            sID = currentActiveSpaceID(forDisplayID: fallbackDisplayID)
        }

        let dID = topo.displayBySpace[sID] ?? fallbackDisplayID

        trackedWindows[id] = win
        windowIDsByElement[win.rawElement] = id
        displayByWindowID[id] = dID
        spaceByWindowID[id] = sID
        displayBySpaceID[sID] = dID

        for otherSID in ribbons.keys where otherSID != sID {
            ribbons[otherSID]?.removeWindow(id: id)
        }

        var targetR = ribbons[sID] ?? Ribbon()
        let isAlreadyInRibbon = targetR.columns.contains { col in
            col.windows.contains { $0.id == id }
        }

        if !isAlreadyInRibbon {
            let model = WindowModel(
                id: id,
                pid: pid,
                bundleId: bundleId,
                title: win.title,
                appName: appName
            )
            let initialRatio = config.appWidthRatios[appName]
                ?? (bundleId.flatMap { config.appWidthRatios[$0] })
                ?? config.defaultWidthRatio
            let widthParam = targetR.columns.isEmpty ? nil : initialRatio
            targetR.addWindow(model, config: config, activate: activate, initialWidthRatio: widthParam)
            ribbons[sID] = targetR
        } else if activate {
            targetR.focus(windowID: id)
            ribbons[sID] = targetR
        }

        observer.observeWindow(element: win, pid: pid)
        adoptedSinceLastSweep.insert(id)
        return sID
    }

    public func removeTrackedWindow(id: CGWindowID) {
        if let win = trackedWindows.removeValue(forKey: id) {
            windowIDsByElement.removeValue(forKey: win.rawElement)
        }
        spaceByWindowID.removeValue(forKey: id)
        displayByWindowID.removeValue(forKey: id)
        lastAppliedFrames.removeValue(forKey: id)
        lastStashedState.removeValue(forKey: id)
        adoptedSinceLastSweep.remove(id)

        for sID in ribbons.keys {
            ribbons[sID]?.removeWindow(id: id)
        }
    }

    func syncFocusToFrontmostWindow() {
        let topology = SpaceManager.currentTopology()

        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let focusedWin = AXElement.application(pid: frontApp.processIdentifier).focusedWindow,
           let fID = focusedWin.windowID,
           let sID = spaceByWindowID[fID] ?? SpaceManager.spaceIDs(for: fID).first,
           topology.activeSpaceByDisplay.values.contains(sID) {
            let dID = topology.displayBySpace[sID]
                ?? displayByWindowID[fID]
                ?? NSScreen.main?.displayID
                ?? CGMainDisplayID()
            activeDisplayID = dID
            activeSpaceID = sID
            ribbons[sID]?.focus(windowID: fID)
        } else {
            let dID = NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID ?? CGMainDisplayID()
            activeDisplayID = dID
            activeSpaceID = topology.activeSpaceByDisplay[dID] ?? currentActiveSpaceID(forDisplayID: dID)
        }
    }

    // MARK: - Window Adoption & Removal

    @discardableResult
    func adopt(element: AXElement, pid: pid_t, activate: Bool, onScreen precomputedOnScreen: Set<CGWindowID>? = nil) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let appName = app.localizedName,
              !config.ignoredApps.contains(appName) else { return false }
        guard admits(element) else { return false }
        guard let id = element.windowID else { return false }

        if originalFrames[id] == nil, let frame = element.frame, frame.width > 50 && frame.height > 50 {
            originalFrames[id] = frame
            persistOriginalFrames()
        }

        let sID = upsertWindow(
            win: element,
            id: id,
            pid: pid,
            appName: appName,
            bundleId: app.bundleIdentifier,
            frame: element.frame,
            activate: activate
        )
        return sID != nil
    }

    // Drops a window from tiling but keeps its originalFrames entry — a
    // minimized/hidden window is still alive and must restore on quit.
    func removeFromRibbon(id: CGWindowID) {
        if let elem = trackedWindows.removeValue(forKey: id) {
            windowIDsByElement.removeValue(forKey: elem.rawElement)
        }
        lastAppliedFrames.removeValue(forKey: id)
        lastStashedState.removeValue(forKey: id)
        displayByWindowID.removeValue(forKey: id)
        if let sID = spaceByWindowID.removeValue(forKey: id) {
            ribbons[sID]?.removeWindow(id: id)
        } else {
            for sID in ribbons.keys {
                ribbons[sID]?.removeWindow(id: id)
            }
        }
    }

    func forgetOriginalFrame(id: CGWindowID) {
        if originalFrames.removeValue(forKey: id) != nil {
            persistOriginalFrames()
        }
    }

    // MARK: - Liveness GC

    func sweepDeadWindows() {
        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [NSDictionary] else { return }
        var liveIDs = Set<CGWindowID>()
        for dict in windowList {
            if let num = dict[kCGWindowNumber as String] as? NSNumber {
                liveIDs.insert(num.uint32Value)
            }
        }

        var removedAny = false
        let currentIDs = allRibbonWindows.map(\.id)
        for id in currentIDs {
            if adoptedSinceLastSweep.contains(id) { continue }
            if !liveIDs.contains(id) {
                removeFromRibbon(id: id)
                removedAny = true
            }
        }

        // Also prune originalFrames of dead windows
        let deadOriginals = originalFrames.keys.filter {
            !liveIDs.contains($0) && !adoptedSinceLastSweep.contains($0)
        }
        if !deadOriginals.isEmpty {
            for id in deadOriginals {
                originalFrames.removeValue(forKey: id)
            }
            persistOriginalFrames()
        }

        if removedAny {
            scheduleRetile()
        }
        adoptedSinceLastSweep.removeAll()
    }
}
