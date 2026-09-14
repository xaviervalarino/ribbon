import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

public final class WindowManager: AXEventObserverDelegate {
    public var ribbon = Ribbon()
    public var config = Config.default
    private let observer = AXEventObserver()
    private let socketServer = SocketServer()
    private var trackedWindows: [CGWindowID: AXElement] = [:]
    private var adoptedSinceLastSweep: Set<CGWindowID> = []
    private var gcTimer: DispatchSourceTimer?

    public init() {
        observer.delegate = self
        // Reads live config on every check, so later config changes apply.
        observer.shouldObserve = { [weak self] app in
            guard let self, let name = app.localizedName else { return true }
            return !self.config.ignoredApps.contains(name)
        }
    }

    public func start() throws {
        print("[ribbon-daemon] Starting WindowManager...")

        // Start event observer
        observer.start()

        // Scan existing windows
        discoverExistingWindows()

        // Start IPC Socket Server; failures propagate — the caller owns exit policy
        socketServer.onCommand = { [weak self] cmd in
            return self?.handleCommand(cmd) ?? "error: daemon unavailable"
        }
        try socketServer.start()
        print("[ribbon-daemon] IPC Socket listening on \(socketServer.socketPath)")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(10), repeating: .seconds(10), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.sweepDeadWindows()
        }
        timer.resume()
        gcTimer = timer

