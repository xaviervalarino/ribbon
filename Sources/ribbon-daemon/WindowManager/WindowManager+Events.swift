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

// MARK: - AXEventObserverDelegate

extension WindowManager: AXEventObserverDelegate {
    public func windowCreated(element: AXElement, pid: pid_t) {
        let isFrontmost = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
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
    }

    public func windowDestroyed(element: AXElement, pid: pid_t) {
        guard let id = element.windowID
            ?? windowIDsByElement[element.rawElement]
            ?? trackedWindows.first(where: { CFEqual($0.value.rawElement, element.rawElement) })?.key
        else { return }
        removeFromRibbon(id: id)
        forgetOriginalFrame(id: id)
        scheduleRetile()
    }

    public func windowMinimized(element: AXElement, pid: pid_t) {
        guard let id = element.windowID
            ?? windowIDsByElement[element.rawElement]
            ?? trackedWindows.first(where: { CFEqual($0.value.rawElement, element.rawElement) })?.key
        else { return }
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
        guard let id = element.windowID
            ?? windowIDsByElement[element.rawElement]
            ?? trackedWindows.first(where: { CFEqual($0.value.rawElement, element.rawElement) })?.key
        else { return }

        let now = DispatchTime.now()
        pendingFrameEchoes = pendingFrameEchoes.filter { $0.value >= now }
        if let deadline = pendingFrameEchoes[id], deadline >= now {
            if let last = lastAppliedFrames[id], let sz = element.size {
                if abs(last.size.width - sz.width) < 2.0 && abs(last.size.height - sz.height) < 2.0 {
                    return
                }
            }
        }

        guard let newSize = element.size else { return }
        let sID = spaceByWindowID[id] ?? currentActiveSpaceID()
        let dID = displayByWindowID[id] ?? NSScreen.main?.displayID ?? activeDisplayID ?? 0
        guard let screen = screen(forDisplayID: dID) else { return }

        if let last = lastAppliedFrames[id], abs(last.size.width - newSize.width) < 2.0 {
            return
        }

        let canvasW = screen.visibleFrame.width - (config.edgeMargin * 2)
        guard canvasW > 0 else { return }

        let ratio = max(0.15, min(1.0, Double(newSize.width) / Double(canvasW)))
        resizeDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeDebounceWork = nil
            if var r = self.ribbons[sID] {
                if r.setWidthRatio(ratio, forWindowID: id) {
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
        guard let id = element.windowID
            ?? windowIDsByElement[element.rawElement]
            ?? trackedWindows.first(where: { CFEqual($0.value.rawElement, element.rawElement) })?.key
        else { return }

        let now = DispatchTime.now()
        pendingFrameEchoes = pendingFrameEchoes.filter { $0.value >= now }
        if let deadline = pendingFrameEchoes[id], deadline >= now {
            if let last = lastAppliedFrames[id], let pos = element.position {
                if abs(last.origin.x - pos.x) < 2.0 && abs(last.origin.y - pos.y) < 2.0 {
                    return
                }
            }
        }

        // Check if window crossed display boundary
        if let pos = element.position, let sz = element.size {
            let currentFrame = CGRect(origin: pos, size: sz)
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
        guard let id = element.windowID else { return }

        let now = DispatchTime.now()
        pendingFocusEchoes = pendingFocusEchoes.filter { $0.value >= now }
        if pendingFocusEchoes.removeValue(forKey: id) != nil {
            return
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
                    ribbons[sID] = r
                    if isVisibleSpace {
                        scheduleRetile()
                    }
                }
            }
        }
    }

    public func applicationActivated(pid: pid_t) {
        let onScreen = onScreenWindowIDs()
        let app = AXElement.application(pid: pid)
        let candidate: AXElement? = {
            if let focused = app.focusedWindow,
               let id = focused.windowID,
               onScreen?.contains(id) ?? true {
                return focused
            }
            return app.windows.first { win in
                guard let id = win.windowID else { return false }
                return onScreen?.contains(id) ?? false
            }
        }()

        if let focused = candidate {
            windowFocused(element: focused, pid: pid)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                guard let self, !self.isStopped else { return }
                let onScreenRetry = self.onScreenWindowIDs()
                let retryApp = AXElement.application(pid: pid)
                let retryCandidate: AXElement? = {
                    if let focused = retryApp.focusedWindow,
                       let id = focused.windowID,
                       onScreenRetry?.contains(id) ?? true {
                        return focused
                    }
                    return retryApp.windows.first { win in
                        guard let id = win.windowID else { return false }
                        return onScreenRetry?.contains(id) ?? false
                    }
                }()
                if let focused = retryCandidate {
                    self.windowFocused(element: focused, pid: pid)
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
        let matchingIDs = Set(allRibbonWindows.filter { $0.pid == pid }.map { $0.id })
        for id in matchingIDs {
            trackedWindows.removeValue(forKey: id)
            lastAppliedFrames.removeValue(forKey: id)
            lastStashedState.removeValue(forKey: id)
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
