import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard let userInfo = userInfo else { return }
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
    public var ribbon = Ribbon()
    public var config = Config.default
    private let observer = AXEventObserver()
    private let socketServer = SocketServer()
    private var trackedWindows: [CGWindowID: AXElement] = [:]
    private var windowIDsByElement: [AXUIElement: CGWindowID] = [:]
    private var adoptedSinceLastSweep: Set<CGWindowID> = []
    private var gcTimer: DispatchSourceTimer?
    private var retileWork: DispatchWorkItem?
    private var lastAppliedFrames: [CGWindowID: CGRect] = [:]
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
        observer.stop()

        var windowPID: [CGWindowID: pid_t] = [:]
        for col in ribbon.columns {
            for win in col.windows {
                windowPID[win.id] = win.pid
            }
        }

        var restoreFrames: [(id: CGWindowID, pid: pid_t, frame: CGRect)] = []
        for (id, _) in trackedWindows {
            guard let pid = windowPID[id], let orig = originalFrames[id] else { continue }
            restoreFrames.append((id: id, pid: pid, frame: orig))
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
        lastAppliedFrames.removeAll()
        scheduleRetile()
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

                if originalFrames[id] == nil, let frame = win.frame {
                    originalFrames[id] = frame
                }

                let x = win.position?.x ?? 0
                discovered.append((win: win, id: id, pid: app.processIdentifier, appName: appName, bundleId: app.bundleIdentifier, x: x))
            }
        }

        discovered.sort { $0.x < $1.x }

        for entry in discovered {
            trackedWindows[entry.id] = entry.win
            windowIDsByElement[entry.win.rawElement] = entry.id
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

        persistOriginalFrames()
    }

    // MARK: - Screen Resolution

    private func resolveScreen() -> NSScreen? {
        if let activeID = ribbon.activeWindow?.id,
           let frame = trackedWindows[activeID]?.frame {
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

            if let best = bestScreen, maxArea > 0 {
                return best
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: - Layout & Retile

    public func retile() {
        guard let screen = resolveScreen() else { return }
        // NSScreen coordinates have Y origin at bottom-left; WindowServer has Y origin at top-left
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
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
        ribbon.viewportOffset = LayoutEngine.minimalScrollOffset(for: ribbon, canvasWidth: canvasW, config: config)

        let plan = LayoutEngine.computePlan(
            for: ribbon,
            screenFrame: windowServerFrame,
            config: config,
            allowLeftBleed: !leftAdjacent,
            allowRightBleed: !rightAdjacent
        )

        var windowPID: [CGWindowID: pid_t] = [:]
        for col in ribbon.columns {
            for win in col.windows {
                windowPID[win.id] = win.pid
            }
        }

        var framesToApply: [(id: CGWindowID, pid: pid_t, frame: CGRect)] = []
        for placement in plan.placements {
            guard let pid = windowPID[placement.windowID] else { continue }
            framesToApply.append((id: placement.windowID, pid: pid, frame: placement.frame))
        }

        applyFrames(framesToApply)
    }

    private func applyFrames(_ frames: [(id: CGWindowID, pid: pid_t, frame: CGRect)]) {
        // Filter unchanged frames first so untouched apps skip the
        // AXEnhancedUserInterface round-trips entirely.
        var placementsByPID: [pid_t: [(elem: AXElement, id: CGWindowID, frame: CGRect)]] = [:]
        for entry in frames {
            guard let elem = trackedWindows[entry.id] else { continue }
            if let last = lastAppliedFrames[entry.id] {
                let dx = abs(last.origin.x - entry.frame.origin.x)
                let dy = abs(last.origin.y - entry.frame.origin.y)
                let dw = abs(last.size.width - entry.frame.size.width)
                let dh = abs(last.size.height - entry.frame.size.height)
                if dx < 0.5 && dy < 0.5 && dw < 0.5 && dh < 0.5 {
                    continue
                }
            }
            placementsByPID[entry.pid, default: []].append((elem: elem, id: entry.id, frame: entry.frame))
        }

        for (pid, entries) in placementsByPID {
            let appElem = AXElement.application(pid: pid)
            let wasEnhanced = appElem.enhancedUserInterface
            if wasEnhanced {
                appElem.enhancedUserInterface = false
            }
            for entry in entries {
                entry.elem.setFrame(entry.frame)
                lastAppliedFrames[entry.id] = entry.frame
                pendingFrameEchoes[entry.id] = .now() + .milliseconds(200)
            }
            if wasEnhanced {
                appElem.enhancedUserInterface = true
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

        scheduleRetile()
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

        // Never overwrite an existing entry: on re-adoption (deminiaturize,
        // unhide, space change) the current frame is our own tiled frame,
        // not the user's original.
        if originalFrames[id] == nil, let frame = element.frame {
            originalFrames[id] = frame
            persistOriginalFrames()
        }

        trackedWindows[id] = element
        windowIDsByElement[element.rawElement] = id
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

    // Drops a window from tiling but keeps its originalFrames entry — a
    // minimized/hidden window is still alive and must restore on quit.
    // Dead-window paths (destroy, GC sweep, app termination) call
    // forgetOriginalFrame separately.
    private func removeFromRibbon(id: CGWindowID) {
        if let elem = trackedWindows.removeValue(forKey: id) {
            windowIDsByElement.removeValue(forKey: elem.rawElement)
        }
        lastAppliedFrames.removeValue(forKey: id)
        ribbon.removeWindow(id: id)
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
        scheduleRetile()
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

        guard let newSize = element.size,
              let screen = resolveScreen() else { return }

        let canvasW = screen.visibleFrame.width - (config.edgeMargin * 2)
        guard canvasW > 0 else { return }

        let ratio = max(0.15, min(1.0, Double(newSize.width) / Double(canvasW)))
        if ribbon.setWidthRatio(ratio, forWindowID: id) {
            lastAppliedFrames.removeValue(forKey: id)
            scheduleRetile()
        }
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

        // Snap user-moved window back to its assigned ribbon column
        lastAppliedFrames.removeValue(forKey: id)
        scheduleRetile()
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

        // Update active column if focused window is tracked
        for (cIdx, col) in ribbon.columns.enumerated() {
            if let rIdx = col.windows.firstIndex(where: { $0.id == id }) {
                if ribbon.activeColumnIndex != cIdx || col.activeRowIndex != rIdx {
                    ribbon.activeColumnIndex = cIdx
                    var updatedCol = col
                    updatedCol.activeRowIndex = rIdx
                    ribbon.columns[cIdx] = updatedCol
                    scheduleRetile()
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
            scheduleRetile()
        case .unhidden:
            guard let pid = pid else { return }
            for win in AXElement.application(pid: pid).windows {
                adopt(element: win, pid: pid, activate: false)
            }
            scheduleRetile()
        case .spaceChanged:
            rescanAfterSpaceChange()
        }
    }

    public func applicationTerminated(pid: pid_t) {
        let matchingIDs = ribbon.columns.flatMap { $0.windows }.filter { $0.pid == pid }.map { $0.id }
        for id in matchingIDs {
            trackedWindows.removeValue(forKey: id)
            lastAppliedFrames.removeValue(forKey: id)
            originalFrames.removeValue(forKey: id)
        }
        persistOriginalFrames()
        ribbon.removeWindows(pid: pid)
        scheduleRetile()
    }
}