        retile()
    }

    public func stop() {
        gcTimer?.cancel()
        gcTimer = nil
        observer.stop()
        socketServer.stop()
    }

    // MARK: - Window Discovery

    private func admits(_ win: AXElement) -> Bool {
        return win.role == (kAXWindowRole as String)
            && win.subrole == (kAXStandardWindowSubrole as String)
            && !win.isMinimized
            && !win.isFullscreen
    }

    private func discoverExistingWindows() {
        var discovered: [(win: AXElement, id: CGWindowID, pid: pid_t, appName: String, bundleId: String?, x: CGFloat)] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let appName = app.localizedName,
                  !config.ignoredApps.contains(appName) else { continue }

            let appElem = AXElement.application(pid: app.processIdentifier)
            for win in appElem.windows {
                guard admits(win) else { continue }
                guard let id = win.windowID else { continue }

                let x = win.position?.x ?? 0
                discovered.append((win: win, id: id, pid: app.processIdentifier, appName: appName, bundleId: app.bundleIdentifier, x: x))
            }
        }

        discovered.sort { $0.x < $1.x }

        for entry in discovered {
            trackedWindows[entry.id] = entry.win
            let model = WindowModel(
                id: entry.id,
                pid: entry.pid,
                bundleId: entry.bundleId,
                title: entry.win.title,
                appName: entry.appName
            )
            ribbon.addWindow(model, config: config)
            observer.observeWindowDestroyed(element: entry.win, pid: entry.pid)
            adoptedSinceLastSweep.insert(entry.id)
        }
    }

    // MARK: - Layout & Retile

    public func retile() {
        guard let screen = NSScreen.main else { return }
        // NSScreen coordinates have Y origin at bottom-left; WindowServer has Y origin at top-left
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cocoaFrame = screen.visibleFrame
        let windowServerFrame = CGRect(
            x: cocoaFrame.minX,
            y: primaryScreenHeight - cocoaFrame.maxY,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )

        let plan = LayoutEngine.computePlan(for: ribbon, screenFrame: windowServerFrame, config: config)

        var windowPID: [CGWindowID: pid_t] = [:]
        for col in ribbon.columns {
            for win in col.windows {
                windowPID[win.id] = win.pid
            }
        }

        var placementsByPID: [pid_t: [WindowPlacement]] = [:]
        for placement in plan.placements {
            guard let pid = windowPID[placement.windowID] else { continue }
            placementsByPID[pid, default: []].append(placement)
        }

        for (pid, placements) in placementsByPID {
            let appElem = AXElement.application(pid: pid)
            let wasEnhanced = appElem.enhancedUserInterface
            if wasEnhanced {
                appElem.enhancedUserInterface = false
            }
            for placement in placements {
                guard let elem = trackedWindows[placement.windowID] else { continue }
                if placement.isHidden {
                    elem.isHidden = true
                } else {
                    elem.isHidden = false
                    elem.setFrame(placement.frame)
                }
            }
            if wasEnhanced {
                appElem.enhancedUserInterface = true
            }
        }

        // Focus the active window
        if let active = ribbon.activeWindow, let elem = trackedWindows[active.id] {
            elem.focus()
        }
    }

    // MARK: - IPC Command Handling

    public func handleCommand(_ command: String) -> String {
        let parts = command.split(separator: " ").map(String.init)
        guard let action = parts.first?.lowercased() else { return "error: empty command" }

        switch action {
        case "focus":
            let dir = parts.dropFirst().first?.lowercased() ?? "right"
            switch dir {
            case "left", "h": ribbon.focusLeft()
            case "right", "l": ribbon.focusRight()
            case "up", "k": ribbon.focusUp()
            case "down", "j": ribbon.focusDown()
            default: return "error: unknown focus direction"
            }
        case "swap":
            let dir = parts.dropFirst().first?.lowercased() ?? "right"
            switch dir {
            case "left", "h": ribbon.swapLeft()
            case "right", "l": ribbon.swapRight()
            default: return "error: unknown swap direction"
            }
        case "cycle-width", "cycle":
            ribbon.cycleWidth(ratios: config.widthCycleRatios)
        case "slurp":
            ribbon.slurp()
        case "barf":
            ribbon.barf()
        case "status":
            return "columns: \(ribbon.columns.count), active: \(ribbon.activeColumnIndex)"
        default:
            return "error: unknown command '\(command)'"
        }

        retile()
        return "ok"
    }

    // MARK: - Window Adoption & Removal

    @discardableResult
    private func adopt(element: AXElement, pid: pid_t, activate: Bool) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let appName = app.localizedName,
              !config.ignoredApps.contains(appName) else { return false }
        guard admits(element) else { return false }
        guard let id = element.windowID else { return false }

        trackedWindows[id] = element
        let model = WindowModel(
            id: id,
            pid: pid,
            bundleId: app.bundleIdentifier,
            title: element.title,
            appName: appName
        )
        ribbon.addWindow(model, config: config, activate: activate)
        observer.observeWindowDestroyed(element: element, pid: pid)
        adoptedSinceLastSweep.insert(id)
        return true
    }

    private func removeFromRibbon(id: CGWindowID) {
        trackedWindows.removeValue(forKey: id)
        ribbon.removeWindow(id: id)
    }

    private func rescanAfterSpaceChange() {
        // 1. Build the set of currently-visible admitted window ids
        var visibleIDs = Set<CGWindowID>()
        var candidateWindows: [(win: AXElement, id: CGWindowID, pid: pid_t, x: CGFloat)] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  !app.isHidden,
                  let appName = app.localizedName,
                  !config.ignoredApps.contains(appName) else { continue }

            let pid = app.processIdentifier
            let appElem = AXElement.application(pid: pid)
            for win in appElem.windows {
                guard admits(win), let id = win.windowID else { continue }
                if visibleIDs.insert(id).inserted {
                    let x = win.position?.x ?? 0
                    candidateWindows.append((win: win, id: id, pid: pid, x: x))
                }
            }
        }

        // 2. Remove: every ribbon window whose id is NOT in that visible set (removeFromRibbon)
        let currentRibbonIDs = ribbon.columns.flatMap { $0.windows }.map(\.id)
        for id in currentRibbonIDs {
            if !visibleIDs.contains(id) {
                removeFromRibbon(id: id)
            }
        }

        // 3. Add: every visible admitted window whose id is NOT yet tracked — sort these new ones by x-position ascending, adopt(activate: false) each
        let newWindows = candidateWindows
            .filter { trackedWindows[$0.id] == nil }
            .sorted { $0.x < $1.x }
        for entry in newWindows {
            adopt(element: entry.win, pid: entry.pid, activate: false)
        }

        // 4. retile()
        retile()
    }

    // MARK: - Liveness GC

    private func sweepDeadWindows() {
        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [NSDictionary] else { return }
        var liveIDs = Set<CGWindowID>()
        for dict in windowList {
            if let num = dict[kCGWindowNumber as String] as? NSNumber {
                liveIDs.insert(num.uint32Value)
            }
        }

        var removedAny = false
        let currentIDs = ribbon.columns.flatMap { $0.windows }.map(\.id)
        for id in currentIDs {
            if adoptedSinceLastSweep.contains(id) { continue }
            if !liveIDs.contains(id) {
                removeFromRibbon(id: id)
                removedAny = true
            }
        }

        if removedAny {
            retile()
        }
        adoptedSinceLastSweep.removeAll()
    }

    // MARK: - AXEventObserverDelegate

    public func windowCreated(element: AXElement, pid: pid_t) {
        let isFrontmost = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        if adopt(element: element, pid: pid, activate: isFrontmost) {
            retile()
        }
    }

    public func windowDestroyed(element: AXElement, pid: pid_t) {
        guard let id = element.windowID else { return }
        removeFromRibbon(id: id)
        retile()
    }

    public func windowMinimized(element: AXElement, pid: pid_t) {
        guard let id = element.windowID else { return }
        removeFromRibbon(id: id)
        retile()
    }

    public func windowDeminiaturized(element: AXElement, pid: pid_t) {
        let isFrontmost = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        if adopt(element: element, pid: pid, activate: isFrontmost) {
            retile()
        }
    }

    public func windowFocused(element: AXElement, pid: pid_t) {
        guard let id = element.windowID else { return }
        // Update active column if focused window is tracked
        for (cIdx, col) in ribbon.columns.enumerated() {
            if let rIdx = col.windows.firstIndex(where: { $0.id == id }) {
                if ribbon.activeColumnIndex != cIdx || col.activeRowIndex != rIdx {
                    ribbon.activeColumnIndex = cIdx
                    var updatedCol = col
                    updatedCol.activeRowIndex = rIdx
                    ribbon.columns[cIdx] = updatedCol
                    retile()
                }
                break
            }
        }
    }

    public func applicationActivated(pid: pid_t) {
        if let focused = AXElement.application(pid: pid).focusedWindow {
            windowFocused(element: focused, pid: pid)
        }
    }

    public func applicationEventOccurred(kind: AppEventKind, pid: pid_t?) {
        switch kind {
        case .hidden:
            guard let pid = pid else { return }
            let windowIDs = ribbon.columns.flatMap { $0.windows }.filter { $0.pid == pid }.map(\.id)
            for id in windowIDs {
                removeFromRibbon(id: id)
            }
            retile()
        case .unhidden:
            guard let pid = pid else { return }
            for win in AXElement.application(pid: pid).windows {
                adopt(element: win, pid: pid, activate: false)
            }
            retile()
        case .spaceChanged:
            rescanAfterSpaceChange()
        }
    }

    public func applicationTerminated(pid: pid_t) {
        let matchingIDs = ribbon.columns.flatMap { $0.windows }.filter { $0.pid == pid }.map { $0.id }
        for id in matchingIDs {
            trackedWindows.removeValue(forKey: id)
        }
        ribbon.removeWindows(pid: pid)
        retile()
    }
}
