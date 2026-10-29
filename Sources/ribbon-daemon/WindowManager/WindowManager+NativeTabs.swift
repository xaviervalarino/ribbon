import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Native Tab Groups
//
// Each macOS native tab is its own window. Only the selected tab is ordered in, and every tab of
// a group shares the group's frame, so writing a frame to any tab moves the whole group. A group
// holds one ribbon slot, owned by its shown tab; hidden tabs live in `tabStates`.

/// Native-tab bookkeeping per window; a window has at most one state.
enum TabState {
    /// Ordered-out tab outside every ribbon and `trackedWindows`. `shownSinceMs` is set while it is
    /// on screen without a slot (a stray), from its first sighting.
    case hidden(element: AXElement, pid: pid_t, shownSinceMs: Double?)
    /// Tiled window seen ordered out since `sinceMs`; hidden once that holds for `tabConfirmMs`.
    case orderedOut(sinceMs: Double)
    /// Slot of a closed shown tab, held untracked until a tab of its group shows.
    case closedSlot(pid: pid_t, frame: CGRect, sinceMs: Double)
}

extension WindowManager {
    /// How long a window stays ordered out before it is hidden, or a hidden tab stays shown
    /// without a slot before it is adopted. A tab switch settles well inside it.
    var tabConfirmMs: Double { 500 }

    /// How long a closed tab's slot waits for its group's next tab to show.
    var closedTabHoldMs: Double { 300 }

