import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Native Tab Groups
//
// Each macOS native tab is its own window. Only the selected tab is ordered in, and every tab of
// a group shares the group's frame, so writing a frame to any tab moves the whole group. A group
// holds one ribbon slot, owned by its shown tab; hidden tabs live in `nativeTabs`.

extension WindowManager {
    /// How long a window stays ordered out before it is hidden, or a hidden tab stays shown
    /// without a slot before it is adopted. A tab switch settles well inside it.
    var tabConfirmMs: Double { 500 }

    /// How long a new window of the frontmost app waits untiled for a sibling tab to order out.
    var newTabWaitMs: Double { 300 }

    /// Swaps each tiled window of `pids` that is ordered out for its group's shown tab, hides an
    /// ordered-out window while its app shows another window, and adopts a hidden tab shown
    /// without a slot. Hiding and adopting wait until the state has held for `tabConfirmMs`;
    /// `confirmHides: false` hides at once. Mid space switch, a window can read as ordered out
    /// while its space still reads as visible. Costs one `.optionAll` and one on-screen window
    /// list read; pass `windowList` to reuse an `.optionAll` list read moments earlier.
    func reconcileNativeTabs(
        pids: Set<pid_t>,
        focus: CGWindowID? = nil,
        confirmHides: Bool = true,
        windowList precomputedList: [NSDictionary]? = nil
    ) {
        guard !isDisplayReconfiguring, !pids.isEmpty else { return }
        guard let windowList = precomputedList
                ?? CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [NSDictionary],
              let onScreen = onScreenWindowIDs() else { return }

        var liveIDs = Set<CGWindowID>()
        var boundsByID: [CGWindowID: CGRect] = [:]
        var pidsShowingWindows = Set<pid_t>()
        for dict in windowList {
            guard let num = dict[kCGWindowNumber as String] as? NSNumber else { continue }
            let id = num.uint32Value
            liveIDs.insert(id)
            guard let owner = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pids.contains(owner) else { continue }
            if let bounds = dict[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: bounds) {
                boundsByID[id] = rect
            }
            if onScreen.contains(id), (dict[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
                pidsShowingWindows.insert(owner)
            }
        }
        guard !liveIDs.isEmpty else { return }

        let visibleSpaces = Set(SpaceManager.currentTopology().activeSpaceByDisplay.values)
        let now = CACurrentMediaTime() * 1000
        var changed = false

        for pid in pids.sorted() {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isHidden else { continue }

            for id in nativeTabIDs(pid: pid) where !liveIDs.contains(id) {
                dropNativeTab(id)
            }

            let tiledIDs = allRibbonWindows.filter { $0.pid == pid }.map(\.id)
            // A window moved to another space reports only that space; it is not a tab.
            let offTiled = tiledIDs.filter { id in
                guard liveIDs.contains(id), !onScreen.contains(id),
                      let sID = spaceByWindowID[id], visibleSpaces.contains(sID) else { return false }
                let spaces = SpaceManager.spaceIDs(for: id)
                return spaces.isEmpty || spaces.contains(where: visibleSpaces.contains)
            }.sorted()
            let pidTabs = nativeTabIDs(pid: pid)
            let shownTabs = pidTabs.filter(onScreen.contains)

            // A stray tab hidden again starts over.
            for id in pidTabs where !onScreen.contains(id) {
                strayTabs.removeValue(forKey: id)
            }

            // An ordered-out window starts over when it shows again or dies.
            hideCandidates = hideCandidates.filter { entry in
                liveIDs.contains(entry.key) && (!tiledIDs.contains(entry.key) || offTiled.contains(entry.key))
            }

            var placed = Set<CGWindowID>()
            for old in offTiled {
                let candidates = shownTabs.filter { !placed.contains($0) }
                let oldBounds = boundsByID[old]
                // Tabs share their group's x and width. A size-only match stands only for the app's
                // single shown tab; with several, it can pick another group's tab.
                let frameMatch = candidates.first { candidate in
                    guard let oldBounds, let bounds = boundsByID[candidate] else { return false }
                    return bounds.isSameColumn(oldBounds)
                }
                let sizeMatch = shownTabs.count == 1 ? candidates.first { candidate in
                    guard let oldSize = oldBounds?.size, let size = boundsByID[candidate]?.size else { return false }
                    return size.isNear(oldSize)
                } : nil
                let new = frameMatch ?? sizeMatch

                if let new, let tab = nativeTabs[new] {
                    if swapTab(out: old, in: new, element: tab.element, pid: pid, focus: focus) {
                        placed.insert(new)
                        changed = true
                    }
                } else if tiledIDs.contains(where: onScreen.contains) || pidsShowingWindows.contains(pid) {
                    if confirmHides {
                        let firstSeen = hideCandidates[old] ?? now
                        hideCandidates[old] = firstSeen
                        if now - firstSeen < tabConfirmMs { continue }
                    }
                    // An ordered-out tab or window returns through events or a stray pass once shown again.
                    hideTab(old, pid: pid)
                    changed = true
                }
            }

            for id in shownTabs where !placed.contains(id) {
                guard let tab = nativeTabs[id] else { continue }
                let firstSeen = strayTabs[id] ?? now
                strayTabs[id] = firstSeen
                guard now - firstSeen >= tabConfirmMs else { continue }
                dropNativeTab(id)
                if adopt(element: tab.element, pid: pid, activate: id == focus) {
                    RibbonLog.log("native tab adopted as window wid=\(id) pid=\(pid)", category: "tabs")
                    changed = true
                }
            }
        }

        if changed {
            scheduleRetile()
        }
    }

    /// Hands `old`'s ribbon slot to the tab `new` and moves `old` into `nativeTabs`. Tracks `new`
    /// directly: `upsertWindow` re-derives the space and can move the window to another ribbon.
    @discardableResult
    func swapTab(out old: CGWindowID, in new: CGWindowID, element: AXElement, pid: pid_t, focus: CGWindowID? = nil) -> Bool {
        let slotSID = spaceByWindowID[old] ?? ribbons.first(where: { entry in
            entry.value.columns.contains { $0.windows.contains { $0.id == old } }
        })?.key
        guard let sID = slotSID, var r = ribbons[sID] else { return false }

        let oldModel = r.columns.lazy.flatMap(\.windows).first { $0.id == old }
        let app = NSRunningApplication(processIdentifier: pid)
        let model = WindowModel(
            id: new,
            pid: pid,
            bundleId: app?.bundleIdentifier ?? oldModel?.bundleId,
            title: element.title,
            appName: app?.localizedName ?? oldModel?.appName ?? ""
        )
        guard r.replaceWindow(id: old, with: model) else { return false }
        if new == focus {
            r.focus(windowID: new)
        }
        ribbons[sID] = r

        let oldElement = trackedWindows[old]
        let dID = displayByWindowID[old]
        removeFromRibbon(id: old)
        if let oldElement {
            nativeTabs[old] = (element: oldElement, pid: pid)
        }

        dropNativeTab(new)
        trackedWindows[new] = element
        windowIDsByElement[element.rawElement] = new
        spaceByWindowID[new] = sID
        if let dID {
            displayByWindowID[new] = dID
        }
        rememberOriginalFrame(id: new, element: element)
        observer.observeWindow(element: element, pid: pid)
        adoptedSinceLastSweep.insert(new)

        RibbonLog.log("native tab swap wid=\(old) -> \(new) pid=\(pid)", category: "tabs")
        return true
    }

    /// Drops an ordered-out window from its ribbon and keeps it in `nativeTabs` until it shows again.
    func hideTab(_ id: CGWindowID, pid: pid_t) {
        if let element = trackedWindows[id] {
            nativeTabs[id] = (element: element, pid: pid)
        }
        removeFromRibbon(id: id)
        RibbonLog.log("native tab hidden wid=\(id) pid=\(pid) spaces=\(SpaceManager.spaceIDs(for: id))", category: "tabs")
    }

    /// Holds a new window that opened at a tiled sibling's frame as a hidden tab; the reconcile
    /// passes give it its group's slot once macOS orders the sibling out.
    func holdTabCandidate(_ element: AXElement, id: CGWindowID, sibling: CGWindowID, pid: pid_t, focus: CGWindowID?) {
        let frame = serverFrame(id).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none"
        RibbonLog.log("native tab candidate wid=\(id) sibling=\(sibling) frame=\(frame)", category: "tabs")
        nativeTabs[id] = (element: element, pid: pid)
        observer.observeWindow(element: element, pid: pid)
        scheduleTabReconcile(pid: pid, focus: focus)
    }

    /// Reconciles the app's tabs once its tab switch or window creation has settled.
    func scheduleTabReconcile(pid: pid_t, focus: CGWindowID? = nil) {
        for ms in [100, 300, 800] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.reconcileNativeTabs(pids: [pid], focus: focus)
            }
        }
    }

    /// Gives a new window its group's slot when it is a native tab: at once when the sibling has
    /// ordered out, else held until the reconcile sees it do so. A new window of the frontmost app
    /// waits untiled for up to `newTabWaitMs`, since the shown tab orders out shortly after its new
    /// tab is created. False for an ordinary window, which the caller adopts.
    func claimNewTab(_ element: AXElement, id: CGWindowID, pid: pid_t, focus: CGWindowID?) -> Bool {
        // A tab its focus event already claimed holds a slot; claiming it again would move it.
        guard trackedWindows[id] == nil, nativeTabs[id] == nil else { return false }
        if pendingNewWindows[id] != nil { return true }
        if let sibling = tabSibling(of: id, frame: serverFrame(id) ?? element.frame, pid: pid) {
            settleNewTab(element, id: id, sibling: sibling, pid: pid, focus: focus)
            return true
        }
        guard focus != nil, allRibbonWindows.contains(where: { $0.pid == pid }) else { return false }
        pendingNewWindows[id] = (element: element, pid: pid, focus: focus, sinceMs: CACurrentMediaTime() * 1000)
        let format = { (r: CGRect) in "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
        let tiled = allRibbonWindows.filter { $0.pid == pid }.map { "\($0.id):\(serverFrame($0.id).map(format) ?? "none")" }
        RibbonLog.log("new window wid=\(id) frame=\(element.frame.map(format) ?? "none") waits; app tiles [\(tiled.joined(separator: ", "))]", category: "tabs")
        pollNewWindow(id)
        return true
    }

    private func settleNewTab(_ element: AXElement, id: CGWindowID, sibling: (id: CGWindowID, orderedOut: Bool), pid: pid_t, focus: CGWindowID?) {
        if sibling.orderedOut, swapTab(out: sibling.id, in: id, element: element, pid: pid, focus: focus) {
            scheduleTabReconcile(pid: pid)
            scheduleRetile()
        } else {
            holdTabCandidate(element, id: id, sibling: sibling.id, pid: pid, focus: focus)
        }
    }

    /// Checks a waiting new window every 25ms: a sibling ordering out makes it a tab; at the end of
    /// the wait it is adopted as an ordinary window.
    private func pollNewWindow(_ id: CGWindowID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            guard let self, !self.isStopped, let pending = self.pendingNewWindows[id] else { return }
            let waitedMs = Int(CACurrentMediaTime() * 1000 - pending.sinceMs)
            // Another path adopted it meanwhile; its own slot stands.
            if self.trackedWindows[id] != nil || self.nativeTabs[id] != nil {
                self.pendingNewWindows.removeValue(forKey: id)
                return
            }
            // WindowServer's frame: an AX read waits behind the app creating the tab.
            if let sibling = self.tabSibling(of: id, frame: self.serverFrame(id), pid: pending.pid) {
                self.pendingNewWindows.removeValue(forKey: id)
                RibbonLog.log("native tab wid=\(id) sibling=\(sibling.id) orderedOut=\(sibling.orderedOut) after \(waitedMs)ms", category: "tabs")
                self.settleNewTab(pending.element, id: id, sibling: sibling, pid: pending.pid, focus: pending.focus)
                return
            }
            guard Double(waitedMs) >= self.newTabWaitMs else {
                self.pollNewWindow(id)
                return
            }
            self.pendingNewWindows.removeValue(forKey: id)
            RibbonLog.log("new window wid=\(id) pid=\(pending.pid) is not a tab after \(waitedMs)ms", category: "tabs")
            // A click or cmd-tab during the wait moved focus elsewhere; the window then tiles unfocused.
            let stillFocused = pending.focus != nil
                && NSRunningApplication(processIdentifier: pending.pid)?.isActive == true
                && self.frontmostWindowID(pid: pending.pid) == id
            if self.adopt(element: pending.element, pid: pending.pid, activate: stillFocused) {
                self.scheduleRetile()
            }
            self.scheduleTabReconcile(pid: pending.pid)
        }
    }

    /// The tiled window that new window `id` is a tab of. Showing a new tab orders its group's shown
    /// tab out, so an app's tiled window ordered out on a visible space at the new window's origin
    /// and width is the sibling, swapped at once (`orderedOut`). A lone ordered-out
    /// window at another frame, or a tiled window at the same frame within 2pt, makes the new window
    /// a candidate that the reconcile settles; Ribbon writes nothing to it meanwhile. Otherwise the
    /// window is ordinary: macOS cascades a genuine new window to a different origin.
    func tabSibling(of id: CGWindowID, frame: CGRect?, pid: pid_t) -> (id: CGWindowID, orderedOut: Bool)? {
        let tiled = Set(allRibbonWindows.filter { $0.pid == pid && $0.id != id }.map(\.id)).sorted()
        guard !tiled.isEmpty, let onScreen = onScreenWindowIDs() else { return nil }

        let appHidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? true
        let visibleSpaces = Set(SpaceManager.currentTopology().activeSpaceByDisplay.values)
        // A window moved to another space reports only that space; it is not ordered out.
        let orderedOut: [(id: CGWindowID, frame: CGRect)] = appHidden ? [] : tiled.compactMap { tiledID in
            guard !onScreen.contains(tiledID), let sID = spaceByWindowID[tiledID], visibleSpaces.contains(sID),
                  let tiledFrame = serverFrame(tiledID) else { return nil }
            let spaces = SpaceManager.spaceIDs(for: tiledID)
            guard spaces.isEmpty || spaces.contains(where: visibleSpaces.contains) else { return nil }
            return (tiledID, tiledFrame)
        }

        if let frame, let match = orderedOut.first(where: { $0.frame.isSameColumn(frame) }) {
            return (match.id, true)
        }
        if orderedOut.count == 1 {
            return (orderedOut[0].id, false)
        }
        if let frame, let match = tiled.first(where: { serverFrame($0)?.isNear(frame) ?? false }) {
            return (match, false)
        }

        if !orderedOut.isEmpty {
            let format = { (r: CGRect) in "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
            let out = orderedOut.map { "\($0.id):\(format($0.frame))" }.joined(separator: ", ")
            RibbonLog.log("native tab check wid=\(id) frame=\(frame.map(format) ?? "none") no sibling among ordered out [\(out)]", category: "tabs")
        }
        return nil
    }

    /// The pid's hidden tabs in ascending window ID order.
    func nativeTabIDs(pid: pid_t) -> [CGWindowID] {
        nativeTabs.filter { $0.value.pid == pid }.keys.sorted()
    }

    func dropNativeTab(_ id: CGWindowID) {
        nativeTabs.removeValue(forKey: id)
        strayTabs.removeValue(forKey: id)
    }
}

extension CGSize {
    /// True when both dimensions differ from `other` by at most 2pt.
    func isNear(_ other: CGSize) -> Bool {
        abs(width - other.width) <= 2 && abs(height - other.height) <= 2
    }
}

extension CGRect {
    /// True when origin x and width each differ from `other` by at most 2pt. A tab group's frame
    /// keeps its x and width as tabs come and go; a tab bar showing can change its height.
    func isSameColumn(_ other: CGRect) -> Bool {
        abs(minX - other.minX) <= 2 && abs(width - other.width) <= 2
    }

    /// True when origin and size each differ from `other` by at most 2pt.
    func isNear(_ other: CGRect) -> Bool {
        abs(minX - other.minX) <= 2 && abs(minY - other.minY) <= 2 && size.isNear(other.size)
    }
}
