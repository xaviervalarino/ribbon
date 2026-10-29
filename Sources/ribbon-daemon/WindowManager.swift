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

public final class WindowManager {
    public typealias SpaceID = UInt64
    public var ribbons: [SpaceID: Ribbon] = [:]
    public var activeSpaceID: SpaceID?
    public var activeDisplayID: CGDirectDisplayID?
    var displayBySpaceID: [SpaceID: CGDirectDisplayID] = [:]
    var spaceByWindowID: [CGWindowID: SpaceID] = [:]
    var displayByWindowID: [CGWindowID: CGDirectDisplayID] = [:]

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

    var allRibbonWindows: [WindowModel] {
        return ribbons.values.flatMap { $0.columns.flatMap { $0.windows } }
    }

    public var config = Config.default
    let observer = AXEventObserver()
    let inputTap = InputTap()
    let socketServer = SocketServer()
    var trackedWindows: [CGWindowID: AXElement] = [:]
    var windowIDsByElement: [AXUIElement: CGWindowID] = [:]
    var adoptedSinceLastSweep: Set<CGWindowID> = []
    var gcTimer: DispatchSourceTimer?
    var retileWork: DispatchWorkItem?
    var resizeDebounceWork: DispatchWorkItem?
    var isDisplayReconfiguring: Bool = false
    var dragDirty = false
    var panHeld = false
    var panHeldSince: DispatchTime?
    var orphanPanEndAt: DispatchTime?
    var panningSpaceID: SpaceID?
    lazy var panController = PanController(windowManager: self)
    struct TouchesProbeState {
        var isArmed = false
        var bucketTimer: DispatchSourceTimer?
        var endWork: DispatchWorkItem?
        var lastTouchCount = 0
        var lastMeanX: Double?
        var maxTouches = 0
        var events = 0
        var dx = 0.0
        var swipes = 0
        var swipeDX = 0.0
    }
    var touchesProbe = TouchesProbeState()
    var displaySamplingTimer: DispatchSourceTimer?
    var displaySamplingCount: Int = 0

    private struct DisplaySnapshot: Equatable {
        let displayIDs: [CGDirectDisplayID]
        let bounds: [CGRect]
    }
    private var lastSampledDisplaySnapshot: DisplaySnapshot?
    private var screenParametersObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    var lastAppliedFrames: [CGWindowID: CGRect] = [:]
    var lastStashedState: [CGWindowID: Bool] = [:]
    var lastNaturalFrames: [CGWindowID: CGRect] = [:]
    var pendingFocusEchoes: [CGWindowID: DispatchTime] = [:]
    /// Apps Ribbon is activating. Activation first reports the app's previously focused
    /// window, so any focus change from these apps before the deadline is an echo.
    var pendingFocusEchoPIDs: [pid_t: DispatchTime] = [:]
    var pendingFrameEchoes: [CGWindowID: DispatchTime] = [:]
    var originalFrames: [CGWindowID: CGRect] = [:]
    var isStopped = false
    var appDrivers: [pid_t: AppDriver] = [:]
    lazy var scrollAnimator = ScrollAnimator { [unowned self] pid in self.appDriver(for: pid) }

    func appDriver(for pid: pid_t) -> AppDriver {
        if let driver = appDrivers[pid] {
            return driver
        }
        let driver = AppDriver(pid: pid) { [weak self] id, height in
            DispatchQueue.main.async { self?.recordMinHeight(height, forWindowID: id) }
        }
        appDrivers[pid] = driver
        return driver
    }

    func recordMinHeight(_ height: Double, forWindowID id: CGWindowID) {
        for sID in ribbons.keys where ribbons[sID]?.raiseMinHeight(height, forWindowID: id) == true {
            RibbonLog.log("min height wid=\(id) \(Int(height))", category: "layout")
            lastAppliedFrames.removeValue(forKey: id)
            scheduleRetile()
        }
    }

    func removeAppDriver(for pid: pid_t) {
        appDrivers.removeValue(forKey: pid)
    }

    var restoreFramesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("ribbon")
            .appendingPathComponent("restore-frames.json")
    }

    private var restartStateURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ribbon-restart-\(getuid()).json")
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

        // Hold main-thread event handlers while a slide runs; replay them when it ends.
        observer.shouldDeferEvents = { [weak self] in self?.scrollAnimator.isActive ?? false }
        scrollAnimator.onIdle = { [weak self] in self?.observer.flushDeferredEvents() }
        scrollAnimator.onSettledFocus = { [weak self] id, pid in
            self?.expectFocusEcho(id: id, pid: pid, ms: 300)
        }

        // Start event observer
        observer.start()
        inputTap.delegate = self
        inputTap.start()

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
            guard let self else { return }
            // Gesture events arrive with no touches after sleep until the tap is recreated.
            self.inputTap.start()
            self.displayConfigurationChanged()
        }

        retileNow()
    }

    func loadPersistedOriginalFrames() {
        guard let data = try? Data(contentsOf: restoreFramesURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] else { return }
        for (key, values) in dict {
            guard let id = CGWindowID(key), values.count == 4 else { continue }
            originalFrames[id] = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
    }

    func persistOriginalFrames() {
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

    func loadRestartState() {
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: legacyConfigStateURL)
        try? FileManager.default.removeItem(at: restartStateURL)
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
        panController.stop()
        touchesProbe.bucketTimer?.cancel()
        touchesProbe.bucketTimer = nil
        touchesProbe.endWork?.cancel()
        touchesProbe.endWork = nil
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
        inputTap.unfreezePointer()
        inputTap.stop()
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

        appDrivers.removeAll()

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
}