    var nowMs: Double { CACurrentMediaTime() * 1000 }

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
        // A swap mid-slide leaves the old window's track writing its frame, which drags the group.
        if scrollAnimator.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                guard let self, !self.isStopped else { return }
                let current = pids.lazy.compactMap { self.stillFocused(focus, pid: $0) }.first
                self.reconcileNativeTabs(pids: pids, focus: current, confirmHides: confirmHides)
            }
            return
        }
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
        let now = nowMs
        var changed = false
        // A state first seen in this pass is confirmed by a pass of its own; the scheduled passes
        // and the 2s sweep may not see it again until long after, and a gap can hide a return.
        var confirmPIDs = Set<pid_t>()

        // An ordered-out window starts over when it dies.
        tabStates = tabStates.filter { id, state in
            if case .orderedOut = state { return liveIDs.contains(id) }
            return true
        }

        for pid in pids.sorted() {
            for id in hiddenTabIDs(pid: pid) where !liveIDs.contains(id) {
                tabStates[id] = nil
            }
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isHidden else { continue }

            let tiledIDs = allRibbonWindows.filter { $0.pid == pid }.map(\.id)
            let offTiled = tiledIDs.filter {
                liveIDs.contains($0) && isOrderedOutOnVisibleSpace($0, onScreen: onScreen, visibleSpaces: visibleSpaces)
            }.sorted()
            let pidTabs = hiddenTabIDs(pid: pid)
            let shownTabs = pidTabs.filter(onScreen.contains)

            // A stray tab hidden again starts over.
            for id in pidTabs where !onScreen.contains(id) {
                if case let .hidden(element, tabPID, _?) = tabStates[id] {
                    tabStates[id] = .hidden(element: element, pid: tabPID, shownSinceMs: nil)
                }
            }

            // An ordered-out window starts over when it shows again.
            for id in tiledIDs where !offTiled.contains(id) {
                dropOrderedOut(id)
            }

            var placed = Set<CGWindowID>()
            for old in offTiled {
                let candidates = shownTabs.filter { !placed.contains($0) }
                let oldBounds = boundsByID[old]
                // Tabs share their group's x and width. A size-only match stands only for the app's
                // single ordered-out window and single shown tab; with several, it can pick another
                // group's tab.
                let frameMatch = oldBounds.flatMap { oldBounds in
                    candidates.compactMap { id in boundsByID[id].map { (id, $0) } }
                        .closestInColumn(to: oldBounds)
                }
                let sizeMatch = offTiled.count == 1 && shownTabs.count == 1 ? candidates.first { candidate in
                    guard let oldSize = oldBounds?.size, let size = boundsByID[candidate]?.size else { return false }
                    return size.isNear(oldSize)
                } : nil
                let new = frameMatch ?? sizeMatch

                if let new, let element = hiddenTabElement(new) {
                    if swapTab(out: old, in: new, element: element, pid: pid, focus: focus) {
                        placed.insert(new)
                        changed = true
                    }
                } else if tiledIDs.contains(where: onScreen.contains) || pidsShowingWindows.contains(pid) {
                    // A closed tab's held slot waits for its group's next tab, not for a hide.
                    if closedSlot(old) != nil { continue }
                    if confirmHides {
                        let firstSeen: Double
                        if case let .orderedOut(sinceMs) = tabStates[old] {
                            firstSeen = sinceMs
                        } else {
                            firstSeen = now
                            tabStates[old] = .orderedOut(sinceMs: now)
                            confirmPIDs.insert(pid)
                        }
                        if now - firstSeen < tabConfirmMs { continue }
                    }
                    // An ordered-out tab or window returns through events or a stray pass once shown again.
                    hideTab(old, pid: pid)
                    changed = true
                }
            }

            for id in shownTabs where !placed.contains(id) {
                guard case let .hidden(element, _, shownSinceMs) = tabStates[id] else { continue }
                let firstSeen = shownSinceMs ?? now
                if shownSinceMs == nil {
                    tabStates[id] = .hidden(element: element, pid: pid, shownSinceMs: firstSeen)
                    confirmPIDs.insert(pid)
                }
                guard now - firstSeen >= tabConfirmMs else { continue }
                // `adopt` refuses a hidden tab, so the state goes first. A window adopt refuses (one
                // on all spaces) stays untracked rather than retried on every pass.
                tabStates[id] = nil
                if adopt(element: element, pid: pid, activate: id == focus || stillFocused(id, pid: pid) == id) {
                    RibbonLog.log("native tab adopted as window wid=\(id) pid=\(pid)", category: "tabs")
                    changed = true
                }
            }
        }

        if changed {
            scheduleRetile()
        }
        for pid in confirmPIDs {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(tabConfirmMs) + 50)) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.reconcileNativeTabs(pids: [pid], focus: self.stillFocused(focus, pid: pid))
            }
        }
    }

    /// Hands `old`'s ribbon slot to the tab `new` and marks `old` as a hidden tab. Tracks `new`
    /// directly: `upsertWindow` re-derives the space and can move the window to another ribbon.
    /// The slot's restore frame and minimum height move to `new`; `new`'s current frame is the
    /// tiled one, not its original.
    @discardableResult
    func swapTab(out old: CGWindowID, in new: CGWindowID, element: AXElement, pid: pid_t, focus: CGWindowID? = nil) -> Bool {
        let slotSID = spaceByWindowID[old] ?? ribbons.first(where: { entry in
            entry.value.columns.contains { $0.windows.contains { $0.id == old } }
        })?.key
        guard let sID = slotSID, var r = ribbons[sID] else { return false }

        let oldModel = r.columns.lazy.flatMap(\.windows).first { $0.id == old }
        let app = NSRunningApplication(processIdentifier: pid)
        var model = WindowModel(
            id: new,
            pid: pid,
            bundleId: app?.bundleIdentifier ?? oldModel?.bundleId,
            title: element.title,
            appName: app?.localizedName ?? oldModel?.appName ?? ""
        )
        model.minHeight = oldModel?.minHeight
        guard r.replaceWindow(id: old, with: model) else { return false }
        if new == focus {
            r.focus(windowID: new)
        }
        ribbons[sID] = r

        let oldElement = trackedWindows[old]
        let dID = displayByWindowID[old]
        // Until the next retile, a slide or a close of `new` reads the slot's strip state.
        lastNaturalFrames[new] = lastNaturalFrames[old]
        lastStashedState[new] = lastStashedState[old]
        removeFromRibbon(id: old)
        // A closed tab's slot has no element left; its state ends with the handover.
        tabStates[old] = oldElement.map { .hidden(element: $0, pid: pid, shownSinceMs: nil) }

        tabStates[new] = nil
        trackedWindows[new] = element
        windowIDsByElement[element.rawElement] = new
        spaceByWindowID[new] = sID
        if let dID {
            displayByWindowID[new] = dID
        }
        if let frame = originalFrames.removeValue(forKey: old) {
            originalFrames[new] = frame
            persistOriginalFrames()
        } else {
            rememberOriginalFrame(id: new, element: element)
        }
        observer.observeWindow(element: element, pid: pid)
        adoptedSinceLastSweep.insert(new)

        RibbonLog.log("native tab swap wid=\(old) -> \(new) pid=\(pid)", category: "tabs")
        return true
    }

    /// Drops an ordered-out window from its ribbon and marks it as a hidden tab until it shows again.
    func hideTab(_ id: CGWindowID, pid: pid_t) {
        if let element = trackedWindows[id] {
            tabStates[id] = .hidden(element: element, pid: pid, shownSinceMs: nil)
        }
        removeFromRibbon(id: id)
        RibbonLog.log("native tab hidden wid=\(id) pid=\(pid) spaces=\(SpaceManager.spaceIDs(for: id))", category: "tabs")
    }

    /// Keeps a closed tab's slot until its group's next tab shows, for up to `closedTabHoldMs`, and
    /// returns false when no hidden tab shares the slot's x and width (the group had one tab). The
    /// slot has no element meanwhile, so retiles skip it: the next tab may still be ordered out, and
    /// a frame written to a hidden tab moves its group. Focus and manual moves evict
    /// `lastAppliedFrames`; the slot's strip frame stands in unless the slot is stashed, where the
    /// group sits at its stash instead.
    func holdClosedTabSlot(_ id: CGWindowID, pid: pid_t) -> Bool {
        let stripFrame = lastStashedState[id] == true ? nil : lastNaturalFrames[id]
        guard var frame = lastAppliedFrames[id] ?? stripFrame else { return false }
        let frames = serverFrames(pid: pid)
        let hiddenIDs = hiddenTabIDs(pid: pid)
        guard !hiddenIDs.isEmpty else { return false }
        if !hiddenIDs.contains(where: { frames[$0]?.isSameColumn(frame) ?? false }) {
            // A tab closed mid-slide is reported after the slide, and its group stays where the
            // last step that reached it left it; the group's next tab already shows there. Slides
            // are horizontal, so the group keeps the slot's top and width.
            let onScreen = onScreenWindowIDs() ?? []
            let shownSameWidth = hiddenIDs.filter(onScreen.contains).compactMap { frames[$0] }
                .filter { abs($0.width - frame.width) <= 2 && abs($0.minY - frame.minY) <= 2 }
            guard shownSameWidth.count == 1 else { return false }
            frame = shownSameWidth[0]
        }
        if let element = trackedWindows.removeValue(forKey: id) {
            windowIDsByElement.removeValue(forKey: element.rawElement)
        }
        tabStates[id] = .closedSlot(pid: pid, frame: frame, sinceMs: nowMs)
        if !fillClosedTabSlot(id, shown: nil) {
            pollClosedTabSlot(id)
        }
        return true
    }

    /// Hands the app's held closed-tab slot at `shown`'s x and width to `shown`, a hidden tab that
    /// just took focus.
    func fillClosedTabSlot(pid: pid_t, shown: CGWindowID) {
        guard let shownFrame = serverFrames(pid: pid)[shown],
              let slot = tabStates.first(where: {
                  guard case let .closedSlot(slotPID, frame, _) = $0.value else { return false }
                  return slotPID == pid && frame.isSameColumn(shownFrame)
              })?.key
        else { return }
        fillClosedTabSlot(slot, shown: shown)
    }

    /// Hands the closed-tab slot to `shown`, else to a hidden tab of its group now on screen. False
    /// while no tab of the group has shown.
    @discardableResult
    private func fillClosedTabSlot(_ slot: CGWindowID, shown: CGWindowID?) -> Bool {
        guard let held = closedSlot(slot) else { return false }
        let candidate: CGWindowID?
        if let shown {
            candidate = shown
        } else {
            let onScreen = onScreenWindowIDs() ?? []
            let frames = serverFrames(pid: held.pid)
            candidate = hiddenTabIDs(pid: held.pid).filter(onScreen.contains)
                .compactMap { id in frames[id].map { (id, $0) } }
                .closestInColumn(to: held.frame)
        }
        guard let new = candidate, let element = hiddenTabElement(new) else { return false }
        tabStates[slot] = nil
        if swapTab(out: slot, in: new, element: element, pid: held.pid, focus: shown) {
            scheduleTabReconcile(pid: held.pid)
        } else {
            removeFromRibbon(id: slot)
        }
        scheduleRetile()
        return true
    }

    private func pollClosedTabSlot(_ id: CGWindowID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            guard let self, !self.isStopped, let held = self.closedSlot(id) else { return }
            if self.fillClosedTabSlot(id, shown: nil) { return }
            guard self.nowMs - held.sinceMs >= self.closedTabHoldMs else {
                self.pollClosedTabSlot(id)
                return
            }
            self.tabStates[id] = nil
            self.removeFromRibbon(id: id)
            // The group's tab that shows late joins as a stray; it keeps the group's restore frame.
            if let original = self.originalFrames[id] {
                let frames = self.serverFrames(pid: held.pid)
                for tab in self.hiddenTabIDs(pid: held.pid) where frames[tab]?.isSameColumn(held.frame) ?? false {
                    self.originalFrames[tab] = self.originalFrames[tab] ?? original
                }
            }
            self.forgetOriginalFrame(id: id)
            self.scheduleRetile()
            self.scheduleTabReconcile(pid: held.pid)
        }
    }

    /// Reconciles the app's tabs once its tab switch or window creation has settled. Each pass
    /// focuses `focus` only while it is still its active app's front window.
    func scheduleTabReconcile(pid: pid_t, focus: CGWindowID? = nil) {
        for ms in [100, 300, 800] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.reconcileNativeTabs(pids: [pid], focus: self.stillFocused(focus, pid: pid))
            }
        }
    }

    /// `focus` while its app is active and it is the app's front window, else nil. A delayed pass
    /// passes its captured focus through this, so a click or cmd-tab since then keeps its focus.
    func stillFocused(_ focus: CGWindowID?, pid: pid_t) -> CGWindowID? {
        guard let focus, NSRunningApplication(processIdentifier: pid)?.isActive == true,
              frontmostWindowID(pid: pid) == focus else { return nil }
        return focus
    }

    /// Gives a new window its group's slot when it is a native tab: at once when the sibling has
    /// ordered out, else held as a hidden tab until the reconcile passes see it do so. False for
    /// an ordinary window, which the caller adopts. True for a window its focus event already
    /// tracked or held: adopting it again re-derives its space and can move it.
    func claimNewTab(_ element: AXElement, id: CGWindowID, pid: pid_t, focus: CGWindowID?) -> Bool {
        guard trackedWindows[id] == nil, !isHiddenTab(id) else { return true }
        guard let sibling = tabSibling(of: id, pid: pid) else { return false }
        if sibling.orderedOut, swapTab(out: sibling.id, in: id, element: element, pid: pid, focus: focus) {
            scheduleTabReconcile(pid: pid)
            scheduleRetile()
            return true
        }
        let frame = serverFrame(id)?.logDescription ?? "none"
        RibbonLog.log("native tab candidate wid=\(id) sibling=\(sibling.id) frame=\(frame)", category: "tabs")
        tabStates[id] = .hidden(element: element, pid: pid, shownSinceMs: nil)
        observer.observeWindow(element: element, pid: pid)
        scheduleTabReconcile(pid: pid, focus: focus)
        return true
    }

    /// The tiled window that new window `id` is a tab of. Showing a new tab orders its group's shown
    /// tab out, so an app's tiled window ordered out on a visible space at the new window's origin
    /// and width is the sibling, swapped at once (`orderedOut`). A lone ordered-out window of the
    /// new window's size at another origin, or a tiled window at the same frame within 2pt, makes
    /// the new window a candidate that the reconcile settles; Ribbon writes nothing to it
    /// meanwhile. Otherwise the window is ordinary: macOS cascades a genuine new window to a
    /// different origin.
    func tabSibling(of id: CGWindowID, pid: pid_t) -> (id: CGWindowID, orderedOut: Bool)? {
        let tiled = Set(allRibbonWindows.filter { $0.pid == pid && $0.id != id }.map(\.id)).sorted()
        guard !tiled.isEmpty, let onScreen = onScreenWindowIDs() else { return nil }
        let frames = serverFrames(pid: pid)
        let frame = frames[id]

        let appHidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? true
        let visibleSpaces = Set(SpaceManager.currentTopology().activeSpaceByDisplay.values)
        let orderedOut: [(id: CGWindowID, frame: CGRect)] = appHidden ? [] : tiled.compactMap { tiledID in
            guard let tiledFrame = frames[tiledID],
                  isOrderedOutOnVisibleSpace(tiledID, onScreen: onScreen, visibleSpaces: visibleSpaces) else { return nil }
            return (tiledID, tiledFrame)
        }

        if let frame, let match = orderedOut.first(where: { $0.frame.isSameColumn(frame) }) {
            return (match.id, true)
        }
        if orderedOut.count == 1, let frame, orderedOut[0].frame.size.isNear(frame.size) {
            return (orderedOut[0].id, false)
        }
        if let frame, let match = tiled.first(where: { frames[$0]?.isNear(frame) ?? false }) {
            return (match, false)
        }

        if !orderedOut.isEmpty {
            let out = orderedOut.map { "\($0.id):\($0.frame.logDescription)" }.joined(separator: ", ")
            RibbonLog.log("native tab check wid=\(id) frame=\(frame?.logDescription ?? "none") no sibling among ordered out [\(out)]", category: "tabs")
        }
        return nil
    }

    /// True for a window that is off screen while its space is visible. A window moved to another
    /// space reports only that space; it is not ordered out.
    private func isOrderedOutOnVisibleSpace(_ id: CGWindowID, onScreen: Set<CGWindowID>, visibleSpaces: Set<SpaceID>) -> Bool {
        guard !onScreen.contains(id), let sID = spaceByWindowID[id], visibleSpaces.contains(sID) else { return false }
        let spaces = SpaceManager.spaceIDs(for: id)
        return spaces.isEmpty || spaces.contains(where: visibleSpaces.contains)
    }

    func hiddenTabElement(_ id: CGWindowID) -> AXElement? {
        guard case let .hidden(element, _, _) = tabStates[id] else { return nil }
        return element
    }

    func isHiddenTab(_ id: CGWindowID) -> Bool {
        if case .hidden = tabStates[id] { return true }
        return false
    }

    /// Drops the hidden tab whose element is `element`; false when none matches. A destroyed
    /// element no longer answers its window ID, so it matches by element.
    @discardableResult
    func dropHiddenTab(for element: AXElement) -> Bool {
        let match = tabStates.first { _, state in
            guard case let .hidden(tabElement, _, _) = state else { return false }
            return CFEqual(tabElement.rawElement, element.rawElement)
        }
        guard let id = match?.key else { return false }
        tabStates[id] = nil
        return true
    }

    func dropOrderedOut(_ id: CGWindowID) {
        if case .orderedOut = tabStates[id] {
            tabStates[id] = nil
        }
    }

    /// The pid's hidden tabs in ascending window ID order.
    func hiddenTabIDs(pid: pid_t) -> [CGWindowID] {
        tabStates.compactMap { id, state in
            guard case let .hidden(_, tabPID, _) = state, tabPID == pid else { return nil }
            return id
        }.sorted()
    }

    func closedSlot(_ id: CGWindowID) -> (pid: pid_t, frame: CGRect, sinceMs: Double)? {
        guard case let .closedSlot(pid, frame, sinceMs) = tabStates[id] else { return nil }
        return (pid, frame, sinceMs)
    }
}

extension Array where Element == (CGWindowID, CGRect) {
    /// The window sharing `frame`'s x and width whose top is nearest `frame`'s. Same-app tab groups
    /// stacked in one column share x and width and differ only in y.
    func closestInColumn(to frame: CGRect) -> CGWindowID? {
        filter { $0.1.isSameColumn(frame) }
            .min { abs($0.1.minY - frame.minY) < abs($1.1.minY - frame.minY) }?.0
    }
}

extension CGSize {
    /// True when both dimensions differ from `other` by at most 2pt.
    func isNear(_ other: CGSize) -> Bool {
        abs(width - other.width) <= 2 && abs(height - other.height) <= 2
    }
}

extension CGRect {
    /// "x,y WxH" in whole points, for logs.
    var logDescription: String {
        "\(Int(minX)),\(Int(minY)) \(Int(width))x\(Int(height))"
    }

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
