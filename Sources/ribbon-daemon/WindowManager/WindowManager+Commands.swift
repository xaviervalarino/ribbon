import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

extension WindowManager {
    // MARK: - Focus

    func expectFocusEcho(id: CGWindowID, pid: pid_t, ms: Int) {
        let deadline = DispatchTime.now() + .milliseconds(ms)
        pendingFocusEchoes[id] = deadline
        pendingFocusEchoPIDs[pid] = deadline
    }

    func focusWindowDirectly(id: CGWindowID) {
        guard let elem = trackedWindows[id],
              let pid = ribbons.values.lazy
                .flatMap({ $0.columns.flatMap(\.windows) })
                .first(where: { $0.id == id })?.pid else { return }
        AppDriver.focusRequested(id)
        expectFocusEcho(id: id, pid: pid, ms: 150)
        NSRunningApplication(processIdentifier: pid)?.activate()
        elem.focus()
    }

    private func targetDisplayIndex(arg: String?, currentIdx: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let a = arg?.lowercased() ?? "next"
        if a == "prev" || a == "previous" {
            return (currentIdx - 1 + count) % count
        } else if let num = Int(a), num >= 0, num < count {
            return num
        } else {
            return (currentIdx + 1) % count
        }
    }

    func migrateWindow(id: CGWindowID, toSpace targetSID: SpaceID, display targetDID: CGDirectDisplayID) {
        let oldSID = spaceByWindowID[id] ?? currentActiveSpaceID()
        var winModel: WindowModel?

        if var oldR = ribbons[oldSID] {
            if let col = oldR.columns.first(where: { $0.windows.contains(where: { $0.id == id }) }) {
                winModel = col.windows.first(where: { $0.id == id })
            }
            oldR.removeWindow(id: id)
            ribbons[oldSID] = oldR
        }

        guard let win = winModel else { return }

        var targetR = ribbons[targetSID] ?? Ribbon()
        targetR.addWindow(win, config: config, activate: true)
        ribbons[targetSID] = targetR

        displayByWindowID[id] = targetDID
        spaceByWindowID[id] = targetSID
        displayBySpaceID[targetSID] = targetDID
    }

    // MARK: - IPC Command Handling

    /// Tracked ribbon windows currently on screen, snapshotted on the main thread for debug probes.
    private func debugProbeTargets() -> [DebugProbes.Target] {
        let onScreen = onScreenWindowIDs() ?? []
        return ribbons.values.flatMap { $0.columns.flatMap(\.windows) }.compactMap { win in
            guard onScreen.contains(win.id), let elem = trackedWindows[win.id] else { return nil }
            let app = NSRunningApplication(processIdentifier: win.pid)?.localizedName ?? "pid \(win.pid)"
            return DebugProbes.Target(id: win.id, pid: win.pid, app: app, element: elem)
        }
    }

