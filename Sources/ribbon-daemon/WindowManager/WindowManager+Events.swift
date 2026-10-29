import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

extension WindowManager {
    // MARK: - Space Change Handling

    public func handleActiveSpaceDidChange() {
        guard !isDisplayReconfiguring else { return }

        let topology = SpaceManager.currentTopology()
        for (sID, dID) in topology.displayBySpace {
            displayBySpaceID[sID] = dID
        }

        reconcileWindows(sortHorizontally: false)
        syncFocusToFrontmostWindow()

        for activeSID in topology.activeSpaceByDisplay.values {
            guard let ribbon = ribbons[activeSID] else { continue }
            for col in ribbon.columns {
                for win in col.windows {
                    lastAppliedFrames.removeValue(forKey: win.id)
                }
            }
        }

        retile(allSpaces: false)

        // macOS posts activeSpaceDidChangeNotification before NSWorkspace updates
        // frontmostApplication. A trailing 50ms pass catches the newly focused window
        // once AppKit finishes switching the active app.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self = self, !self.isDisplayReconfiguring else { return }
            self.syncFocusToFrontmostWindow()
            self.retile(allSpaces: false)
        }
    }
}

/// Carries a weak WindowManager reference through a Task; only read it back on the main queue.
private struct MainThreadRef: @unchecked Sendable {
    weak var value: WindowManager?

    init(_ value: WindowManager) {
        self.value = value
    }
}

// MARK: - AXEventObserverDelegate

