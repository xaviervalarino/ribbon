import Foundation
import AppKit
import ApplicationServices

public enum AppEventKind {
    case hidden
    case unhidden
    /// Observation started late (the app's AX was not ready at launch), so windows it created
    /// before then sent no notification.
    case observedLate
    case spaceChanged
}

public protocol AXEventObserverDelegate: AnyObject {
    func windowCreated(element: AXElement, pid: pid_t)
    func windowDestroyed(element: AXElement, pid: pid_t)
    func windowFocused(element: AXElement, pid: pid_t)
    func applicationTerminated(pid: pid_t)
    func windowMinimized(element: AXElement, pid: pid_t)
    func windowDeminiaturized(element: AXElement, pid: pid_t)
    func windowResized(element: AXElement, pid: pid_t)
    func windowMoved(element: AXElement, pid: pid_t)
    func applicationActivated(pid: pid_t)
    func applicationEventOccurred(kind: AppEventKind, pid: pid_t?)
}

public final class AXEventObserver {
    public weak var delegate: AXEventObserverDelegate?
    /// Owner-supplied admission policy; return false to skip observing an app.
    public var shouldObserve: ((NSRunningApplication) -> Bool)?
    private var observers: [pid_t: AXObserver] = [:]
    private var pendingWindowRegistrations: [pid_t: [AXElement]] = [:]
    private var pendingRetryPids: Set<pid_t> = []
    /// Apps whose observation failed at least once; windows they create before it succeeds send nothing.
    private var failedObservePids: Set<pid_t> = []
    private var isRunning: Bool = false
    private static let retryDelays: [TimeInterval] = [0.5, 1.0, 2.0, 4.0]
    /// Returns true while main-thread handlers must wait (a scroll slide is running): their AX
    /// reads block on busy apps and would freeze the slide's frames.
    public var shouldDeferEvents: (() -> Bool)?
    private var deferredEvents: [String: () -> Void] = [:]
    private var deferredOrder: [String] = []
    private var replayingArrival: DispatchTime?

    /// When the event being handled arrived. Echo checks compare deadlines against this, so an
    /// event held during a slide is judged by when it happened, not when it was replayed.
    public var currentEventTime: DispatchTime {
        replayingArrival ?? .now()
    }

    public init() {}

    public func start() {
        isRunning = true
        // Watch for launched applications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        // Watch for terminated applications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Watch for activated applications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Watch for hidden applications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppHidden(_:)),
            name: NSWorkspace.didHideApplicationNotification,
            object: nil
        )

