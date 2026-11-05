import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

extension WindowManager {
    // MARK: - Space Change Handling

    public func handleActiveSpaceDidChange() {
        screenshotGrid.close()
        guard !isDisplayReconfiguring else { return }
        panController.endPan(snap: false)

        let topology = SpaceManager.currentTopology()
        for (sID, dID) in topology.displayBySpace {
            displayBySpaceID[sID] = dID
        }

        // Space changes during a drag defer reconciliation and retiling until mouse-up.
        if inputTap.isRunning && CGEventSource.buttonState(.combinedSessionState, button: .left) {
            dragDirty = true
            if !spaceChangeDeferred {
                spaceChangeDeferred = true
                RibbonLog.log("space change deferred to drag end", category: "drag")
            }
            return
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
        let isAdmitted = admits(element)
        // A new tab opens at its group's frame. Adopting it as a column would move the whole group.
        if isAdmitted, let id = element.windowID, claimNewTab(element, id: id, pid: pid, focus: isFrontmost ? id : nil) {
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
        if isAdmitted && hasTiledWindow {
            scheduleTabReconcile(pid: pid)
        }
    }

    public func windowDestroyed(element: AXElement, pid: pid_t) {
        if dropHiddenTab(for: element) { return }
        guard let id = trackedWindowID(for: element) else { return }

        // Closing a shown tab shows another tab of its group, which takes over the slot and its
        // restore frame once shown.
        if holdClosedTabSlot(id, pid: pid) {
            return
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
        // A minimize can read as ordered out and hide the window as a tab; it returns as a window.
        dropHiddenTab(for: element)
        if adopt(element: element, pid: pid, activate: isFrontmost) {
            scheduleRetile()
        }
    }

    public func windowResized(element: AXElement, pid: pid_t) {
        guard !isDisplayReconfiguring else { return }
        // A hidden tab follows its group's frame; its resize is not a manual one.
        guard let id = trackedWindowID(for: element), !isHiddenTab(id) else { return }

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
            // Apps settle a few points off the width they are given (terminals round to a cell,
            // UTM to its display); adopting that as a manual resize starts a resize loop.
            if let last = self.lastAppliedFrames[id], abs(last.size.width - newSize.width) < 16 {
                return
            }
            // The inverse of columnGeometry's width: ratio × (canvas + gap) − gap.
            let gap = self.config.windowGap
            let ratio = max(0.15, min(1.0, (Double(newSize.width) + gap) / (Double(canvasW) + gap)))
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
        guard let id = trackedWindowID(for: element), !isHiddenTab(id) else { return }

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
                    if isDragging {
                        if draggingWindowID != id {
                            RibbonLog.log("drag started wid=\(id)", category: "drag")
                            draggingWindowID = id
                        }
                        dragDirty = true
                    } else {
                        scheduleRetile()
                    }
                    return
                }
            }
        }

        // Manual move: mark dirty in diff cache; keyboard retiles snap it back,
        // but avoid fighting the mouse cursor mid-drag.
        lastAppliedFrames.removeValue(forKey: id)
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            if draggingWindowID != id {
                RibbonLog.log("drag started wid=\(id)", category: "drag")
                draggingWindowID = id
            }
            dragDirty = true
        }
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
        // A focus the ribbon did not request (a click elsewhere, a new window) leaves the grid
        // without focusing its selection.
        closeScreenshotGrid(focusSelection: false)

        // A tab switch focuses a hidden tab: it takes over its group's slot, never a new column.
        if isHiddenTab(id) {
            fillClosedTabSlot(pid: pid, shown: id)
            reconcileNativeTabs(pids: [pid], focus: id)
            if spaceByWindowID[id] == nil {
                scheduleTabReconcile(pid: pid, focus: id)
                return
            }
        }