extension WindowManager: AXEventObserverDelegate {
    public func windowCreated(element: AXElement, pid: pid_t) {
        let isFrontmost = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        // A new tab opens at its group's frame. Adopting it as a column would move the whole group.
        if admits(element), let id = element.windowID, let sibling = tabSibling(of: element, pid: pid) {
            let frame = serverFrame(id).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none"
            RibbonLog.log("native tab candidate wid=\(id) sibling=\(sibling) frame=\(frame)", category: "tabs")
            nativeTabs[id] = (element: element, pid: pid)
            observer.observeWindow(element: element, pid: pid)
            scheduleTabReconcile(pid: pid, focus: isFrontmost ? id : nil)
            return
        }

        let hasTiledWindow = allRibbonWindows.contains { $0.pid == pid }
        if adopt(element: element, pid: pid, activate: isFrontmost) {
            scheduleRetile()
        } else if isFrontmost {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                guard let self, !self.isStopped else { return }
                if self.adopt(element: element, pid: pid, activate: true) {
                    self.scheduleRetile()
                }
            }
        }
        // A tab whose frame settles after creation is caught once it orders its sibling out.
        if hasTiledWindow {
            scheduleTabReconcile(pid: pid)
        }
    }

    public func windowDestroyed(element: AXElement, pid: pid_t) {
        // A destroyed element no longer answers its window ID, so hidden tabs match by element.
        if let tabID = nativeTabs.first(where: { CFEqual($0.value.element.rawElement, element.rawElement) })?.key {
            nativeTabs.removeValue(forKey: tabID)
            strayTabs.remove(tabID)
            return
        }
        guard let id = trackedWindowID(for: element) else { return }

        // Closing a shown tab shows another tab of its group, which takes over the slot.
        let siblings = nativeTabs.keys.filter { $0 != id && nativeTabs[$0]?.pid == pid }.sorted()
        if !siblings.isEmpty {
            let onScreen = onScreenWindowIDs() ?? []
            let lastSize = lastAppliedFrames[id]?.size
            let sizeMatch = siblings.first { sibling in
                guard let lastSize, let size = serverFrame(sibling)?.size else { return false }
                return abs(size.width - lastSize.width) <= 2 && abs(size.height - lastSize.height) <= 2
            }
            // Any other sibling may belong to another group of the app; a frame write would move that group.
            if let replacement = siblings.first(where: onScreen.contains) ?? sizeMatch,
               let tab = nativeTabs[replacement],
               swapTab(out: id, in: replacement, element: tab.element, pid: pid) {
                nativeTabs.removeValue(forKey: id)
                strayTabs.remove(id)
                forgetOriginalFrame(id: id)
                scheduleTabReconcile(pid: pid)
                scheduleRetile()
                return
            }
        }

        removeFromRibbon(id: id)
        forgetOriginalFrame(id: id)
        scheduleRetile()
    }

    public func windowMinimized(element: AXElement, pid: pid_t) {
        guard let id = trackedWindowID(for: element) else { return }
        removeFromRibbon(id: id)
        scheduleRetile()
    }

    public func windowDeminiaturized(element: AXElement, pid: pid_t) {
        let isFrontmost = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        if adopt(element: element, pid: pid, activate: isFrontmost) {
            scheduleRetile()
        }
    }

    public func windowResized(element: AXElement, pid: pid_t) {
        guard !isDisplayReconfiguring else { return }
        // A hidden tab follows its group's frame; its resize is not a manual one.
        guard let id = trackedWindowID(for: element), nativeTabs[id] == nil else { return }

        // WindowServer bounds trail the app's resize notification by 8-13ms, so a size read here
        // can be the pre-resize size. Any resize inside Ribbon's own echo window is ours, and a
        // manual resize is measured again once the debounce fires, after WindowServer catches up.
        let now = observer.currentEventTime
        pendingFrameEchoes = pendingFrameEchoes.filter { $0.value >= now }
        if pendingFrameEchoes[id] != nil {
            return
        }

        let sID = spaceByWindowID[id] ?? currentActiveSpaceID()
        let dID = displayByWindowID[id] ?? NSScreen.main?.displayID ?? activeDisplayID ?? 0
        guard let screen = screen(forDisplayID: dID) else { return }
        let canvasW = screen.visibleFrame.width - (config.edgeMargin * 2)
        guard canvasW > 0 else { return }

        resizeDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeDebounceWork = nil
            guard let newSize = self.serverFrame(id)?.size else { return }
            if let last = self.lastAppliedFrames[id], abs(last.size.width - newSize.width) < 2.0 {
                return
            }
            let ratio = max(0.15, min(1.0, Double(newSize.width) / Double(canvasW)))
            if var r = self.ribbons[sID] {
                if r.setWidthRatio(ratio, forWindowID: id) {
                    let applied = self.lastAppliedFrames[id].map { "\(Int($0.width))" } ?? "none"
                    RibbonLog.log(
                        "manual resize wid=\(id) width=\(Int(newSize.width)) applied=\(applied) ratio=\(String(format: "%.3f", ratio))",
                        category: "layout"
                    )
                    self.ribbons[sID] = r
                    self.lastAppliedFrames.removeValue(forKey: id)
                    self.scheduleRetile()
                }
            }
        }
        resizeDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    public func windowMoved(element: AXElement, pid: pid_t) {
        guard !isDisplayReconfiguring else { return }
        guard let id = trackedWindowID(for: element), nativeTabs[id] == nil else { return }

        let now = observer.currentEventTime
        // WindowServer bounds trail the app's move notification, so inside Ribbon's own echo
        // window a position mismatch is lag, not a manual move.
        pendingFrameEchoes = pendingFrameEchoes.filter { $0.value >= now }
        if pendingFrameEchoes[id] != nil {
            return
        }

        // Check if window crossed display boundary
        if let currentFrame = serverFrame(id) {
            if let newScreen = screen(forFrame: currentFrame) {
                let newDID = newScreen.displayID
                if let oldDID = displayByWindowID[id], oldDID != newDID {
                    let newSID = currentActiveSpaceID(forDisplayID: newDID)
                    migrateWindow(id: id, toSpace: newSID, display: newDID)
                    activeDisplayID = newDID
                    activeSpaceID = newSID
                    lastAppliedFrames.removeValue(forKey: id)
                    let isDragging = CGEventSource.buttonState(.combinedSessionState, button: .left)
                    if !isDragging {
                        scheduleRetile()
                    }
                    return
                }
            }
        }

        // Manual move: mark dirty in diff cache; keyboard retiles snap it back,
        // but avoid fighting the mouse cursor mid-drag.
        lastAppliedFrames.removeValue(forKey: id)
    }

    public func windowFocused(element: AXElement, pid: pid_t) {
        windowFocused(element: element, pid: pid, windowID: nil, arrival: nil)
    }

    /// `windowID` and `arrival` come from a lookup that ran off the main thread: the ID saves an
    /// AX read, and echo checks judge the event by when it arrived rather than when it was answered.
    func windowFocused(element: AXElement, pid: pid_t, windowID: CGWindowID?, arrival: DispatchTime?) {
        guard let id = windowID ?? cachedWindowID(for: element) else { return }

        let now = arrival ?? observer.currentEventTime
        // One activation echoes twice (focused-window change, then app activation), and an
        // older target's echoes can land after a newer press; all of them stay echoes until
        // the deadline.
        pendingFocusEchoes = pendingFocusEchoes.filter { $0.value >= now }
        pendingFocusEchoPIDs = pendingFocusEchoPIDs.filter { $0.value >= now }
        if pendingFocusEchoes[id] != nil || pendingFocusEchoPIDs[pid] != nil {
            return
        }
        // A click newer than the last command focus wins: drivers skip that focus, even one held through a slide.
        // An event older than it (a slow front-window lookup, a click before the keypress) is stale.
        guard AppDriver.focusRequested(id, at: now) else {
            RibbonLog.log("focus event wid=\(id) pid=\(pid) ignored: older than the latest focus request", category: "focus")
            return
        }

        // A tab switch focuses a hidden tab: it takes over its group's slot, never a new column.
        if nativeTabs[id] != nil {
            reconcileNativeTabs(pids: [pid], focus: id)
            if spaceByWindowID[id] == nil {
                scheduleTabReconcile(pid: pid, focus: id)
                return
            }
        }

        // A real (user-initiated) focus usually precedes a manual drag; the
        // diff cache can't see drags yet (kAXMoved lands in Phase 4), so
        // evict this window's entry to force a fresh frame write next retile.
        lastAppliedFrames.removeValue(forKey: id)

        var foundSpaceID = spaceByWindowID[id]
        if foundSpaceID == nil {
            for (sID, r) in ribbons {
                if r.columns.contains(where: { $0.windows.contains(where: { $0.id == id }) }) {
                    foundSpaceID = sID
                    spaceByWindowID[id] = sID
                    break
                }
            }
        }

        if foundSpaceID == nil {
            if let onScreen = onScreenWindowIDs(), onScreen.contains(id), admits(element) {
                if adopt(element: element, pid: pid, activate: true) {
                    scheduleRetile()
                    return
                }
            }
        }

        if let sID = foundSpaceID, var r = ribbons[sID] {
            let topology = SpaceManager.currentTopology()
            let isVisibleSpace = topology.activeSpaceByDisplay.values.contains(sID)
            if isVisibleSpace {
                activeSpaceID = sID
                if let dID = topology.displayBySpace[sID] ?? displayBySpaceID[sID] {
                    activeDisplayID = dID
                }
            }

            let wasOverview = r.isOverview
            if wasOverview && isVisibleSpace {
                r.isOverview = false
            }

            let oldActive = r.activeColumnIndex
            let oldRow = r.activeColumn?.activeRowIndex
            if r.focus(windowID: id) {
                if r.activeColumnIndex != oldActive || r.activeColumn?.activeRowIndex != oldRow || (wasOverview && isVisibleSpace) {
                    RibbonLog.log("focus event moved activeColumn \(oldActive)->\(r.activeColumnIndex) to wid=\(id) pid=\(pid)", category: "focus")
                    ribbons[sID] = r
                    if isVisibleSpace {
                        scheduleRetile()
                    }
                }
            }
        }
    }

    public func applicationActivated(pid: pid_t) {
        // Ignored apps never join a ribbon, so their activation has nothing to look up.
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName,
           config.ignoredApps.contains(name) {
            return
        }
        // The app's front window from WindowServer stacking avoids an AX round trip when it is tracked.
        if let id = frontmostWindowID(pid: pid), let tracked = trackedWindows[id] {
            windowFocused(element: tracked, pid: pid)
            return
        }
        lookUpFrontWindow(pid: pid, arrival: observer.currentEventTime, retry: true)
    }

    /// Asks the app's driver for its front window; an app redrawing for activation answers in
    /// 30-350ms. The answer is judged by the activation's arrival time and dropped once another
    /// app is frontmost. An app with no window on screen yet is asked once more after 100ms.
    private func lookUpFrontWindow(pid: pid_t, arrival: DispatchTime, retry: Bool) {
        let onScreen = onScreenWindowIDs()
        let driver = appDriver(for: pid)
        let manager = MainThreadRef(self)
        Task {
            let front = await driver.frontWindow(onScreen: onScreen)
            DispatchQueue.main.async {
                guard let self = manager.value, !self.isStopped,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                if let front {
                    self.windowFocused(element: front.element, pid: pid, windowID: front.windowID, arrival: arrival)
                } else if retry {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                        guard let self, !self.isStopped else { return }
                        self.lookUpFrontWindow(pid: pid, arrival: arrival, retry: false)
                    }
                }
            }
        }
    }

    public func applicationEventOccurred(kind: AppEventKind, pid: pid_t?) {
        switch kind {
        case .hidden:
            guard let pid = pid else { return }
            let windowIDs = allRibbonWindows.filter { $0.pid == pid }.map(\.id)
            for id in windowIDs {
                removeFromRibbon(id: id)
            }
            scheduleRetile()
        case .unhidden:
            guard let pid = pid else { return }
            let onScreen = onScreenWindowIDs()
            for win in AXElement.application(pid: pid).windows {
                if let id = win.windowID, onScreen?.contains(id) ?? true {
                    adopt(element: win, pid: pid, activate: false)
                }
            }
            scheduleRetile()
        case .spaceChanged:
            handleActiveSpaceDidChange()
        }
    }

    public func applicationTerminated(pid: pid_t) {
        removeAppDriver(for: pid)
        for id in nativeTabs.keys where nativeTabs[id]?.pid == pid {
            nativeTabs.removeValue(forKey: id)
            strayTabs.remove(id)
        }
        let matchingIDs = Set(allRibbonWindows.filter { $0.pid == pid }.map { $0.id })
        for id in matchingIDs {
            trackedWindows.removeValue(forKey: id)
            lastAppliedFrames.removeValue(forKey: id)
            lastStashedState.removeValue(forKey: id)
            lastNaturalFrames.removeValue(forKey: id)
            originalFrames.removeValue(forKey: id)
            displayByWindowID.removeValue(forKey: id)
            spaceByWindowID.removeValue(forKey: id)
        }
        windowIDsByElement = windowIDsByElement.filter { !matchingIDs.contains($0.value) }
        persistOriginalFrames()
        for sID in ribbons.keys {
            ribbons[sID]?.removeWindows(pid: pid)
        }
        scheduleRetile()
    }
}
