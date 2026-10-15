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
    private var spaceSamplingTimer: DispatchSourceTimer?
    private var spaceSamplingCount: Int = 0
    private var lastSampledWindowIDs: Set<CGWindowID>?
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

    private func retileNow() {
        retileWork?.cancel()
        retileWork = nil
        retile()
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
        spaceSamplingTimer?.cancel()
        spaceSamplingTimer = nil
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
        rescanAfterSpaceChange()

        // Trailing pass for apps (Electron, Catalyst) that resize/relocate asynchronously
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            guard let self = self, !self.isStopped, !self.isDisplayReconfiguring else { return }
            self.rescanAfterSpaceChange()
        }
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
        let currentSID = currentActiveSpaceID()
        activeSpaceID = currentSID

        let allLiveIDs: Set<CGWindowID>
        if let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            allLiveIDs = Set(windowList.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        } else {
            allLiveIDs = []
        }

        var discovered: [(win: AXElement, id: CGWindowID, pid: pid_t, appName: String, bundleId: String?, x: CGFloat, frame: CGRect)] = []
        let restoredIDs = Set(ribbons.values.flatMap { $0.columns.flatMap { $0.windows }.map(\.id) })

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  !app.isHidden,
                  let appName = app.localizedName,
                  !config.ignoredApps.contains(appName) else { continue }

            let appElem = AXElement.application(pid: app.processIdentifier)
            for win in appElem.windows {
                guard admits(win) else { continue }
                guard let id = win.windowID else { continue }
                if !allLiveIDs.isEmpty && !allLiveIDs.contains(id) { continue }
                let isRestored = restoredIDs.contains(id)
                if !isRestored {
                    if let onScreen = onScreen, !onScreen.contains(id) { continue }
                }

                let frame = win.frame ?? CGRect.zero
                if originalFrames[id] == nil, frame.width > 50 && frame.height > 50 {
                    originalFrames[id] = frame
                }

                discovered.append((win: win, id: id, pid: app.processIdentifier, appName: appName, bundleId: app.bundleIdentifier, x: frame.origin.x, frame: frame))
            }
        }

        discovered.sort { $0.x < $1.x }

        // Prune any windows from restored ribbons that are actually dead/closed
        if !allLiveIDs.isEmpty {
            for (sID, var r) in ribbons {
                let deadIDs = r.columns.flatMap { $0.windows }.map(\.id).filter { !allLiveIDs.contains($0) }
                for id in deadIDs {
                    r.removeWindow(id: id)
                }
                ribbons[sID] = r
            }
        }

        for entry in discovered {
            trackedWindows[entry.id] = entry.win
            windowIDsByElement[entry.win.rawElement] = entry.id
            let targetScreen = screen(forFrame: entry.frame) ?? NSScreen.main ?? NSScreen.screens.first
            let dID = targetScreen?.displayID ?? 0
            let isCurrentlyOnScreen = onScreen?.contains(entry.id) == true
            let detectedSID = SpaceManager.spaceIDs(for: entry.id).first
            guard let sID = (isCurrentlyOnScreen ? currentActiveSpaceID(forDisplayID: dID) : (detectedSID ?? spaceByWindowID[entry.id])) else {
                continue
            }
            displayByWindowID[entry.id] = dID
            spaceByWindowID[entry.id] = sID
            displayBySpaceID[sID] = dID

            var targetR = ribbons[sID] ?? Ribbon()
            let isAlreadyTracked = targetR.columns.contains(where: { $0.windows.contains(where: { $0.id == entry.id }) })
            let initialRatio: Double? = config.appWidthRatios[entry.appName] ?? config.defaultWidthRatio

            if !isAlreadyTracked {
                for otherSID in ribbons.keys where otherSID != sID {
                    ribbons[otherSID]?.removeWindow(id: entry.id)
                }
                let model = WindowModel(
                    id: entry.id,
                    pid: entry.pid,
                    bundleId: entry.bundleId,
                    title: entry.win.title,
                    appName: entry.appName
                )
                targetR.addWindow(model, config: config, activate: false, initialWidthRatio: initialRatio)
                ribbons[sID] = targetR
            }
            observer.observeWindow(element: entry.win, pid: entry.pid)
            adoptedSinceLastSweep.insert(entry.id)
        }

        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let focusedWin = AXElement.application(pid: frontApp.processIdentifier).focusedWindow,
           let fID = focusedWin.windowID,
           let dID = displayByWindowID[fID] {
            activeDisplayID = dID
            let sID = spaceByWindowID[fID] ?? currentActiveSpaceID(forDisplayID: dID)
            activeSpaceID = sID
            ribbons[sID]?.focus(windowID: fID)
        } else if activeDisplayID == nil {
            let dID = NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID ?? 0
            activeDisplayID = dID
            activeSpaceID = currentActiveSpaceID(forDisplayID: dID)
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
        guard !isDisplayReconfiguring else { return }
        guard !NSScreen.screens.isEmpty else { return }
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? (NSScreen.main?.frame.height ?? 0)

        var framesToApply: [(id: CGWindowID, pid: pid_t, frame: CGRect, isStashed: Bool)] = []

        var spacesToTile = Set<SpaceID>()
        for screen in NSScreen.screens {
            let sID = currentActiveSpaceID(forDisplayID: screen.displayID)
            spacesToTile.insert(sID)
            displayBySpaceID[sID] = screen.displayID
        }
        if spacesToTile.isEmpty {
            spacesToTile.insert(currentActiveSpaceID())
        }

        for sID in spacesToTile {
            guard var r = ribbons[sID], !r.columns.isEmpty else { continue }
            let dID = displayBySpaceID[sID] ?? activeDisplayID ?? NSScreen.main?.displayID ?? NSScreen.screens.first?.displayID ?? 0
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
        rescanAfterSpaceChange()

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
            rescanAfterSpaceChange()
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

        let onScreen = precomputedOnScreen ?? onScreenWindowIDs()
        if let onScreen, !onScreen.contains(id) {
            return false
        }

        // Never overwrite an existing entry: on re-adoption (deminiaturize,
        // unhide, space change) the current frame is our own tiled frame,
        // not the user's original.
        if originalFrames[id] == nil, let frame = element.frame, frame.width > 50 && frame.height > 50 {
            originalFrames[id] = frame
            persistOriginalFrames()
        }

        let f = element.frame ?? CGRect.zero
        let targetScreen = screen(forFrame: f) ?? NSScreen.main ?? NSScreen.screens.first
        let dID = targetScreen?.displayID ?? 0
        let sID = currentActiveSpaceID(forDisplayID: dID)

        for otherSID in ribbons.keys where otherSID != sID {
            ribbons[otherSID]?.removeWindow(id: id)
        }

        trackedWindows[id] = element
        windowIDsByElement[element.rawElement] = id
        displayByWindowID[id] = dID
        spaceByWindowID[id] = sID
        displayBySpaceID[sID] = dID
        let existingRatio = ribbons.values.flatMap(\.columns).first(where: { $0.windows.contains(where: { $0.id == id }) })?.widthRatio
        let initialRatio: Double? = existingRatio
            ?? config.appWidthRatios[appName]
            ?? config.defaultWidthRatio

        let model = WindowModel(
            id: id,
            pid: pid,
            bundleId: app.bundleIdentifier,
            title: element.title,
            appName: appName
        )
        var r = ribbons[sID] ?? Ribbon()
        r.addWindow(model, config: config, activate: activate, initialWidthRatio: initialRatio)
        ribbons[sID] = r

        if activate || activeDisplayID == nil {
            activeDisplayID = dID
            activeSpaceID = sID
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

    private func rescanAfterSpaceChange() {
        guard let windowListAll = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [NSDictionary] else { return }
        var allLiveIDs = Set<CGWindowID>()
        for dict in windowListAll {
            if let num = dict[kCGWindowNumber as String] as? NSNumber {
                allLiveIDs.insert(num.uint32Value)
            }
        }

        let onScreen = onScreenWindowIDs() ?? []

        var candidatesByScreen: [CGDirectDisplayID: [(win: AXElement, id: CGWindowID, pid: pid_t, x: CGFloat)]] = [:]
        var visibleIDsByScreen: [CGDirectDisplayID: Set<CGWindowID>] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  !app.isHidden,
                  let appName = app.localizedName,
                  !config.ignoredApps.contains(appName) else { continue }

            let pid = app.processIdentifier
            let appElem = AXElement.application(pid: pid)
            for win in appElem.windows {
                guard admits(win), let id = win.windowID else { continue }
                if !onScreen.contains(id) { continue }
                let frame = win.frame ?? .zero
                let winDID = (self.lastStashedState[id] == true ? self.displayByWindowID[id] : nil) ?? self.screen(forFrame: frame)?.displayID ?? self.displayByWindowID[id] ?? (NSScreen.main?.displayID ?? 0)
                guard winDID != 0 else { continue }
                if visibleIDsByScreen[winDID, default: []].insert(id).inserted {
                    let x = win.position?.x ?? 0
                    candidatesByScreen[winDID, default: []].append((win: win, id: id, pid: pid, x: x))
                }
            }
        }

        for screen in NSScreen.screens {
            let currentDID = screen.displayID
            let currentSID = currentActiveSpaceID(forDisplayID: currentDID)
            self.displayBySpaceID[currentSID] = currentDID

            let candidateWindows = candidatesByScreen[currentDID] ?? []
            for entry in candidateWindows {
                self.trackedWindows[entry.id] = entry.win
                self.windowIDsByElement[entry.win.rawElement] = entry.id
                self.observer.observeWindow(element: entry.win, pid: entry.pid)
                self.displayByWindowID[entry.id] = currentDID
                self.lastAppliedFrames.removeValue(forKey: entry.id)
            }

            var r = ribbons[currentSID] ?? Ribbon()

            // 2. Prune only windows from THIS space's ribbon that are actually dead/closed or assigned to another space
            let currentRibbonIDs = r.columns.flatMap { $0.windows }.map(\.id)
            for id in currentRibbonIDs {
                if !allLiveIDs.contains(id) {
                    r.removeWindow(id: id)
                    removeFromRibbon(id: id)
                    forgetOriginalFrame(id: id)
                } else if let assignedSID = spaceByWindowID[id], assignedSID != currentSID {
                    r.removeWindow(id: id)
                }
            }
            ribbons[currentSID] = r

            // 3. Add any newly visible windows not yet in this space's ribbon
            let existingIDs = Set(r.columns.flatMap { $0.windows }.map(\.id))
            let newWindows = candidateWindows
                .filter { !existingIDs.contains($0.id) }
                .sorted { $0.x < $1.x }
            for entry in newWindows {
                adopt(element: entry.win, pid: entry.pid, activate: false, onScreen: onScreen)
            }

            for entry in candidateWindows {
                self.spaceByWindowID[entry.id] = currentSID
            }

            r = ribbons[currentSID] ?? r

            // 4. Sync active display and active column if frontmost window is on this screen
            var targetFocusID: CGWindowID?
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                let frontElem = AXElement.application(pid: frontApp.processIdentifier)
                if let focusedWin = frontElem.focusedWindow ?? frontElem.windows.first,
                   let focusedID = focusedWin.windowID {
                    let isTrackedOnThisSpace = r.columns.contains(where: { $0.windows.contains(where: { $0.id == focusedID }) })
                    let isAssignedToThisSpace = spaceByWindowID[focusedID] == currentSID
                    if isTrackedOnThisSpace || isAssignedToThisSpace {
                        targetFocusID = focusedID
                    } else if trackedWindows[focusedID] == nil && admits(focusedWin) {
                        if adopt(element: focusedWin, pid: frontApp.processIdentifier, activate: true, onScreen: onScreen) {
                            r = ribbons[currentSID] ?? r
                            targetFocusID = focusedID
                        }
                    }
                }
            }

            if targetFocusID == nil,
               let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary] {
                // Fallback: pick the top-most tracked window in Z-order for this screen
                for dict in windowList {
                    guard let num = dict[kCGWindowNumber as String] as? NSNumber,
                          let layer = dict[kCGWindowLayer as String] as? Int,
                          layer == 0 else { continue }
                    let id = num.uint32Value
                    if r.columns.contains(where: { $0.windows.contains(where: { $0.id == id }) }) {
                        targetFocusID = id
                        break
                    }
                }
            }

            if let fID = targetFocusID {
                if r.focus(windowID: fID) {
                    ribbons[currentSID] = r
                }
            }
            let isMainScreen = (screen.displayID == (NSScreen.main?.displayID ?? 0))
            if targetFocusID != nil || isMainScreen || activeDisplayID == nil {
                activeDisplayID = currentDID
                activeSpaceID = currentSID
            }
        }

        retileNow()
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

    private func handleSpaceChangeStability() {
        spaceSamplingTimer?.cancel()
        spaceSamplingCount = 0
        lastSampledWindowIDs = nil

        let interval = max(15, config.spaceChangeDebounceMs)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.spaceSamplingCount += 1
            let current = self.onScreenWindowIDs()
            let currentSID = self.currentActiveSpaceID()

            let spaceIDChanged = (self.activeSpaceID != nil && currentSID != self.activeSpaceID)
            let isMinSettled = self.spaceSamplingCount >= 6
            let isStable = isMinSettled && current != nil && !current!.isEmpty && current == self.lastSampledWindowIDs && (spaceIDChanged || self.spaceSamplingCount >= 10)
            let isTimeout = self.spaceSamplingCount >= 16

            if isStable || isTimeout {
                self.spaceSamplingTimer?.cancel()
                self.spaceSamplingTimer = nil
                self.lastSampledWindowIDs = nil
                self.rescanAfterSpaceChange()

                // Final trailing pass after macOS space animation fully completes
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
                    self?.rescanAfterSpaceChange()
                }
            } else {
                self.lastSampledWindowIDs = current
            }
        }
        spaceSamplingTimer = timer
        timer.resume()
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
            handleSpaceChangeStability()
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
