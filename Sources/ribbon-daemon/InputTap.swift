import Foundation
import CoreGraphics

private let gestureEventType = CGEventType(rawValue: 29)!

protocol InputTapDelegate: AnyObject {
    func mouseUp()
    func mouseMoved(dx: Double, dy: Double)
    func scrolled(dx: Double, dy: Double, phase: CGScrollPhase, momentum: CGMomentumScrollPhase)
    func gesture(_ event: CGEvent)
}

private let inputTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<InputTap>.fromOpaque(userInfo).takeUnretainedValue()
    tap.handleEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class InputTap {
    weak var delegate: InputTapDelegate?
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var loggedUnavailable = false

    func start() {
        stop()

        let events: [CGEventType] = [
            .leftMouseUp,
            .mouseMoved,
            .leftMouseDragged,
            .scrollWheel,
            gestureEventType
        ]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !loggedUnavailable {
                loggedUnavailable = true
                RibbonLog.log("input tap unavailable: grant Input Monitoring to Ribbon.app", category: "input")
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapPort = port
        runLoopSource = source
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
            if let port = tapPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
        case .leftMouseUp:
            delegate?.mouseUp()
        case .mouseMoved, .leftMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            delegate?.mouseMoved(dx: dx, dy: dy)
        case .scrollWheel:
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let phaseRaw = UInt32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventScrollPhase))
            let momentumRaw = UInt32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
            let phase = CGScrollPhase(rawValue: phaseRaw) ?? .changed
            let momentum = CGMomentumScrollPhase(rawValue: momentumRaw) ?? .none
            delegate?.scrolled(dx: dx, dy: dy, phase: phase, momentum: momentum)
        case gestureEventType:
            delegate?.gesture(event)
        default:
            break
        }
    }
}