        // The cached frame stays: an animated click retile slides from it (a parked window from its
        // parking spot), and windowMoved evicts it when the user drags the window.

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
                // A new tab's focus event can arrive before its creation event.
                if claimNewTab(element, id: id, pid: pid, focus: id) {
                    return
                }
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
                        scheduleRetile(animated: true)
                    }
                }
            }
        }
    }

    public func applicationActivated(pid: pid_t) {
        // An activation the ribbon did not cause (Cmd-Tab, a click on another app, an ignored app
        // included) leaves the grid without focusing its selection.
        let isEcho = pendingFocusEchoPIDs[pid].map { $0 >= observer.currentEventTime } ?? false
        if !isEcho {
            closeScreenshotGrid(focusSelection: false)
        }
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
        case .unhidden, .observedLate:
            guard let pid = pid else { return }
            let onScreen = onScreenWindowIDs()
            for win in AXElement.application(pid: pid).windows {
                if let id = win.windowID, onScreen?.contains(id) ?? true {
                    adopt(element: win, pid: pid, activate: false)
                }
            }
            scheduleRetile()
            // A launch's activation found no window yet; its front window takes focus now.
            if kind == .observedLate, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                applicationActivated(pid: pid)
            }
        case .spaceChanged:
            handleActiveSpaceDidChange()
        }
    }

    public func applicationTerminated(pid: pid_t) {
        removeAppDriver(for: pid)
        let matchingIDs = Set(allRibbonWindows.filter { $0.pid == pid }.map { $0.id })
        tabStates = tabStates.filter { id, state in
            switch state {
            case let .hidden(_, tabPID, _), let .closedSlot(tabPID, _, _):
                return tabPID != pid
            case .orderedOut:
                return !matchingIDs.contains(id)
            }
        }
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

// MARK: - InputTapDelegate

extension WindowManager: InputTapDelegate {
    func mouseUp() {
        draggingWindowID = nil
        // A click mid-pan ends it without the snap's focus, so the click's own focus event stands;
        // the retile slides the strip back to the active column instead of leaving the pan offset.
        if panController.isPanning {
            panController.endPan(snap: false)
            retileNow(animated: true)
        }
        guard dragDirty else { return }
        dragDirty = false
        let spaceChanged = spaceChangeDeferred
        spaceChangeDeferred = false
        RibbonLog.log("drag ended: \(spaceChanged ? "space change" : "retile")", category: "drag")
        let finish = { [weak self] in
            guard let self else { return }
            if spaceChanged {
                self.handleActiveSpaceDidChange()
            } else {
                self.scheduleRetile()
            }
        }
        // An edge drag that moved the origin also resized: retiling before the resize debounce
        // measures the new width writes the old width back and the debounce then sees no change.
        if resizeDebounceWork != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: finish)
        } else {
            finish()
        }
    }

    func pointerMoved(dx: Double) {
        panController.handleMotion(dx: dx)
    }

    /// Virtual key codes of h/j/k/l and the arrow keys, by grid direction. Key codes name key
    /// positions, so h/j/k/l keep their places under any keyboard layout.
    private static let gridKeyDirections: [Int64: String] = [
        Int64(kVK_ANSI_H): "left", Int64(kVK_LeftArrow): "left",
        Int64(kVK_ANSI_J): "down", Int64(kVK_DownArrow): "down",
        Int64(kVK_ANSI_K): "up", Int64(kVK_UpArrow): "up",
        Int64(kVK_ANSI_L): "right", Int64(kVK_RightArrow): "right",
    ]

    /// Drives the open grid: Esc closes it, Return or keypad Enter focuses the selection, and
    /// h/j/k/l and the arrows move it. Other keys do nothing; the tap already swallowed them.
    func keyDown(keyCode: Int64) {
        guard screenshotGrid.isOpen else { return }
        switch keyCode {
        case Int64(kVK_Escape):
            closeScreenshotGrid(focusSelection: false)
        case Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter):
            closeScreenshotGrid(focusSelection: true)
        default:
            if let direction = Self.gridKeyDirections[keyCode] {
                _ = screenshotGrid.moveSelection(direction)
            }
        }
    }

    func setTouchesProbe(_ on: Bool) {
        touchesProbe.bucketTimer?.cancel()
        touchesProbe.bucketTimer = nil
        touchesProbe.endWork?.cancel()
        touchesProbe.endWork = nil

        if !on {
            if touchesProbe.isArmed {
                flushTouchesProbeBucket()
                touchesProbe = TouchesProbeState()
                inputTap.setGestureMonitoring(false)
                RibbonLog.log("touches probe off", category: "input")
            }
            return
        }

        flushTouchesProbeBucket()
        touchesProbe = TouchesProbeState(isArmed: true)
        inputTap.setGestureMonitoring(true)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.flushTouchesProbeBucket()
        }
        timer.resume()
        touchesProbe.bucketTimer = timer

        let endWork = DispatchWorkItem { [weak self] in
            self?.setTouchesProbe(false)
        }
        touchesProbe.endWork = endWork
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(10), execute: endWork)
    }

    private func flushTouchesProbeBucket() {
        guard touchesProbe.events > 0 || touchesProbe.swipes > 0 else { return }
        let dxText = String(format: "%.3f", touchesProbe.dx)
        RibbonLog.log(
            "touches=\(touchesProbe.maxTouches) events=\(touchesProbe.events) dx=\(dxText) swipes=\(touchesProbe.swipes) swipeDX=\(touchesProbe.swipeDX)",
            category: "input"
        )
        touchesProbe.maxTouches = 0
        touchesProbe.events = 0
        touchesProbe.dx = 0
        touchesProbe.swipes = 0
        touchesProbe.swipeDX = 0
    }

    func gesture(_ event: CGEvent) {
        guard touchesProbe.isArmed, let nsEvent = NSEvent(cgEvent: event) else { return }
        let touches = nsEvent.touches(matching: .touching, in: nil).filter { $0.type == .indirect }
        let count = touches.count
        let meanX: Double? = count > 0
            ? touches.reduce(0.0) { $0 + Double($1.normalizedPosition.x) } / Double(count)
            : nil
        if count > 0, count == touchesProbe.lastTouchCount, let meanX, let prevX = touchesProbe.lastMeanX {
            touchesProbe.dx += meanX - prevX
        }
        touchesProbe.lastTouchCount = count
        touchesProbe.lastMeanX = meanX
        touchesProbe.events += 1
        touchesProbe.maxTouches = max(touchesProbe.maxTouches, count)
    }

    func swipe(_ event: CGEvent) {
        guard touchesProbe.isArmed, let nsEvent = NSEvent(cgEvent: event) else { return }
        touchesProbe.swipes += 1
        touchesProbe.swipeDX += Double(nsEvent.deltaX)
    }
}
