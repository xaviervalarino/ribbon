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
    /// Swaps each tiled window of `pids` that is ordered out for its group's shown tab, hides an
    /// ordered-out window while its app shows another window, and adopts a hidden tab seen on
    /// screen without a slot on two consecutive passes. Hiding also takes two consecutive passes
    /// unless `confirmHides` is false: mid space switch, a window can read as ordered out while
    /// its space still reads as visible. Costs one `.optionAll` and one on-screen window list
    /// read; pass `windowList` to reuse an `.optionAll` list read moments earlier.
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

            // A tab marked stray on an earlier pass and hidden since starts over.
            strayTabs.subtract(pidTabs.filter { !onScreen.contains($0) })

            // A window seen ordered out once starts over when it shows again or dies.
            hideCandidates = hideCandidates.filter { liveIDs.contains($0) && (!tiledIDs.contains($0) || offTiled.contains($0)) }

            var placed = Set<CGWindowID>()
            for old in offTiled {
                let candidates = shownTabs.filter { !placed.contains($0) }
                let oldSize = boundsByID[old]?.size
                let new = candidates.first { candidate in
                    guard let oldSize, let size = boundsByID[candidate]?.size else { return false }
                    return size.isNear(oldSize)
                } ?? candidates.first

                if let new, let tab = nativeTabs[new] {
                    if swapTab(out: old, in: new, element: tab.element, pid: pid, focus: focus) {
                        placed.insert(new)
                        hideCandidates.remove(old)
                        changed = true
                    }
                } else if tiledIDs.contains(where: onScreen.contains) || pidsShowingWindows.contains(pid) {
                    if confirmHides && hideCandidates.insert(old).inserted { continue }
                    // An ordered-out tab or window returns through events or a stray pass once shown again.
                    hideCandidates.remove(old)
                    hideTab(old, pid: pid)
                    changed = true
                }
            }

            for id in shownTabs where !placed.contains(id) {
                guard let tab = nativeTabs[id] else { continue }
                if strayTabs.contains(id) {
                    dropNativeTab(id)
                    if adopt(element: tab.element, pid: pid, activate: id == focus) {
                        RibbonLog.log("native tab adopted as window wid=\(id) pid=\(pid)", category: "tabs")
                        changed = true
                    }
                } else {
                    strayTabs.insert(id)
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
        RibbonLog.log("native tab hidden wid=\(id) pid=\(pid)", category: "tabs")
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

    /// The app's tiled window whose frame matches `element` within 2pt. Tabs share their group's
    /// frame; macOS cascades a genuine new window to a different origin.
    func tabSibling(of element: AXElement, pid: pid_t) -> CGWindowID? {
        guard let frame = element.frame else { return nil }
        let ownID = cachedWindowID(for: element)
        let candidates = allRibbonWindows.filter { $0.pid == pid && $0.id != ownID }.map(\.id).sorted()
        return candidates.first { id in
            guard let tiled = serverFrame(id) else { return false }
            return abs(tiled.minX - frame.minX) <= 2 && abs(tiled.minY - frame.minY) <= 2
                && tiled.size.isNear(frame.size)
        }
    }

    /// The pid's hidden tabs in ascending window ID order.
    func nativeTabIDs(pid: pid_t) -> [CGWindowID] {
        nativeTabs.filter { $0.value.pid == pid }.keys.sorted()
    }

    func dropNativeTab(_ id: CGWindowID) {
        nativeTabs.removeValue(forKey: id)
        strayTabs.remove(id)
    }
}

extension CGSize {
    /// True when both dimensions differ from `other` by at most 2pt.
    func isNear(_ other: CGSize) -> Bool {
        abs(width - other.width) <= 2 && abs(height - other.height) <= 2
    }
}
