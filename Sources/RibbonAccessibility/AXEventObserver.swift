import Foundation
import AppKit
import ApplicationServices
import RibbonCore

public protocol AXEventObserverDelegate: AnyObject {
    func windowCreated(element: AXElement, pid: pid_t)
    func windowDestroyed(element: AXElement, pid: pid_t)
    func windowFocused(element: AXElement, pid: pid_t)
}

public final class AXEventObserver {
    public weak var delegate: AXEventObserverDelegate?
    private var observers: [pid_t: AXObserver] = [:]

    public init() {}

    public func start() {
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

        // Observe already-running applications
        for app in NSWorkspace.shared.runningApplications {
            if app.activationPolicy == .regular {
                observeApplication(pid: app.processIdentifier)
            }
        }
    }

    public func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for (_, observer) in observers {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observers.removeAll()
    }

    @objc private func handleAppLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        observeApplication(pid: app.processIdentifier)
    }

    @objc private func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        removeObserver(pid: app.processIdentifier)
    }

    public func observeApplication(pid: pid_t) {
        guard observers[pid] == nil else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let this = Unmanaged<AXEventObserver>.fromOpaque(refcon).takeUnretainedValue()
            let axElem = AXElement(element)
            let notifString = notification as String

            DispatchQueue.main.async {
                switch notifString {
                case kAXWindowCreatedNotification as String:
                    this.delegate?.windowCreated(element: axElem, pid: pid)
                case kAXUIElementDestroyedNotification as String:
                    this.delegate?.windowDestroyed(element: axElem, pid: pid)
                case kAXFocusedWindowChangedNotification as String:
                    this.delegate?.windowFocused(element: axElem, pid: pid)
                default:
                    break
                }
            }
        }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let error = AXObserverCreate(pid, callback, &observer)
        guard error == .success, let obs = observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let notifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification
        ]

        for notif in notifications {
            AXObserverAddNotification(obs, appElement, notif as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    public func removeObserver(pid: pid_t) {
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
    }
}
