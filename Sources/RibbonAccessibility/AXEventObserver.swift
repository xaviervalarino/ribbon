import Foundation
import AppKit
import ApplicationServices

public enum AppEventKind {
    case hidden
    case unhidden
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
    private var isRunning: Bool = false
    private static let retryDelays: [TimeInterval] = [0.5, 1.0, 2.0]
    /// Returns true while main-thread handlers must wait (a scroll slide is running): their AX
    /// reads block on busy apps and would freeze the slide's frames.
    public var shouldDeferEvents: (() -> Bool)?
    private var deferredEvents: [String: () -> Void] = [:]
    private var deferredOrder: [String] = []

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
    }

    @objc private func handleAppLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
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
        runOrDefer(key: "didActivateApplication", label: "didActivateApplication", pid: pid) { [weak self] in
            self?.delegate?.applicationActivated(pid: pid)
        }
    }

    private func runOrDefer(key: String, label: String, pid: pid_t, _ work: @escaping () -> Void) {
        if shouldDeferEvents?() == true {
            deferredOrder.removeAll { $0 == key }
            deferredOrder.append(key)
            deferredEvents[key] = work
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

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let error = AXObserverCreate(pid, callback, &observer)
        guard error == .success, let obs = observer else {
            if attempt < Self.retryDelays.count {
                guard !pendingRetryPids.contains(pid) else { return }
                pendingRetryPids.insert(pid)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
                    guard let self, self.isRunning, self.pendingRetryPids.remove(pid) != nil else { return }
                    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
                    self.observeApplication(pid: pid, attempt: attempt + 1)
                }
            }
            return
        }

        let appElement = AXElement.application(pid: pid).rawElement
        let notifications = [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification
        ]

        for notif in notifications {
            AXObserverAddNotification(obs, appElement, notif as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs

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
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
    }
}