        // Watch for unhidden applications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppUnhidden(_:)),
            name: NSWorkspace.didUnhideApplicationNotification,
            object: nil
        )

        // Watch for active Space changes
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // Observe already-running applications
        for app in NSWorkspace.shared.runningApplications {
            if app.activationPolicy == .regular {
                observeApplication(pid: app.processIdentifier)
            }
        }
    }

    public func stop() {
        isRunning = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for (_, observer) in observers {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observers.removeAll()
        pendingWindowRegistrations.removeAll()
        pendingRetryPids.removeAll()
        failedObservePids.removeAll()
    }

    @objc private func handleAppLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.activationPolicy == .regular else { return }
        observeApplication(pid: app.processIdentifier)
    }

    @objc private func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        pendingWindowRegistrations.removeValue(forKey: pid)
        removeObserver(pid: pid)
        delegate?.applicationTerminated(pid: pid)
    }

    @objc private func handleAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        // An app can launch before its activation policy turns regular, so the launch skipped it.
        if app.activationPolicy == .regular {
            observeApplication(pid: pid)
        }
        runOrDefer(key: "didActivateApplication", label: "didActivateApplication", pid: pid) { [weak self] in
            self?.delegate?.applicationActivated(pid: pid)
        }
    }

    private func runOrDefer(key: String, label: String, pid: pid_t, _ work: @escaping () -> Void) {
        if shouldDeferEvents?() == true {
            let arrival = DispatchTime.now()
            deferredOrder.removeAll { $0 == key }
            deferredOrder.append(key)
            deferredEvents[key] = { [weak self] in
                self?.replayingArrival = arrival
                let started = DispatchTime.now()
                work()
                Self.logIfSlow("\(label) (replayed)", pid: pid, since: started)
                self?.replayingArrival = nil
            }
            return
        }
        let started = DispatchTime.now()
        work()
        Self.logIfSlow(label, pid: pid, since: started)
    }

    /// Runs the events held during a slide, once each, in order of their latest arrival.
    public func flushDeferredEvents() {
        let order = deferredOrder
        let events = deferredEvents
        deferredOrder.removeAll()
        deferredEvents.removeAll()
        for key in order {
            events[key]?()
        }
    }

    /// Main-thread handlers longer than 20ms stall scroll slides; name them in the log.
    static func logIfSlow(_ event: String, pid: pid_t, since started: DispatchTime) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        guard ms > 20 else { return }
        RibbonLog.log("slow main-thread handler \(event) pid=\(pid) took \(Int(ms))ms", category: "stall")
    }

    @objc private func handleAppHidden(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        delegate?.applicationEventOccurred(kind: .hidden, pid: app.processIdentifier)
    }

    @objc private func handleAppUnhidden(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        delegate?.applicationEventOccurred(kind: .unhidden, pid: app.processIdentifier)
    }

    @objc private func handleActiveSpaceChanged(_ notification: Notification) {
        delegate?.applicationEventOccurred(kind: .spaceChanged, pid: nil)
    }

    public func observeApplication(pid: pid_t) {
        observeApplication(pid: pid, attempt: 0)
    }

    private func observeApplication(pid: pid_t, attempt: Int) {
        guard isRunning, observers[pid] == nil else { return }

        if let shouldObserve = shouldObserve,
           let app = NSRunningApplication(processIdentifier: pid),
           !shouldObserve(app) {
            return
        }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let this = Unmanaged<AXEventObserver>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let axElem = AXElement(element)
            let notifString = notification as String
            DispatchQueue.main.async {
                guard this.isRunning else { return }
                // Later events of the same kind for the same window supersede held ones.
                let key = "\(notifString)-\(pid)-\(CFHash(element))"
                this.runOrDefer(key: key, label: notifString, pid: pid) {
                    switch notifString {
                    case kAXWindowCreatedNotification:
                        this.delegate?.windowCreated(element: axElem, pid: pid)
                    case kAXUIElementDestroyedNotification:
                        this.delegate?.windowDestroyed(element: axElem, pid: pid)
                    case kAXFocusedWindowChangedNotification:
                        this.delegate?.windowFocused(element: axElem, pid: pid)
                    case kAXWindowMiniaturizedNotification:
                        this.delegate?.windowMinimized(element: axElem, pid: pid)
                    case kAXWindowDeminiaturizedNotification:
                        this.delegate?.windowDeminiaturized(element: axElem, pid: pid)
                    case kAXWindowResizedNotification, kAXResizedNotification:
                        this.delegate?.windowResized(element: axElem, pid: pid)
                    case kAXWindowMovedNotification, kAXMovedNotification:
                        this.delegate?.windowMoved(element: axElem, pid: pid)
                    default:
                        break
                    }
                }
            }
        }

        func retryLater() {
            guard attempt < Self.retryDelays.count, !pendingRetryPids.contains(pid) else { return }
            pendingRetryPids.insert(pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
                guard let self, self.isRunning, self.pendingRetryPids.remove(pid) != nil else { return }
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
                self.observeApplication(pid: pid, attempt: attempt + 1)
            }
        }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let error = AXObserverCreate(pid, callback, &observer)
        guard error == .success, let obs = observer else {
            failedObservePids.insert(pid)
            retryLater()
            return
        }

        let appElement = AXElement.application(pid: pid).rawElement
        let notifications = [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification
        ]

        var observesCreation = true
        for notif in notifications {
            let result = AXObserverAddNotification(obs, appElement, notif as CFString, refcon)
            // A just-launched app answers cannotComplete until its AX is up; an observer without
            // window creation never sees its windows, so it is dropped and retried. After the last
            // retry it is kept for the notifications that did register (focus still adopts).
            if result != .success, notif == kAXWindowCreatedNotification {
                RibbonLog.log("AX observe failed pid=\(pid) err=\(result.rawValue) attempt=\(attempt)", category: "discovery")
                failedObservePids.insert(pid)
                observesCreation = false
                if attempt < Self.retryDelays.count {
                    retryLater()
                    return
                }
            }
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
        if failedObservePids.remove(pid) != nil {
            if observesCreation {
                RibbonLog.log("AX observe succeeded late pid=\(pid) attempt=\(attempt)", category: "discovery")
            } else {
                RibbonLog.log("AX observe kept without window creation pid=\(pid) attempts=\(attempt + 1)", category: "discovery")
            }
            // Without window creation, the sweep is the only way the app's existing windows join.
            // Callers include discovery and tiling loops, so the sweep runs on a later turn, held
            // like other app events while a slide runs.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.runOrDefer(key: "observedLate-\(pid)", label: "observedLate", pid: pid) { [weak self] in
                    self?.delegate?.applicationEventOccurred(kind: .observedLate, pid: pid)
                }
            }
        }

        if let pending = pendingWindowRegistrations.removeValue(forKey: pid) {
            for element in pending {
                registerWindowNotifications(obs: obs, element: element.rawElement, refcon: refcon)
            }
        }
    }

    private func registerWindowNotifications(obs: AXObserver, element: AXUIElement, refcon: UnsafeMutableRawPointer) {
        let windowNotifs = [
            kAXUIElementDestroyedNotification,
            kAXResizedNotification,
            kAXWindowResizedNotification,
            kAXMovedNotification,
            kAXWindowMovedNotification
        ]
        for notif in windowNotifs {
            AXObserverAddNotification(obs, element, notif as CFString, refcon)
        }
    }

    public func observeWindow(element: AXElement, pid: pid_t) {
        guard isRunning else { return }
        observeApplication(pid: pid)
        guard let obs = observers[pid] else {
            pendingWindowRegistrations[pid, default: []].append(element)
            return
        }
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        registerWindowNotifications(obs: obs, element: element.rawElement, refcon: refcon)
    }

    public func removeObserver(pid: pid_t) {
        pendingWindowRegistrations.removeValue(forKey: pid)
        pendingRetryPids.remove(pid)
        failedObservePids.remove(pid)
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
    }
}
