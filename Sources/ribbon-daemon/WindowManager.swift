import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard let userInfo = userInfo else { return }
    // Ignore the begin phase; wait until the end phase when hardware & WindowServer bounds are updated
    if flags.contains(.beginConfigurationFlag) { return }
    let wm = Unmanaged<WindowManager>.fromOpaque(userInfo).takeUnretainedValue()
    if wm.isStopped { return }
    if flags.contains(.setModeFlag) || flags.contains(.addFlag) || flags.contains(.removeFlag) || flags.contains(.desktopShapeChangedFlag) {
        DispatchQueue.main.async {
            guard !wm.isStopped else { return }
            wm.displayConfigurationChanged()
        }
    }
}

public final class WindowManager: AXEventObserverDelegate {
    public var ribbons: [CGDirectDisplayID: Ribbon] = [:]
    public var activeDisplayID: CGDirectDisplayID?
    private var displayByWindowID: [CGWindowID: CGDirectDisplayID] = [:]

    public var activeRibbon: Ribbon {
        get {
            if let id = activeDisplayID, let r = ribbons[id] {
                return r
            }
            if let id = NSScreen.main?.displayID, let r = ribbons[id] {
                return r
            }
            if let first = ribbons.first {
                return first.value
            }
            return Ribbon()
        }
        set {
            let id = activeDisplayID ?? NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID ?? 0
            ribbons[id] = newValue
            activeDisplayID = id
        }
    }

    public var ribbon: Ribbon {
        get { activeRibbon }
        set { activeRibbon = newValue }
    }

    private var allRibbonWindows: [WindowModel] {
        return ribbons.values.flatMap { $0.columns.flatMap { $0.windows } }
    }

    public var config = Config.default
    private let observer = AXEventObserver()
    private let socketServer = SocketServer()
    private var trackedWindows: [CGWindowID: AXElement] = [:]
    private var windowIDsByElement: [AXUIElement: CGWindowID] = [:]
    private var adoptedSinceLastSweep: Set<CGWindowID> = []
    private var gcTimer: DispatchSourceTimer?
    private var retileWork: DispatchWorkItem?
    private var resizeDebounceWork: DispatchWorkItem?
    private var spaceChangeWork: DispatchWorkItem?
    private var displayReconfigWork: DispatchWorkItem?
    private var screenParametersObserver: NSObjectProtocol?
    private var lastAppliedFrames: [CGWindowID: CGRect] = [:]
    private var lastStashedState: [CGWindowID: Bool] = [:]
    private var pendingFocusEchoes: [CGWindowID: DispatchTime] = [:]
    private var pendingFrameEchoes: [CGWindowID: DispatchTime] = [:]
    private var originalFrames: [CGWindowID: CGRect] = [:]
    fileprivate var isStopped = false