    /// Tracking state and what AX returns per app, to locate where discovery drops windows.
    private func debugStateDump() -> String {
        let topology = SpaceManager.currentTopology()
        var lines = [
            "axTrusted=\(AXIsProcessTrusted()) tracked=\(trackedWindows.count) currentSpace=\(currentActiveSpaceID())",
            "topology active=\(topology.activeSpaceByDisplay) spaces=\(topology.displayBySpace.keys.sorted())",
            "ribbons: " + ribbons.map { "\($0.key):\($0.value.columns.count)" }.sorted().joined(separator: " "),
        ]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let appElem = AXElement.application(pid: app.processIdentifier)
            let wins = appElem.windows
            let admitted = wins.filter { admits($0) }.count
            lines.append("  \(app.localizedName ?? "?") pid=\(app.processIdentifier) hidden=\(app.isHidden) axWindows=\(wins.count) admitted=\(admitted)")
        }
        return lines.joined(separator: "\n")
    }

    /// Every AX window of the apps matching `appFilter`, with the attributes a float rule can key
    /// on. Run it while the window in question is open to see what sets it apart.
    private func debugInspect(appFilter: String?) -> String {
        let buttons = [
            ("close", kAXCloseButtonAttribute), ("minimize", kAXMinimizeButtonAttribute),
            ("zoom", kAXZoomButtonAttribute), ("fullscreen", kAXFullScreenButtonAttribute),
        ]
        var lines: [String] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let name = app.localizedName ?? "?"
            if let filter = appFilter, !name.lowercased().contains(filter.lowercased()) { continue }
            let appElem = AXElement.application(pid: app.processIdentifier)
            var windows = appElem.windows.map { (win: $0, listed: true) }
            // A popup can be missing from AXWindows yet reach the ribbon as the focused window.
            if let focused = appElem.focusedWindow,
               !windows.contains(where: { $0.win.windowID == focused.windowID }) {
                windows.append((win: focused, listed: false))
            }
            for (win, listed) in windows {
                let id = win.windowID
                let frame = win.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
                let present = buttons.filter { win.hasValue($0.1) }.map(\.0).joined(separator: ",")
                lines.append(
                    "\(name) pid=\(app.processIdentifier) wid=\(id.map(String.init) ?? "?") title=\"\(win.title)\""
                    + " role=\(win.role) subrole=\(win.subrole) frame=\(frame)"
                    + " sizeSettable=\(win.isSettable(kAXSizeAttribute)) modal=\(win.bool(kAXModalAttribute) ?? false)"
                    + " buttons=\(present.isEmpty ? "none" : present)"
                    + " admitted=\(admits(win)) inRibbon=\(id.map { spaceByWindowID[$0] != nil } ?? false)"
                    + (listed ? "" : " (focused, not in AXWindows)")
                )
            }
        }
        return lines.isEmpty ? "no windows" + (appFilter.map { " for '\($0)'" } ?? "") : lines.joined(separator: "\n")
    }

    /// Live-tunes slide settings for side-by-side comparison; a daemon restart resets them.
    private func applyDebugSetting(_ args: [String]) -> String {
        guard args.count == 2 else { return "error: debug set resize-mode|slide-ms|focus-timing <value>" }
        let value = args[1].lowercased()
        switch args[0].lowercased() {
        case "resize-mode":
            guard let mode = ResizeMode(rawValue: value) else { return "error: resize-mode end|instant|grow-first" }
            config.resizeMode = mode
        case "slide-ms":
            guard let ms = Int(value), ms >= 0 else { return "error: slide-ms <milliseconds, 0 disables>" }
            config.scrollAnimationMs = ms
        case "focus-timing":
            guard let timing = FocusTiming(rawValue: value) else { return "error: focus-timing start|end" }
            config.focusTiming = timing
        default:
            return "error: unknown setting '\(args[0])'"
        }
        return "ok"
    }

    /// The screen showing `sID`: its recorded display, else the active one, else the main screen.
    private func screen(forSpace sID: SpaceID) -> NSScreen? {
        screen(forDisplayID: displayBySpaceID[sID] ?? activeDisplayID ?? NSScreen.main?.displayID ?? 0)
    }

    /// Canvas width of the display showing `sID`, as `windowResized` measures it.
    private func canvasWidth(forSpace sID: SpaceID) -> Double? {
        guard let screen = screen(forSpace: sID) else { return nil }
        let width = screen.visibleFrame.width - (config.edgeMargin * 2)
        return width > 0 ? width : nil
    }

    /// Opens the screenshot grid for space `sID` on its display. Cells come from the overview
    /// layout of a copy of the ribbon, so the real ribbon never enters overview.
    private func openScreenshotGrid(forSpace sID: SpaceID) {
        guard var copy = ribbons[sID], !copy.columns.isEmpty, let screen = screen(forSpace: sID) else { return }
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let visible = QuartzGeometry.toQuartzRect(cocoaFrame: screen.visibleFrame, primaryScreenHeight: primaryHeight)
        let display = QuartzGeometry.toQuartzRect(cocoaFrame: screen.frame, primaryScreenHeight: primaryHeight)
        copy.isOverview = true
        let plan = LayoutEngine.computePlan(for: copy, screenFrame: visible, config: config)
        let frames = serverFrames()
        let thumbnails = plan.placements.map { placement in
            ScreenshotGrid.Thumbnail(
                id: placement.windowID,
                windowFrame: frames[placement.windowID] ?? lastAppliedFrames[placement.windowID] ?? placement.frame,
                cell: placement.frame
            )
        }
        screenshotGrid.open(selection: copy, spaceID: sID, thumbnails: thumbnails,
                            screen: screen, displayFrame: display.cgRect)
    }

    public func handleCommand(_ command: String) -> String {
        if command.lowercased().hasPrefix("debug") {
            let args = command.split(separator: " ").dropFirst().map(String.init)
            switch args.first?.lowercased() {
            case "set":
                return applyDebugSetting(Array(args.dropFirst()))
            case "state":
                return debugStateDump()
            case "inspect":
                return debugInspect(appFilter: args.dropFirst().first)
            case "settings":
                return "resize-mode=\(config.resizeMode.rawValue) slide-ms=\(config.scrollAnimationMs) focus-timing=\(config.focusTiming.rawValue)"
            default:
                break
            }
            return DebugProbes.run(command.split(separator: " ").dropFirst().map(String.init), targets: debugProbeTargets())
        }
        // Commands act on the ribbon's own active column: macOS focus lags while the previous
        // command's activation is in flight. Clicks reach the ribbon as focus events.
        let sID = currentActiveSpaceID()

        let parts = command.split(separator: " ").map(String.init)
        guard let action = parts.first?.lowercased() else { return "error: empty command" }

        let beforeRibbon = ribbons[sID] ?? Ribbon()
        let previousActive = beforeRibbon.activeWindow?.id
        RibbonLog.log(
            "CMD '\(command)' on space=\(sID) display=\(displayBySpaceID[sID] ?? 0) cols=\(beforeRibbon.columns.count) activeCol=\(beforeRibbon.activeColumnIndex) activeWin=\(previousActive ?? 0)",
            category: "cmd"
        )

        // While the grid is open, `focus` moves its selection and `overview` closes it onto the
        // selected window; every other command closes it first and runs as usual.
        if screenshotGrid.isOpen {
            switch action {
            case "focus":
                let dir = parts.dropFirst().first?.lowercased() ?? "right"
                return screenshotGrid.moveSelection(dir, perRow: config.overviewColumnsPerRow)
                    ? "ok" : "error: unknown focus direction"
            case "toggle-overview", "overview":
                if parts.count == 1 {
                    closeScreenshotGrid(focusSelection: true)
                    return "ok"
                }
                screenshotGrid.close()
            case "status":
                break
            default:
                screenshotGrid.close()
            }
        }

        switch action {
        case "focus":
            let dir = parts.dropFirst().first?.lowercased() ?? "right"
            var r = ribbon
            guard r.focus(direction: dir, perRow: config.overviewColumnsPerRow) else {
                return "error: unknown focus direction"
            }
            ribbon = r
        case "swap", "move":
            ribbon.isOverview = false
            let dir = parts.dropFirst().first?.lowercased() ?? "right"
            switch dir {
            case "left", "h": ribbon.swapLeft()
            case "right", "l": ribbon.swapRight()
            case "up", "k": ribbon.swapUp()
            case "down", "j": ribbon.swapDown()
            case "first": ribbon.moveFirst()
            case "last": ribbon.moveLast()
            default: return "error: unknown swap direction"
            }
        case "grow", "shrink":
            ribbon.isOverview = false
            guard let dir = parts.dropFirst().first?.lowercased(), dir == "left" || dir == "right" else {
                return "error: unknown \(action) direction"
            }
            var step = config.widthStep
            if parts.count > 2 {
                guard let parsed = Double(parts[2]), parsed > 0 else {
                    return "error: \(action) step must be a positive number"
                }
                step = parsed
            }
            let appliedDelta = ribbon.adjustWidth(by: action == "grow" ? step : -step)
            // The left variants keep the column's right edge in place by scrolling with the change;
            // a column against the canvas's left edge has no room to scroll and grows rightward.
            if dir == "left", let canvasW = canvasWidth(forSpace: sID) {
                // Column widths scale with the canvas plus one gap (see columnGeometry).
                ribbon.viewportOffset = max(0.0, ribbon.viewportOffset + appliedDelta * (canvasW + config.windowGap))
            }
        case "align":
            ribbon.isOverview = false
            guard let dir = parts.dropFirst().first?.lowercased(),
                  let alignment = LayoutEngine.ViewportAlignment(rawValue: dir) else {
                return "error: unknown alignment"
            }
            if let canvasW = canvasWidth(forSpace: sID) {
                ribbon.viewportOffset = LayoutEngine.alignedOffset(
                    for: ribbon,
                    canvasWidth: canvasW,
                    config: config,
                    alignment: alignment
                )
            }
        case "cycle-width", "cycle":
            ribbon.isOverview = false
            ribbon.cycleWidth(ratios: config.widthCycleRatios)
        case "slurp":
            ribbon.isOverview = false
            ribbon.slurp()
        case "barf":
            ribbon.isOverview = false
            ribbon.barf()
        case "toggle-overview", "overview":
            switch parts.dropFirst().first?.lowercased() {
            case "resize":
                ribbon.toggleOverview()
            case nil:
                // Plain `overview` leaves the resize overview when it is up, so one key exits both.
                if ribbon.isOverview {
                    ribbon.isOverview = false
                } else {
                    openScreenshotGrid(forSpace: sID)
                    return "ok"
                }
            default:
                return "error: unknown overview mode"
            }
        case "focus-display":
            let screens = NSScreen.screens
            guard screens.count > 1 else { return "ok" }
            let currentIdx = screens.firstIndex(where: { $0.displayID == activeDisplayID }) ?? 0
            let nextIdx = targetDisplayIndex(arg: parts.dropFirst().first, currentIdx: currentIdx, count: screens.count)
            let targetDID = screens[nextIdx].displayID
            let targetSID = currentActiveSpaceID(forDisplayID: targetDID)
            activeDisplayID = targetDID
            activeSpaceID = targetSID
            displayBySpaceID[targetSID] = targetDID
            if let win = ribbons[targetSID]?.activeWindow, let elem = trackedWindows[win.id] {
                AppDriver.focusRequested(win.id)
                expectFocusEcho(id: win.id, pid: win.pid, ms: 150)
                NSRunningApplication(processIdentifier: win.pid)?.activate()
                elem.focus()
            }
            return "ok"
        case "move-to-display":
            let screens = NSScreen.screens
            guard screens.count > 1 else { return "ok" }
            let currentSID = currentActiveSpaceID()
            guard let currentR = ribbons[currentSID],
                  let activeWin = currentR.activeWindow else { return "ok" }
            let currentDID = activeDisplayID ?? NSScreen.main?.displayID ?? 0

            let currentIdx = screens.firstIndex(where: { $0.displayID == currentDID }) ?? 0
            let nextIdx = targetDisplayIndex(arg: parts.dropFirst().first, currentIdx: currentIdx, count: screens.count)
            let targetDID = screens[nextIdx].displayID
            let targetSID = currentActiveSpaceID(forDisplayID: targetDID)

            migrateWindow(id: activeWin.id, toSpace: targetSID, display: targetDID)
            activeDisplayID = targetDID
            activeSpaceID = targetSID

            retileNow(focusWindowID: ribbon.activeWindow?.id)
            return "ok"
        case "retile":
            retileNow()
            return "ok"
        case "rescan":
            handleActiveSpaceDidChange()
            return "ok"
        case "status":
            let dCount = NSScreen.screens.count
            let actD = activeDisplayID ?? NSScreen.main?.displayID ?? 0
            let actS = currentActiveSpaceID()
            return "screens: \(dCount), display: \(actD), space: \(actS), columns: \(ribbon.columns.count), active: \(ribbon.activeColumnIndex), overview: \(ribbon.isOverview), grid: \(screenshotGrid.isOpen)"
        case "restart":
            DispatchQueue.main.async { [weak self] in
                self?.restart()
            }
            return "restarting"
        case "quit", "stop":
            DispatchQueue.main.async { [weak self] in
                self?.stop(forRestart: false)
                exit(0)
            }
            return "ok"
        default:
            return "error: unknown command '\(command)'"
        }

        let afterRibbon = ribbons[sID] ?? Ribbon()
        RibbonLog.log(
            "AFTER '\(command)' on space=\(sID): cols=\(afterRibbon.columns.count) activeCol=\(afterRibbon.activeColumnIndex) widths=\(afterRibbon.columns.map { String(format: "%.2f(exp:%@)", $0.widthRatio, String($0.hasExplicitSingleWidth)) })",
            category: "cmd"
        )

        let newActive = ribbon.activeWindow?.id
        retileNow(focusWindowID: newActive != previousActive ? newActive : nil, animated: true)

        return "ok"
    }

    /// Closes the grid. With `focusSelection`, `windowID` (the grid's selection when nil) becomes
    /// the active window of the ribbon the grid opened for and is focused through the retile path,
    /// as a `focus` command focuses. The grid closes before the focus, so the focus events it
    /// causes find the grid closed.
    func closeScreenshotGrid(focusSelection: Bool, windowID: CGWindowID? = nil) {
        let selected = windowID ?? screenshotGrid.selectedWindowID
        let spaceID = screenshotGrid.spaceID
        screenshotGrid.close()
        guard focusSelection, let id = selected, let sID = spaceID,
              var r = ribbons[sID], r.focus(windowID: id) else { return }
        ribbons[sID] = r
        retileNow(focusWindowID: id, animated: true)
    }
}
