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
    let wm = Unmanaged<WindowManager>.fromOpaque(userInfo).takeUnretainedValue()
    if wm.isStopped { return }

    if flags.contains(.beginConfigurationFlag) {
        DispatchQueue.main.async {
            guard !wm.isStopped else { return }
            wm.displayConfigurationBegan()
        }
        return
    }

    DispatchQueue.main.async {
        guard !wm.isStopped else { return }
        wm.displayConfigurationChanged()
    }
}

public final class WindowManager: AXEventObserverDelegate {
    public typealias SpaceID = UInt64
    public var ribbons: [SpaceID: Ribbon] = [:]
    public var activeSpaceID: SpaceID?
    public var activeDisplayID: CGDirectDisplayID?
    private var displayBySpaceID: [SpaceID: CGDirectDisplayID] = [:]
    private var spaceByWindowID: [CGWindowID: SpaceID] = [:]
    private var displayByWindowID: [CGWindowID: CGDirectDisplayID] = [:]

    public func currentDisplayID() -> CGDirectDisplayID {
        if let mainID = NSScreen.main?.displayID {
            return mainID
        }
        if let actID = activeDisplayID, NSScreen.screens.contains(where: { $0.displayID == actID }) {
            return actID
        }
        return NSScreen.screens.first?.displayID ?? 0
    }

    public func currentActiveSpaceID(forDisplayID displayID: CGDirectDisplayID? = nil) -> SpaceID {
        let dID = displayID ?? currentDisplayID()
        if let sID = SpaceManager.currentSpaceID(forDisplayID: dID) {
            displayBySpaceID[sID] = dID
            return sID
        }
        let fallback = UInt64(dID)
        displayBySpaceID[fallback] = dID
        return fallback
    }

    public var activeRibbon: Ribbon {
        get {
            let sID = currentActiveSpaceID()
            return ribbons[sID] ?? Ribbon()
        }
        set {
            let dID = currentDisplayID()
            let sID = currentActiveSpaceID(forDisplayID: dID)
            ribbons[sID] = newValue
            activeSpaceID = sID
            displayBySpaceID[sID] = dID
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
    private var isDisplayReconfiguring: Bool = false
    private var displaySamplingTimer: DispatchSourceTimer?
    private var displaySamplingCount: Int = 0
    private struct DisplaySnapshot: Equatable {
        let displayIDs: [CGDirectDisplayID]
        let bounds: [CGRect]
    }
    private var lastSampledDisplaySnapshot: DisplaySnapshot?
    private var screenParametersObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
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

    private var restartStateURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ribbon-restart-\(getuid()).json")
    }

    private struct RestartState: Codable {
        let ribbons: [String: Ribbon]
        let displayBySpaceID: [String: CGDirectDisplayID]
        let spaceByWindowID: [String: UInt64]?
        let displayByWindowID: [String: CGDirectDisplayID]?
        let activeSpaceID: UInt64?
        let activeDisplayID: CGDirectDisplayID?
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
        loadRestartState()

        isStopped = false

        // Start IPC Socket Server first to guarantee single-instance ownership
        socketServer.onCommand = { [weak self] cmd in
            return self?.handleCommand(cmd) ?? "error: daemon unavailable"
        }
        try socketServer.start()
        print("[ribbon-daemon] IPC Socket listening on \(socketServer.socketPath)")

        // Start event observer
        observer.start()

        // Scan existing windows
        discoverExistingWindows()

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

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.displayConfigurationChanged()
        }

        retileNow()
    }

    private func loadPersistedOriginalFrames() {
        guard let data = try? Data(contentsOf: restoreFramesURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] else { return }
        for (key, values) in dict {
            guard let id = CGWindowID(key), values.count == 4 else { continue }
            originalFrames[id] = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
    }

    private var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local")
            .appendingPathComponent("state")
            .appendingPathComponent("ribbon")
            .appendingPathComponent("state.json")
    }

