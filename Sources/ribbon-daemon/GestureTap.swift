import Foundation
import CoreGraphics

private let gestureEventType = CGEventType(rawValue: 29)!
private let swipeEventType = CGEventType(rawValue: 31)!

private let gestureTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    Unmanaged<GestureTap>.fromOpaque(userInfo).takeUnretainedValue().handleEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

/// Listen-only tap for trackpad touch events (NSEvent `.gesture`) and system swipes (`.swipe`).
/// Touch events stream whenever a finger is on the trackpad, so they get their own port: a
/// backed-up port drops events, and `InputTap`'s port must not drop a mouse-up.
final class GestureTap {
    var onGesture: ((CGEvent) -> Void)?
    var onSwipe: ((CGEvent) -> Void)?
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var loggedUnavailable = false

    func start() {
        stop()

        let mask = (CGEventMask(1) << gestureEventType.rawValue) | (CGEventMask(1) << swipeEventType.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: gestureTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !loggedUnavailable {
                loggedUnavailable = true
                RibbonLog.log("gesture tap unavailable: CGEvent.tapCreate returned nil", category: "input")
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapPort = port
        runLoopSource = source
        RibbonLog.log("gesture tap started", category: "input")
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

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            guard let port = tapPort else { return }
            CGEvent.tapEnable(tap: port, enable: true)
            RibbonLog.log("gesture tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")", category: "input")
        case gestureEventType:
            onGesture?(event)
        case swipeEventType:
            onSwipe?(event)
        default:
            break
        }
    }
}