    private var restoreFramesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("ribbon")
            .appendingPathComponent("restore-frames.json")
    }

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

        // A leftover restore file means the previous daemon crashed. Load its
        // entries so windows keep their true pre-daemon frames instead of
        // adopting the crashed run's tiled frames as "originals".
        loadPersistedOriginalFrames()

        isStopped = false

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
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.sweepDeadWindows()
        }
        timer.resume()
        gcTimer = timer

        // Registered last so a throwing start() never leaves a dangling
        // callback pointer behind after the caller exits.
        CGDisplayRegisterReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.displayConfigurationChanged()
        }

        retile()
    }

    private func loadPersistedOriginalFrames() {
        guard let data = try? Data(contentsOf: restoreFramesURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] else { return }
        for (key, values) in dict {
            guard let id = CGWindowID(key), values.count == 4 else { continue }
            originalFrames[id] = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
    }

    public func stop() {
        isStopped = true
        gcTimer?.cancel()
        gcTimer = nil
        retileWork?.cancel()
        retileWork = nil
        resizeDebounceWork?.cancel()
        resizeDebounceWork = nil
        spaceChangeWork?.cancel()
        spaceChangeWork = nil
        displayReconfigWork?.cancel()
        displayReconfigWork = nil
        if let obs = screenParametersObserver {
            NotificationCenter.default.removeObserver(obs)
            screenParametersObserver = nil
        }
        observer.stop()

        var windowPID: [CGWindowID: pid_t] = [:]
        for win in allRibbonWindows {
            windowPID[win.id] = win.pid
        }

        var restoreFrames: [(id: CGWindowID, pid: pid_t, frame: CGRect, isStashed: Bool)] = []
        for (id, _) in trackedWindows {
            guard let pid = windowPID[id], let orig = originalFrames[id] else { continue }
            restoreFrames.append((id: id, pid: pid, frame: orig, isStashed: false))
        }

        // The diff cache may be stale (manual drags); never skip restores.
        lastAppliedFrames.removeAll()
        applyFrames(restoreFrames)

        if FileManager.default.fileExists(atPath: restoreFramesURL.path) {
            try? FileManager.default.removeItem(at: restoreFramesURL)
        }

        CGDisplayRemoveReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        socketServer.stop()
    }

    func displayConfigurationChanged() {
        displayReconfigWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isStopped else { return }
            self.displayReconfigWork = nil

            let activeIDs = Set(NSScreen.screens.map { $0.displayID })
            let primaryID = NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID ?? 0

            // Migrate any windows from disconnected displays to the primary display
            for (dID, r) in self.ribbons where !activeIDs.contains(dID) {
                for col in r.columns {
                    for win in col.windows {
                        var primaryR = self.ribbons[primaryID] ?? Ribbon()
                        primaryR.addWindow(win, config: self.config)
                        self.ribbons[primaryID] = primaryR
                        self.displayByWindowID[win.id] = primaryID
                    }
                }
                self.ribbons.removeValue(forKey: dID)
            }

            if self.activeDisplayID == nil || !activeIDs.contains(self.activeDisplayID!) {
                self.activeDisplayID = primaryID
            }

            self.lastAppliedFrames.removeAll()
            self.scheduleRetile()
        }
        displayReconfigWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    // MARK: - Debounced Retile

    private func scheduleRetile() {
        if retileWork != nil { return }
        let work = DispatchWorkItem { [weak self] in
            self?.retileWork = nil
            self?.retile()
        }
        retileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
    }

    // MARK: - Window Discovery

    private func admits(_ win: AXElement) -> Bool {
        return win.role == (kAXWindowRole as String)
            && win.subrole == (kAXStandardWindowSubrole as String)
            && !win.isMinimized
            && !win.isFullscreen
    }

    private func onScreenWindowIDs() -> Set<CGWindowID>? {
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

    private func discoverExistingWindows() {
        let onScreen = onScreenWindowIDs()
        var discovered: [(win: AXElement, id: CGWindowID, pid: pid_t, appName: String, bundleId: String?, x: CGFloat, frame: CGRect)] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let appName = app.localizedName,
                  !config.ignoredApps.contains(appName) else { continue }

            let appElem = AXElement.application(pid: app.processIdentifier)
            for win in appElem.windows {
                guard admits(win) else { continue }
                guard let id = win.windowID else { continue }
                if let onScreen = onScreen, !onScreen.contains(id) { continue }

                let frame = win.frame ?? CGRect.zero
                if originalFrames[id] == nil {
                    originalFrames[id] = frame
                }

                discovered.append((win: win, id: id, pid: app.processIdentifier, appName: appName, bundleId: app.bundleIdentifier, x: frame.origin.x, frame: frame))
            }
        }

        discovered.sort { $0.x < $1.x }

        for entry in discovered {
            trackedWindows[entry.id] = entry.win
            windowIDsByElement[entry.win.rawElement] = entry.id
            let targetScreen = screen(forFrame: entry.frame) ?? NSScreen.main ?? NSScreen.screens.first
            let dID = targetScreen?.displayID ?? 0
            displayByWindowID[entry.id] = dID

            let model = WindowModel(
                id: entry.id,
                pid: entry.pid,
                bundleId: entry.bundleId,
                title: entry.win.title,
                appName: entry.appName
            )
            var r = ribbons[dID] ?? Ribbon()
            r.addWindow(model, config: config)
            ribbons[dID] = r

            observer.observeWindow(element: entry.win, pid: entry.pid)
            adoptedSinceLastSweep.insert(entry.id)
        }

        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let focusedWin = AXElement.application(pid: frontApp.processIdentifier).focusedWindow,
           let fID = focusedWin.windowID,
           let dID = displayByWindowID[fID] {
            activeDisplayID = dID
        } else {
            activeDisplayID = NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID
        }

        persistOriginalFrames()
    }

    // MARK: - Screen Resolution

    private func screen(forFrame frame: CGRect) -> NSScreen? {
        if NSScreen.screens.count <= 1 {
            return NSScreen.main ?? NSScreen.screens.first
        }
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryScreenHeight - (frame.origin.y + frame.height)
        let cocoaFrame = CGRect(x: frame.origin.x, y: cocoaY, width: frame.width, height: frame.height)

        var bestScreen: NSScreen?
        var maxArea: CGFloat = 0

        for screen in NSScreen.screens {
            let inter = screen.frame.intersection(cocoaFrame)
            if !inter.isNull {
                let area = inter.width * inter.height
                if area > maxArea {
                    maxArea = area
                    bestScreen = screen
                }
            }
        }
        return bestScreen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func screen(forDisplayID id: CGDirectDisplayID) -> NSScreen? {
        return NSScreen.screens.first(where: { $0.displayID == id }) ?? NSScreen.main
    }

    // MARK: - Layout & Retile

    public func retile() {
        guard !NSScreen.screens.isEmpty else { return }
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? (NSScreen.main?.frame.height ?? 0)

        var framesToApply: [(id: CGWindowID, pid: pid_t, frame: CGRect, isStashed: Bool)] = []

        for screen in NSScreen.screens {
            let dID = screen.displayID
            guard var r = ribbons[dID], !r.columns.isEmpty else { continue }

            let cocoaFrame = screen.visibleFrame
            let windowServerFrame = CGRect(
                x: cocoaFrame.minX,
                y: primaryScreenHeight - cocoaFrame.maxY,
                width: cocoaFrame.width,
                height: cocoaFrame.height
            )

            var leftAdjacent = false
            var rightAdjacent = false
            for other in NSScreen.screens where other != screen {
                let yOverlap = max(other.frame.minY, screen.frame.minY) < min(other.frame.maxY, screen.frame.maxY)
                if yOverlap {
                    if abs(other.frame.maxX - screen.frame.minX) < 1.0 {
                        leftAdjacent = true
                    }
                    if abs(other.frame.minX - screen.frame.maxX) < 1.0 {
                        rightAdjacent = true
                    }
                }
            }

            let canvasW = windowServerFrame.width - (config.edgeMargin * 2)
            r.viewportOffset = LayoutEngine.minimalScrollOffset(for: r, canvasWidth: canvasW, config: config)
            ribbons[dID] = r

            let plan = LayoutEngine.computePlan(
                for: r,
                screenFrame: windowServerFrame,
                config: config,
                allowLeftBleed: !leftAdjacent,
                allowRightBleed: !rightAdjacent
            )

            var windowPID: [CGWindowID: pid_t] = [:]
            for col in r.columns {
                for win in col.windows {
                    windowPID[win.id] = win.pid
                }
            }

            for placement in plan.placements {
                guard let pid = windowPID[placement.windowID] else { continue }
                framesToApply.append((id: placement.windowID, pid: pid, frame: placement.frame, isStashed: placement.isStashed))
            }
        }

        applyFrames(framesToApply)
    }

    private func applyFrames(_ frames: [(id: CGWindowID, pid: pid_t, frame: CGRect, isStashed: Bool)]) {
        // Filter unchanged frames first so untouched apps skip AX round-trips entirely.
        var placementsByPID: [pid_t: [(elem: AXElement, id: CGWindowID, frame: CGRect, needsFullFrame: Bool)]] = [:]
        for entry in frames {
            guard let elem = trackedWindows[entry.id] else { continue }
            let needsFullFrame: Bool
            if let last = lastAppliedFrames[entry.id] {
                let dx = abs(last.origin.x - entry.frame.origin.x)
                let dy = abs(last.origin.y - entry.frame.origin.y)
                let dw = abs(last.size.width - entry.frame.size.width)
                let dh = abs(last.size.height - entry.frame.size.height)
                if dx < 0.5 && dy < 0.5 && dw < 0.5 && dh < 0.5 {
                    continue
                }
                let stashedChanged = (lastStashedState[entry.id] ?? false) != entry.isStashed
                needsFullFrame = dw >= 0.5 || dh >= 0.5 || stashedChanged
            } else {
                needsFullFrame = true
            }
            lastStashedState[entry.id] = entry.isStashed
            placementsByPID[entry.pid, default: []].append((elem: elem, id: entry.id, frame: entry.frame, needsFullFrame: needsFullFrame))
        }

        for (pid, entries) in placementsByPID {
            let anyNeedsFullFrame = entries.contains(where: { $0.needsFullFrame })
            let appElem = anyNeedsFullFrame ? AXElement.application(pid: pid) : nil
            let wasEnhanced = appElem?.enhancedUserInterface ?? false
            if wasEnhanced {
                appElem?.enhancedUserInterface = false
            }
            for entry in entries {
                if entry.needsFullFrame {
                    entry.elem.setFrame(entry.frame)
                } else {
                    entry.elem.position = entry.frame.origin
                }
                lastAppliedFrames[entry.id] = entry.frame
                pendingFrameEchoes[entry.id] = .now() + .milliseconds(200)
            }
            if wasEnhanced {
                appElem?.enhancedUserInterface = true
            }
        }
    }

    // MARK: - Focus

    private func focusActiveWindow() {
        guard let active = ribbon.activeWindow, let elem = trackedWindows[active.id] else { return }
        pendingFocusEchoes[active.id] = .now() + .milliseconds(150)
        NSRunningApplication(processIdentifier: active.pid)?.activate()
        elem.focus()
    }

    // MARK: - IPC Command Handling

    public func handleCommand(_ command: String) -> String {
        if spaceChangeWork != nil {
            spaceChangeWork?.cancel()
            spaceChangeWork = nil
            rescanAfterSpaceChange()
        }

        let parts = command.split(separator: " ").map(String.init)
        guard let action = parts.first?.lowercased() else { return "error: empty command" }

        let previousActive = ribbon.activeWindow?.id

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
            ribbon.isOverview = false
            let dir = parts.dropFirst().first?.lowercased() ?? "right"
            switch dir {
            case "left", "h": ribbon.swapLeft()
            case "right", "l": ribbon.swapRight()
            case "up", "k": ribbon.swapUp()
            case "down", "j": ribbon.swapDown()
            default: return "error: unknown swap direction"
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
            ribbon.toggleOverview()
        case "focus-display":
            let screens = NSScreen.screens
            guard screens.count > 1 else { return "ok" }
            let currentIdx = screens.firstIndex(where: { $0.displayID == activeDisplayID }) ?? 0
            let arg = parts.dropFirst().first?.lowercased() ?? "next"
            let nextIdx: Int
            if arg == "prev" || arg == "previous" {
                nextIdx = (currentIdx - 1 + screens.count) % screens.count
            } else if let num = Int(arg), num >= 0, num < screens.count {
                nextIdx = num
            } else {
                nextIdx = (currentIdx + 1) % screens.count
            }
            let targetDID = screens[nextIdx].displayID
            activeDisplayID = targetDID
            if let win = ribbons[targetDID]?.activeWindow, let elem = trackedWindows[win.id] {
                pendingFocusEchoes[win.id] = .now() + .milliseconds(150)
                NSRunningApplication(processIdentifier: win.pid)?.activate()
                elem.focus()
            }
            return "ok"
        case "move-to-display":
            let screens = NSScreen.screens
            guard screens.count > 1 else { return "ok" }
            guard let currentDID = activeDisplayID ?? NSScreen.main?.displayID,
                  var currentR = ribbons[currentDID],
                  let activeWin = currentR.activeWindow else { return "ok" }

            let currentIdx = screens.firstIndex(where: { $0.displayID == currentDID }) ?? 0
            let arg = parts.dropFirst().first?.lowercased() ?? "next"
            let nextIdx: Int
            if arg == "prev" || arg == "previous" {
                nextIdx = (currentIdx - 1 + screens.count) % screens.count
            } else if let num = Int(arg), num >= 0, num < screens.count {
                nextIdx = num
            } else {
                nextIdx = (currentIdx + 1) % screens.count
            }
            let targetDID = screens[nextIdx].displayID

            currentR.removeWindow(id: activeWin.id)
            ribbons[currentDID] = currentR

            var targetR = ribbons[targetDID] ?? Ribbon()
            targetR.addWindow(activeWin, config: config, activate: true)
            ribbons[targetDID] = targetR

            displayByWindowID[activeWin.id] = targetDID
            activeDisplayID = targetDID

            retileWork?.cancel()
            retileWork = nil
            retile()
            focusActiveWindow()
            return "ok"
        case "retile":
            retileWork?.cancel()
            retileWork = nil
            retile()
            return "ok"
        case "rescan":
            spaceChangeWork?.cancel()
            spaceChangeWork = nil
            rescanAfterSpaceChange()
            return "ok"
        case "status":
            let dCount = NSScreen.screens.count
            let actD = activeDisplayID ?? 0
            return "screens: \(dCount), active_display: \(actD), columns: \(ribbon.columns.count), active: \(ribbon.activeColumnIndex), overview: \(ribbon.isOverview)"
        default:
            return "error: unknown command '\(command)'"
        }

        retileWork?.cancel()
        retileWork = nil
        retile()
        if ribbon.activeWindow?.id != previousActive {
            focusActiveWindow()
        }
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

        if let onScreen = onScreenWindowIDs(), !onScreen.contains(id) {
            return false
        }

        // Never overwrite an existing entry: on re-adoption (deminiaturize,
        // unhide, space change) the current frame is our own tiled frame,
        // not the user's original.
        if originalFrames[id] == nil, let frame = element.frame {
            originalFrames[id] = frame
            persistOriginalFrames()
        }

        let f = element.frame ?? CGRect.zero
        let targetScreen = screen(forFrame: f) ?? NSScreen.main ?? NSScreen.screens.first
        let dID = targetScreen?.displayID ?? 0

        trackedWindows[id] = element
        windowIDsByElement[element.rawElement] = id
        displayByWindowID[id] = dID

        let model = WindowModel(
            id: id,
            pid: pid,
            bundleId: app.bundleIdentifier,
            title: element.title,
            appName: appName
        )
        var r = ribbons[dID] ?? Ribbon()
        r.addWindow(model, config: config, activate: activate)
        ribbons[dID] = r

        if activate || activeDisplayID == nil {
            activeDisplayID = dID
        }
        observer.observeWindow(element: element, pid: pid)
        adoptedSinceLastSweep.insert(id)
        return true
    }

    // Drops a window from tiling but keeps its originalFrames entry — a
    // minimized/hidden window is still alive and must restore on quit.
    // Dead-window paths (destroy, GC sweep, app termination) call
    // forgetOriginalFrame separately.
    private func removeFromRibbon(id: CGWindowID) {
        if let elem = trackedWindows.removeValue(forKey: id) {
            windowIDsByElement.removeValue(forKey: elem.rawElement)
        }
        lastAppliedFrames.removeValue(forKey: id)
        lastStashedState.removeValue(forKey: id)
        if let dID = displayByWindowID.removeValue(forKey: id) {
            ribbons[dID]?.removeWindow(id: id)
        } else {
            for dID in ribbons.keys {
                ribbons[dID]?.removeWindow(id: id)
            }
        }
    }

    private func forgetOriginalFrame(id: CGWindowID) {
        if originalFrames.removeValue(forKey: id) != nil {
            persistOriginalFrames()
        }
    }

    private func persistOriginalFrames() {
        let url = restoreFramesURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var dict: [String: [Double]] = [:]
        for (id, frame) in originalFrames {
            dict[String(id)] = [
                Double(frame.origin.x),
                Double(frame.origin.y),
                Double(frame.size.width),
                Double(frame.size.height)
            ]
        }

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func rescanAfterSpaceChange() {
        let onScreen = onScreenWindowIDs()
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
                if let onScreen = onScreen, !onScreen.contains(id) { continue }
                if visibleIDs.insert(id).inserted {
                    let x = win.position?.x ?? 0
                    candidateWindows.append((win: win, id: id, pid: pid, x: x))
                }
            }
        }

        // 2. Remove: every ribbon window whose id is NOT in that visible set (removeFromRibbon)
        let currentRibbonIDs = allRibbonWindows.map(\.id)
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

        // 4. Sync active display and active column to frontmost window on the new Space
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let frontElem = AXElement.application(pid: frontApp.processIdentifier)
            if let focusedWin = frontElem.focusedWindow, let focusedID = focusedWin.windowID {
                if let dID = displayByWindowID[focusedID] {
                    activeDisplayID = dID
                    if var r = ribbons[dID] {
                        for (colIdx, col) in r.columns.enumerated() {
                            if let rowIdx = col.windows.firstIndex(where: { $0.id == focusedID }) {
                                r.activeColumnIndex = colIdx
                                var c = col
                                c.activeRowIndex = rowIdx
                                r.columns[colIdx] = c
                                ribbons[dID] = r
                                break
                            }
                        }
                    }
                }
            }
        }

        // 5. retile()
        retileWork?.cancel()
        retileWork = nil
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
        let currentIDs = allRibbonWindows.map(\.id)
        for id in currentIDs {
            if adoptedSinceLastSweep.contains(id) { continue }
            if !liveIDs.contains(id) {
                removeFromRibbon(id: id)
                removedAny = true
            }
        }

        // Also prune originalFrames of dead windows (including stale entries
        // loaded from a crashed run's restore file).
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

    // MARK: - AXEventObserverDelegate

    public func windowCreated(element: AXElement, pid: pid_t) {
        let isFrontmost = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        if adopt(element: element, pid: pid, activate: isFrontmost) {
            scheduleRetile()
        } else if isFrontmost {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                guard let self else { return }
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
        guard let id = element.windowID else { return }
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
        let dID = displayByWindowID[id] ?? activeDisplayID ?? NSScreen.main?.displayID ?? 0
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
            if var r = self.ribbons[dID] {
                if r.setWidthRatio(ratio, forWindowID: id) {
                    self.ribbons[dID] = r
                    self.lastAppliedFrames.removeValue(forKey: id)
                    self.scheduleRetile()
                }
            }
        }
        resizeDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    public func windowMoved(element: AXElement, pid: pid_t) {
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
                    if var oldR = ribbons[oldDID] {
                        if let col = oldR.columns.first(where: { $0.windows.contains(where: { $0.id == id }) }),
                           let winModel = col.windows.first(where: { $0.id == id }) {
                            oldR.removeWindow(id: id)
                            ribbons[oldDID] = oldR

                            var newR = ribbons[newDID] ?? Ribbon()
                            newR.addWindow(winModel, config: config, activate: true)
                            ribbons[newDID] = newR

                            displayByWindowID[id] = newDID
                            activeDisplayID = newDID
                            scheduleRetile()
                            return
                        }
                    }
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

        var foundDisplayID = displayByWindowID[id]
        if foundDisplayID == nil {
            for (dID, r) in ribbons {
                if r.columns.contains(where: { $0.windows.contains(where: { $0.id == id }) }) {
                    foundDisplayID = dID
                    displayByWindowID[id] = dID
                    break
                }
            }
        }

        if foundDisplayID == nil {
            if let onScreen = onScreenWindowIDs(), onScreen.contains(id), admits(element) {
                if adopt(element: element, pid: pid, activate: true) {
                    scheduleRetile()
                    return
                }
            }
        }

        if let dID = foundDisplayID, var r = ribbons[dID] {
            activeDisplayID = dID
            let wasOverview = r.isOverview
            if wasOverview {
                r.isOverview = false
            }

            // Update active column if focused window is tracked
            for (cIdx, col) in r.columns.enumerated() {
                if let rIdx = col.windows.firstIndex(where: { $0.id == id }) {
                    if r.activeColumnIndex != cIdx || col.activeRowIndex != rIdx {
                        r.activeColumnIndex = cIdx
                        var updatedCol = col
                        updatedCol.activeRowIndex = rIdx
                        r.columns[cIdx] = updatedCol
                        ribbons[dID] = r
                        scheduleRetile()
                    } else if wasOverview {
                        ribbons[dID] = r
                        scheduleRetile()
                    }
                    break
                }
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
            spaceChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.spaceChangeWork = nil
                self?.rescanAfterSpaceChange()
            }
            spaceChangeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(config.spaceChangeDebounceMs), execute: work)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(150, config.spaceChangeDebounceMs + 100))) { [weak self] in
                self?.rescanAfterSpaceChange()
            }
        }
    }

    public func applicationTerminated(pid: pid_t) {
        let matchingIDs = allRibbonWindows.filter { $0.pid == pid }.map { $0.id }
        for id in matchingIDs {
            trackedWindows.removeValue(forKey: id)
            lastAppliedFrames.removeValue(forKey: id)
            originalFrames.removeValue(forKey: id)
            displayByWindowID.removeValue(forKey: id)
        }
        persistOriginalFrames()
        for dID in ribbons.keys {
            ribbons[dID]?.removeWindows(pid: pid)
        }
        scheduleRetile()
    }
}