    private var legacyConfigStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("ribbon")
            .appendingPathComponent("state.json")
    }

    public func persistLayoutState() {
        var ribbonsToSave: [String: Ribbon] = [:]
        for (sID, r) in ribbons {
            ribbonsToSave[String(sID)] = r
        }
        var displayBySpaceToSave: [String: CGDirectDisplayID] = [:]
        for (sID, dID) in displayBySpaceID {
            displayBySpaceToSave[String(sID)] = dID
        }
        var spaceByWindowToSave: [String: UInt64] = [:]
        for (wID, sID) in spaceByWindowID {
            spaceByWindowToSave[String(wID)] = sID
        }
        var displayByWindowToSave: [String: CGDirectDisplayID] = [:]
        for (wID, dID) in displayByWindowID {
            displayByWindowToSave[String(wID)] = dID
        }
        let state = RestartState(
            ribbons: ribbonsToSave,
            displayBySpaceID: displayBySpaceToSave,
            spaceByWindowID: spaceByWindowToSave,
            displayByWindowID: displayByWindowToSave,
            activeSpaceID: activeSpaceID,
            activeDisplayID: activeDisplayID
        )
        if let data = try? JSONEncoder().encode(state) {
            let dir = stateURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func loadRestartState() {
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: legacyConfigStateURL)
        try? FileManager.default.removeItem(at: restartStateURL)
    }

    private func retileNow(allSpaces: Bool = false) {
        retileWork?.cancel()
        retileWork = nil
        retile(allSpaces: allSpaces)
    }

    public func stop(forRestart: Bool = false) {
        isStopped = true
        socketServer.stop()
        gcTimer?.cancel()
        gcTimer = nil
        retileWork?.cancel()
        retileWork = nil
        resizeDebounceWork?.cancel()
        resizeDebounceWork = nil
        displaySamplingTimer?.cancel()
        displaySamplingTimer = nil
        if let obs = screenParametersObserver {
            NotificationCenter.default.removeObserver(obs)
            screenParametersObserver = nil
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        observer.stop()

        if !forRestart {
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
        }

        CGDisplayRemoveReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    public func restart() {
        print("[ribbon-daemon] In-place restart requested (fresh clean scan)...")
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: legacyConfigStateURL)
        try? FileManager.default.removeItem(at: restartStateURL)

        stop(forRestart: true)
        let execPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let cArgs = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(execPath, cArgs)
        exit(1)
    }

    func displayConfigurationBegan() {
        isDisplayReconfiguring = true
        retileWork?.cancel()
        retileWork = nil
    }

    func displayConfigurationChanged() {
        isDisplayReconfiguring = true
        retileWork?.cancel()
        retileWork = nil

        displaySamplingCount = 0
        lastSampledDisplaySnapshot = nil

        if displaySamplingTimer != nil { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(150), repeating: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            self?.handleDisplayChangeStability()
        }
        timer.resume()
        displaySamplingTimer = timer
    }

    private func currentDisplaySnapshot() -> DisplaySnapshot {
        let maxDisplays: UInt32 = 16
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(maxDisplays, &activeDisplays, &displayCount)
        var activeList = Array(activeDisplays.prefix(Int(displayCount)))
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        if activeList.isEmpty {
            activeList = NSScreen.screens.map { $0.displayID }
        }
        activeList.sort()
        let bounds = activeList.map { CGDisplayBounds($0) }
        return DisplaySnapshot(displayIDs: activeList, bounds: bounds)
    }

    private func handleDisplayChangeStability() {
        displaySamplingCount += 1
        let current = currentDisplaySnapshot()

        // Settle when:
        // - At least ~450ms (3 ticks) have elapsed since sampling began
        // - Consecutive snapshots match
        // - Or hard cap reached (~2.5s / 17 ticks)
        let isMinSettled = displaySamplingCount >= 3
        let isStable = isMinSettled && !current.displayIDs.isEmpty && current == lastSampledDisplaySnapshot
        let isTimeout = displaySamplingCount >= 17

        if isStable || isTimeout {
            displaySamplingTimer?.cancel()
            displaySamplingTimer = nil
            lastSampledDisplaySnapshot = nil
            settleDisplayConfiguration()
        } else {
            lastSampledDisplaySnapshot = current
        }
    }

    private func settleDisplayConfiguration() {
        isDisplayReconfiguring = false

        let activeDIDs = Set(NSScreen.screens.map { $0.displayID })
        let primaryDID = NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID ?? 0
        let primarySID = currentActiveSpaceID(forDisplayID: primaryDID)

        // Dynamically update space-to-display mappings from SpaceManager
        let spaceMapping = SpaceManager.spaceToDisplayIDMapping(activeDisplayIDs: Array(activeDIDs))
        for (sID, dID) in spaceMapping {
            displayBySpaceID[sID] = dID
        }
        displayBySpaceID[primarySID] = primaryDID

        // Prune ribbons only for spaces that no longer exist anywhere in macOS
        let allManaged = SpaceManager.allManagedSpaceIDs()
        if !allManaged.isEmpty {
            for sID in ribbons.keys {
                if !allManaged.contains(sID) {
                    ribbons.removeValue(forKey: sID)
                    displayBySpaceID.removeValue(forKey: sID)
                }
            }
        }

        if let curD = activeDisplayID, activeDIDs.contains(curD) {
            activeSpaceID = currentActiveSpaceID(forDisplayID: curD)
        } else {
            activeDisplayID = primaryDID
            activeSpaceID = primarySID
        }

        lastAppliedFrames.removeAll()
        handleActiveSpaceDidChange()
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
        guard win.role == (kAXWindowRole as String),
              win.subrole == (kAXStandardWindowSubrole as String),
              !win.isMinimized,
              !win.isFullscreen else { return false }
        return true
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
        reconcileWindows(sortHorizontally: true)
        syncFocusToFrontmostWindow()
        retile(allSpaces: true)
    }

    private func reconcileWindows(sortHorizontally: Bool = false) {
        let topology = SpaceManager.currentTopology()
        for (sID, dID) in topology.displayBySpace {
            displayBySpaceID[sID] = dID
        }

        let allLiveIDs: Set<CGWindowID>
        if let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            allLiveIDs = Set(windowList.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        } else {
            allLiveIDs = []
        }

        if !allLiveIDs.isEmpty {
            let deadIDs = Set(trackedWindows.keys).subtracting(allLiveIDs)
            for id in deadIDs {
                removeTrackedWindow(id: id)
            }
        }

        var discovered: [(
            win: AXElement,
            id: CGWindowID,
            pid: pid_t,
            appName: String,
            bundleId: String?,
            x: CGFloat,
            frame: CGRect
        )] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  !app.isHidden,
                  let appName = app.localizedName,
                  !config.ignoredApps.contains(appName) else { continue }

            let appElem = AXElement.application(pid: app.processIdentifier)
            for win in appElem.windows {
                guard admits(win), let id = win.windowID else { continue }
                if !allLiveIDs.isEmpty && !allLiveIDs.contains(id) { continue }

                let frame = win.frame ?? .zero
                if originalFrames[id] == nil, frame.width > 50 && frame.height > 50 {
                    originalFrames[id] = frame
                }

                discovered.append((
                    win: win,
                    id: id,
                    pid: app.processIdentifier,
                    appName: appName,
                    bundleId: app.bundleIdentifier,
                    x: frame.origin.x,
                    frame: frame
                ))
            }
        }

        if sortHorizontally {
            discovered.sort { $0.x < $1.x }
        }

        for entry in discovered {
            upsertWindow(
                win: entry.win,
                id: entry.id,
                pid: entry.pid,
                appName: entry.appName,
                bundleId: entry.bundleId,
                frame: entry.frame,
                topology: topology,
                activate: false
            )
        }
        persistOriginalFrames()
    }

    @discardableResult
    public func upsertWindow(
        win: AXElement,
        id: CGWindowID,
        pid: pid_t,
        appName: String,
        bundleId: String?,
        frame: CGRect? = nil,
        topology: SpaceManager.SpaceTopology? = nil,
        activate: Bool = false
    ) -> SpaceID? {
        let topo = topology ?? SpaceManager.currentTopology()
        let cgsSpaces = SpaceManager.spaceIDs(for: id)
        let allSpaces = SpaceManager.allManagedSpaceIDs()

        // Skip sticky windows assigned to all spaces
        if allSpaces.count > 1 && cgsSpaces.count >= allSpaces.count {
            return nil
        }

        let winFrame = frame ?? win.frame ?? .zero
        let isStashed = winFrame.width <= 50 || winFrame.height <= 50
        let fallbackScreen = (isStashed ? nil : screen(forFrame: winFrame))
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let fallbackDisplayID = fallbackScreen?.displayID ?? CGMainDisplayID()

        let sID: SpaceID
        if let detectedSID = cgsSpaces.first(where: { topo.displayBySpace[$0] != nil }) ?? cgsSpaces.first {
            sID = detectedSID
        } else if let existingSID = spaceByWindowID[id] {
            sID = existingSID
        } else if let activeSID = topo.activeSpaceByDisplay[fallbackDisplayID] {
            sID = activeSID
        } else {
            sID = currentActiveSpaceID(forDisplayID: fallbackDisplayID)
        }

        let dID = topo.displayBySpace[sID] ?? fallbackDisplayID

        trackedWindows[id] = win
        windowIDsByElement[win.rawElement] = id
        displayByWindowID[id] = dID
        spaceByWindowID[id] = sID
        displayBySpaceID[sID] = dID

        for otherSID in ribbons.keys where otherSID != sID {
            ribbons[otherSID]?.removeWindow(id: id)
        }

        var targetR = ribbons[sID] ?? Ribbon()
        let isAlreadyInRibbon = targetR.columns.contains { col in
            col.windows.contains { $0.id == id }
        }

        if !isAlreadyInRibbon {
            let model = WindowModel(
                id: id,
                pid: pid,
                bundleId: bundleId,
                title: win.title,
                appName: appName
            )
            let initialRatio = config.appWidthRatios[appName]
                ?? (bundleId.flatMap { config.appWidthRatios[$0] })
                ?? config.defaultWidthRatio
            let widthParam = targetR.columns.isEmpty ? nil : initialRatio
            targetR.addWindow(model, config: config, activate: activate, initialWidthRatio: widthParam)
            ribbons[sID] = targetR
        } else if activate {
            targetR.focus(windowID: id)
            ribbons[sID] = targetR
        }

        observer.observeWindow(element: win, pid: pid)
        adoptedSinceLastSweep.insert(id)
        return sID
    }

    public func removeTrackedWindow(id: CGWindowID) {
        if let win = trackedWindows.removeValue(forKey: id) {
            windowIDsByElement.removeValue(forKey: win.rawElement)
        }
        spaceByWindowID.removeValue(forKey: id)
        displayByWindowID.removeValue(forKey: id)
        lastAppliedFrames.removeValue(forKey: id)
        lastStashedState.removeValue(forKey: id)
        adoptedSinceLastSweep.remove(id)

        for sID in ribbons.keys {
            ribbons[sID]?.removeWindow(id: id)
        }
    }

    private func syncFocusToFrontmostWindow() {
        let topology = SpaceManager.currentTopology()

        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let focusedWin = AXElement.application(pid: frontApp.processIdentifier).focusedWindow,
           let fID = focusedWin.windowID,
           let sID = spaceByWindowID[fID] ?? SpaceManager.spaceIDs(for: fID).first,
           topology.activeSpaceByDisplay.values.contains(sID) {
            let dID = topology.displayBySpace[sID]
                ?? displayByWindowID[fID]
                ?? NSScreen.main?.displayID
                ?? CGMainDisplayID()
            activeDisplayID = dID
            activeSpaceID = sID
            ribbons[sID]?.focus(windowID: fID)
        } else {
            let dID = NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID ?? CGMainDisplayID()
            activeDisplayID = dID
            activeSpaceID = topology.activeSpaceByDisplay[dID] ?? currentActiveSpaceID(forDisplayID: dID)
        }
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

    public func retile(allSpaces: Bool = false) {
        guard !isDisplayReconfiguring else { return }
        guard !NSScreen.screens.isEmpty else { return }
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? (NSScreen.main?.frame.height ?? 0)

        let topology = SpaceManager.currentTopology()
        for (sID, dID) in topology.displayBySpace {
            displayBySpaceID[sID] = dID
        }

        var spacesToTile = Set<SpaceID>()
        if allSpaces {
            spacesToTile.formUnion(ribbons.keys)
        } else {
            for screen in NSScreen.screens {
                let sID = topology.activeSpaceByDisplay[screen.displayID]
                    ?? currentActiveSpaceID(forDisplayID: screen.displayID)
                spacesToTile.insert(sID)
                displayBySpaceID[sID] = screen.displayID
            }
            if spacesToTile.isEmpty {
                spacesToTile.insert(currentActiveSpaceID())
            }
        }

        var framesToApply: [(id: CGWindowID, pid: pid_t, frame: CGRect, isStashed: Bool)] = []

        for sID in spacesToTile {
            guard var r = ribbons[sID], !r.columns.isEmpty else { continue }
            let dID = displayBySpaceID[sID] ?? activeDisplayID ?? NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID ?? CGMainDisplayID()
            guard let screen = screen(forDisplayID: dID) ?? NSScreen.screens.first else {
                RibbonLog.log("retile skipped space=\(sID): no screen for displayID=\(dID)", category: "retile")
                continue
            }

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
            ribbons[sID] = r

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
        var placementsByPID: [pid_t: [(elem: AXElement, id: CGWindowID, frame: CGRect, needsFullFrame: Bool)]] = [:]
        for entry in frames {
            var elem = trackedWindows[entry.id]
            if elem == nil {
                let appElem = AXElement.application(pid: entry.pid)
                if let found = appElem.windows.first(where: { $0.windowID == entry.id }) {
                    trackedWindows[entry.id] = found
                    windowIDsByElement[found.rawElement] = entry.id
                    observer.observeWindow(element: found, pid: entry.pid)
                    elem = found
                    RibbonLog.log("applyFrames: on-demand re-tracked wid=\(entry.id) pid=\(entry.pid)", category: "ax")
                }
            }
            guard let elem = elem else {
                RibbonLog.log("applyFrames: missing AXElement in trackedWindows for wid=\(entry.id) pid=\(entry.pid)", category: "ax")
                continue
            }

            let actualPos = elem.position
            let actualSize = elem.size
            let posMismatch: Bool = {
                guard let p = actualPos else { return true }
                return abs(p.x - entry.frame.origin.x) >= 1.5 || abs(p.y - entry.frame.origin.y) >= 1.5
            }()
            let sizeMismatch: Bool = {
                guard let s = actualSize else { return true }
                return abs(s.width - entry.frame.size.width) >= 1.5 || abs(s.height - entry.frame.size.height) >= 1.5
            }()

            var needsFullFrame = sizeMismatch
            if let last = lastAppliedFrames[entry.id] {
                let dx = abs(last.origin.x - entry.frame.origin.x)
                let dy = abs(last.origin.y - entry.frame.origin.y)
                let dw = abs(last.size.width - entry.frame.size.width)
                let dh = abs(last.size.height - entry.frame.size.height)
                let stashedChanged = (lastStashedState[entry.id] ?? false) != entry.isStashed
                if dw >= 0.5 || dh >= 0.5 || stashedChanged {
                    needsFullFrame = true
                }
                if dx < 0.5 && dy < 0.5 && !needsFullFrame && !posMismatch && !sizeMismatch {
                    continue
                }
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
                RibbonLog.log(
                    "AX applied wid=\(entry.id) pid=\(pid) full=\(entry.needsFullFrame) target=\(entry.frame.integral) actualAfter=(pos:\(String(describing: entry.elem.position)), size:\(String(describing: entry.elem.size)))",
                    category: "ax"
                )
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

    private func migrateWindow(id: CGWindowID, toSpace targetSID: SpaceID, display targetDID: CGDirectDisplayID) {
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

    private func syncFocusedWindowToRibbon(spaceID sID: SpaceID) {
        guard var r = ribbons[sID], !r.columns.isEmpty else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appElem = AXElement.application(pid: frontApp.processIdentifier)
        guard let focusedWin = appElem.focusedWindow,
              let focusedWID = focusedWin.windowID else { return }

        for (cIdx, col) in r.columns.enumerated() {
            if let rIdx = col.windows.firstIndex(where: { $0.id == focusedWID }) {
                if r.activeColumnIndex != cIdx || r.columns[cIdx].activeRowIndex != rIdx {
                    RibbonLog.log("Synced activeColumnIndex \(r.activeColumnIndex)->\(cIdx) to match macOS focused window \(focusedWID) (\(frontApp.localizedName ?? ""))", category: "focus")
                    r.activeColumnIndex = cIdx
                    r.columns[cIdx].activeRowIndex = rIdx
                    ribbons[sID] = r
                }
                return
            }
        }
    }

    public func handleCommand(_ command: String) -> String {
        let sID = currentActiveSpaceID()
        syncFocusedWindowToRibbon(spaceID: sID)

        let parts = command.split(separator: " ").map(String.init)
        guard let action = parts.first?.lowercased() else { return "error: empty command" }

        let beforeRibbon = ribbons[sID] ?? Ribbon()
        let previousActive = beforeRibbon.activeWindow?.id
        RibbonLog.log(
            "CMD '\(command)' on space=\(sID) display=\(displayBySpaceID[sID] ?? 0) cols=\(beforeRibbon.columns.count) activeCol=\(beforeRibbon.activeColumnIndex) activeWin=\(previousActive ?? 0)",
            category: "cmd"
        )

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
        case "swap", "move":
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
            let nextIdx = targetDisplayIndex(arg: parts.dropFirst().first, currentIdx: currentIdx, count: screens.count)
            let targetDID = screens[nextIdx].displayID
            let targetSID = currentActiveSpaceID(forDisplayID: targetDID)
            activeDisplayID = targetDID
            activeSpaceID = targetSID
            displayBySpaceID[targetSID] = targetDID
            if let win = ribbons[targetSID]?.activeWindow, let elem = trackedWindows[win.id] {
                pendingFocusEchoes[win.id] = .now() + .milliseconds(150)
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

            retileNow()
            focusActiveWindow()
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
            return "screens: \(dCount), display: \(actD), space: \(actS), columns: \(ribbon.columns.count), active: \(ribbon.activeColumnIndex), overview: \(ribbon.isOverview)"
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

        retileNow()
        if ribbon.activeWindow?.id != previousActive {
            focusActiveWindow()
        }
        return "ok"
    }

    // MARK: - Window Adoption & Removal

    @discardableResult
    private func adopt(element: AXElement, pid: pid_t, activate: Bool, onScreen precomputedOnScreen: Set<CGWindowID>? = nil) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let appName = app.localizedName,
              !config.ignoredApps.contains(appName) else { return false }
        guard admits(element) else { return false }
        guard let id = element.windowID else { return false }

        if originalFrames[id] == nil, let frame = element.frame, frame.width > 50 && frame.height > 50 {
            originalFrames[id] = frame
            persistOriginalFrames()
        }

        let sID = upsertWindow(
            win: element,
            id: id,
            pid: pid,
            appName: appName,
            bundleId: app.bundleIdentifier,
            frame: element.frame,
            activate: activate
        )
        return sID != nil
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
        displayByWindowID.removeValue(forKey: id)
        if let sID = spaceByWindowID.removeValue(forKey: id) {
            ribbons[sID]?.removeWindow(id: id)
        } else {
            for sID in ribbons.keys {
                ribbons[sID]?.removeWindow(id: id)
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

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self = self, !self.isDisplayReconfiguring else { return }
            self.syncFocusToFrontmostWindow()
            self.retile(allSpaces: false)
        }
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
            activeSpaceID = sID
            if let dID = displayBySpaceID[sID] {
                activeDisplayID = dID
            }
            let wasOverview = r.isOverview
            if wasOverview {
                r.isOverview = false
            }

            let oldActive = r.activeColumnIndex
            let oldRow = r.activeColumn?.activeRowIndex
            if r.focus(windowID: id) {
                if r.activeColumnIndex != oldActive || r.activeColumn?.activeRowIndex != oldRow || wasOverview {
                    ribbons[sID] = r
                    scheduleRetile()
                }
            }
        }
    }

    public func applicationActivated(pid: pid_t) {
        let app = AXElement.application(pid: pid)
        if let focused = app.focusedWindow ?? app.windows.first {
            windowFocused(element: focused, pid: pid)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                guard let self else { return }
                let retryApp = AXElement.application(pid: pid)
                if let focused = retryApp.focusedWindow ?? retryApp.windows.first {
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
