import Foundation
import CoreGraphics

private let gestureEventType = CGEventType(rawValue: 29)!
private let swipeEventType = CGEventType(rawValue: 31)!

protocol InputTapDelegate: AnyObject {
    func mouseUp()
    /// Horizontal mouse or scroll travel.
    func pointerMoved(dx: Double)
    func gesture(_ event: CGEvent)
    func swipe(_ event: CGEvent)
}

private let inputTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<InputTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handleEvent(type: type, event: event) ? Unmanaged.passUnretained(event) : nil
}

final class InputTap {
    weak var delegate: InputTapDelegate?
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var loggedUnavailable = false
    private var gestureMonitoring = false
    private var pointerMonitoring = false
    /// While a pan is held the cursor stays where the hold began and mouse motion only pans: each
    /// move warps it back. A warp holds off local mouse events for the suppression interval;
    /// 0.07s is the shortest that still holds the cursor still, and the default 0.25s would stall
    /// it after release.
    private var frozenPointer: CGPoint?
    private var defaultSuppressionInterval: CFTimeInterval = 0.25

    /// Mouse-up only arrives while the tap runs; drag state that waits for it checks this first.
    var isRunning: Bool { tapPort != nil }

    /// Only events with a delegate consumer are in the mask: every masked event wakes the main
    /// run loop, and a backed-up port drops events (a lost mouse-up included).
    private var events: [CGEventType] {
        var list: [CGEventType] = [.leftMouseUp]
        if pointerMonitoring {
            list.append(contentsOf: [.mouseMoved, .scrollWheel])
        }
        if gestureMonitoring {
            list.append(contentsOf: [gestureEventType, swipeEventType])
        }
        return list
    }

    func setPointerMonitoring(_ on: Bool) {
        guard on != pointerMonitoring else { return }
        pointerMonitoring = on
        on ? freezePointer() : unfreezePointer()
        start()
    }

    private func freezePointer() {
        guard let location = CGEvent(source: nil)?.location,
              let source = CGEventSource(stateID: .combinedSessionState) else { return }
        if frozenPointer == nil {
            defaultSuppressionInterval = source.localEventsSuppressionInterval
        }
        source.localEventsSuppressionInterval = 0.07
        frozenPointer = location
    }

    func unfreezePointer() {
        guard let point = frozenPointer,
              let source = CGEventSource(stateID: .combinedSessionState) else { return }
        frozenPointer = nil
        // A zero interval hands the cursor back to the mouse at once after the last warp.
        source.localEventsSuppressionInterval = 0
        CGWarpMouseCursorPosition(point)
        source.localEventsSuppressionInterval = defaultSuppressionInterval
    }

    func setGestureMonitoring(_ on: Bool) {
        guard on != gestureMonitoring else { return }
        gestureMonitoring = on
        start()
    }

    func start() {
        stop()

        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // A held pan swallows scrolls, which needs an active tap; outside a pan the tap only
            // listens, so input never waits on the main run loop.
            options: pointerMonitoring ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !loggedUnavailable {
                loggedUnavailable = true
                RibbonLog.log("input tap unavailable: CGEvent.tapCreate returned nil", category: "input")
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapPort = port
        runLoopSource = source
        RibbonLog.log("input tap started", category: "input")
    }

    func stop() {
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            tapPort = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    /// Returns false to drop the event before it reaches apps.
    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            guard let port = tapPort else { return true }
            CGEvent.tapEnable(tap: port, enable: true)
            RibbonLog.log("input tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")", category: "input")
            // Events are dropped while the tap is disabled; a released button means the mouse-up was one of them.
            // Not during a held pan: a mouse-up ends the pan, and a main-thread stall is no click.
            if !pointerMonitoring && !CGEventSource.buttonState(.combinedSessionState, button: .left) {
                delegate?.mouseUp()
            }
        case .leftMouseUp:
            delegate?.mouseUp()
        case .mouseMoved:
            if let frozenPointer {
                CGWarpMouseCursorPosition(frozenPointer)
            }
            delegate?.pointerMoved(dx: event.getDoubleValueField(.mouseEventDeltaX))
        case .scrollWheel:
            delegate?.pointerMoved(dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
            // A scroll that pans the strip must not also scroll or swipe-navigate the app under the cursor.
            return !pointerMonitoring
        case gestureEventType:
            delegate?.gesture(event)
        case swipeEventType:
            delegate?.swipe(event)
        default:
            break
        }
        return true
    }
}
