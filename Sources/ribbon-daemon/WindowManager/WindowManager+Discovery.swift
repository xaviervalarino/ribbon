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

    // MARK: - WindowServer Reads (no app IPC)
    //
    // An AX read waits in the target app's queue behind its pending slide writes, so event
    // handlers on the main thread read geometry and stacking from WindowServer instead.

    /// WindowServer's frame for a window, in the same top-left coordinates as AX.
    func serverFrame(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [NSDictionary],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// WindowServer frames of the app's windows, ordered-out ones included: `serverFrame` returns
    /// nil for a window that is ordered out, such as a hidden native tab.
    func serverFrames(pid: pid_t) -> [CGWindowID: CGRect] {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [NSDictionary] else { return [:] }
        var frames: [CGWindowID: CGRect] = [:]
        for dict in list where (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
            guard let num = dict[kCGWindowNumber as String] as? NSNumber,
                  let bounds = dict[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            frames[num.uint32Value] = rect
        }
        return frames
    }

    /// The app's front-most on-screen normal window, from WindowServer's front-to-back order.
    func frontmostWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary] else {
            return nil
        }
        for dict in list {
            guard (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (dict[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let num = dict[kCGWindowNumber as String] as? NSNumber else { continue }
            return num.uint32Value
        }
        return nil
    }

    /// Window ID for an AX element, from the local cache before asking the app.
    func cachedWindowID(for element: AXElement) -> CGWindowID? {
        windowIDsByElement[element.rawElement] ?? element.windowID
    }

    /// Window ID for a tracked element, falling back to element equality when the element
    /// no longer answers (destroyed windows).
    func trackedWindowID(for element: AXElement) -> CGWindowID? {
        cachedWindowID(for: element)
            ?? trackedWindows.first(where: { CFEqual($0.value.rawElement, element.rawElement) })?.key
    }

    func discoverExistingWindows() {
        reconcileWindows(sortHorizontally: true)
        // A hidden tab that reports a space is tiled by discovery; collapse each group into one slot.
        reconcileNativeTabs(pids: Set(allRibbonWindows.map(\.pid)), confirmHides: false)
        syncFocusToFrontmostWindow()
        retile(allSpaces: true)
    }

    func reconcileWindows(sortHorizontally: Bool = true) {
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

        let onScreen = onScreenWindowIDs()

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
                guard admits(win), let id = win.windowID, !isHiddenTab(id) else { continue }
                if !allLiveIDs.isEmpty && !allLiveIDs.contains(id) { continue }
                // A hidden native tab is ordered out and reports no space; it joins only through its
                // group's slot or the stray pass.
                if let onScreen, !onScreen.contains(id), SpaceManager.spaceIDs(for: id).isEmpty {
                    if trackedWindows[id] == nil {
                        tabStates[id] = .hidden(element: win, pid: app.processIdentifier, shownSinceMs: nil)
                        observer.observeWindow(element: win, pid: app.processIdentifier)
                    }
                    continue
                }

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

        // Always sort newly discovered windows left-to-right by origin.x;
        // upsertWindow preserves existing column positions for already-tracked windows.
        if sortHorizontally || !discovered.isEmpty {
            discovered.sort {
                if $0.x != $1.x { return $0.x < $1.x }
                return $0.id < $1.id
            }
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
        let isStashed = (lastStashedState[id] == true) || winFrame.width <= 50 || winFrame.height <= 50
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
        lastNaturalFrames.removeValue(forKey: id)
        adoptedSinceLastSweep.remove(id)
        dropOrderedOut(id)

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
        // A hidden tab joins only through its group's slot (reconcileNativeTabs).
        guard let id = element.windowID, !isHiddenTab(id) else { return false }

        rememberOriginalFrame(id: id, element: element)

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
        lastNaturalFrames.removeValue(forKey: id)
        displayByWindowID.removeValue(forKey: id)
        dropOrderedOut(id)
        if let sID = spaceByWindowID.removeValue(forKey: id) {
            ribbons[sID]?.removeWindow(id: id)
        } else {
            for sID in ribbons.keys {
                ribbons[sID]?.removeWindow(id: id)
            }
        }
    }

    func rememberOriginalFrame(id: CGWindowID, element: AXElement) {
        guard originalFrames[id] == nil, let frame = element.frame, frame.width > 50 && frame.height > 50 else { return }
        originalFrames[id] = frame
        persistOriginalFrames()
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
            // A closed tab's slot waits for its group's next tab (holdClosedTabSlot).
            if adoptedSinceLastSweep.contains(id) || closedSlot(id) != nil { continue }
            if !liveIDs.contains(id) {
                removeFromRibbon(id: id)
                removedAny = true
            }
        }

        // Also prune originalFrames of dead windows. A held closed-tab slot keeps its frame for the
        // group's next tab.
        let deadOriginals = originalFrames.keys.filter {
            !liveIDs.contains($0) && !adoptedSinceLastSweep.contains($0) && closedSlot($0) == nil
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

        let hiddenPIDs = tabStates.values.compactMap { state -> pid_t? in
            guard case let .hidden(_, pid, _) = state else { return nil }
            return pid
        }
        let tabPIDs = Set(allRibbonWindows.map(\.pid)).union(hiddenPIDs)
        reconcileNativeTabs(pids: tabPIDs, windowList: windowList)
    }
}
