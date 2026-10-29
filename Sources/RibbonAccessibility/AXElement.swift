import Foundation
import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

/// Wraps an opaque CoreFoundation AXUIElementRef pointer.
/// Marked @unchecked Sendable because macOS Accessibility APIs are thread-safe across Mach message ports.
public final class AXElement: @unchecked Sendable {
    public let rawElement: AXUIElement

    public init(_ rawElement: AXUIElement) {
        self.rawElement = rawElement
    }

    public static func application(pid: pid_t) -> AXElement {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.250)
        return AXElement(app)
    }

    public static func systemWide() -> AXElement {
        return AXElement(AXUIElementCreateSystemWide())
    }

    @discardableResult
    public func setMessagingTimeout(_ timeoutInSeconds: Float) -> AXError {
        return AXUIElementSetMessagingTimeout(rawElement, timeoutInSeconds)
    }

    // MARK: - Attributes

    public var windowID: CGWindowID? {
        var id: CGWindowID = 0
        let error = _AXUIElementGetWindow(rawElement, &id)
        guard error == .success, id != 0 else { return nil }
        return id
    }

    public var title: String {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(rawElement, kAXTitleAttribute as CFString, &value)
        guard error == .success, let str = value as? String else { return "" }
        return str
    }

    public var role: String {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(rawElement, kAXRoleAttribute as CFString, &value)
        guard error == .success, let str = value as? String else { return "" }
        return str
    }

    public var subrole: String {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(rawElement, kAXSubroleAttribute as CFString, &value)
        guard error == .success, let str = value as? String else { return "" }
        return str
    }

    public func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(rawElement, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    /// True when the attribute answers with a value: a title-bar button that exists, a flag that is set.
    public func hasValue(_ attribute: String) -> Bool {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(rawElement, attribute as CFString, &value) == .success && value != nil
    }

    public func bool(_ attribute: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(rawElement, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    public var position: CGPoint? {
        get {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(rawElement, kAXPositionAttribute as CFString, &value)
            guard error == .success,
                  let axVal = value,
                  CFGetTypeID(axVal) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            guard AXValueGetValue(axVal as! AXValue, .cgPoint, &point) else { return nil }
            return point
        }
        set {
            guard let newPoint = newValue else { return }
            setPosition(newPoint)
        }
    }

    @discardableResult
    public func setPosition(_ p: CGPoint) -> AXError {
        var point = p
        guard let axVal = AXValueCreate(.cgPoint, &point) else { return .failure }
        return AXUIElementSetAttributeValue(rawElement, kAXPositionAttribute as CFString, axVal)
    }

    public var size: CGSize? {
        get {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(rawElement, kAXSizeAttribute as CFString, &value)
            guard error == .success,
                  let axVal = value,
                  CFGetTypeID(axVal) == AXValueGetTypeID() else { return nil }
            var size = CGSize.zero
            guard AXValueGetValue(axVal as! AXValue, .cgSize, &size) else { return nil }
            return size
        }
        set {
            guard let newSize = newValue else { return }
            setSize(newSize)
        }
    }

    @discardableResult
    public func setSize(_ s: CGSize) -> AXError {
        var size = s
        guard let axVal = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(rawElement, kAXSizeAttribute as CFString, axVal)
    }

    public var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    public func setFrame(_ rect: CGRect) -> AXError {
        // WindowServer clamps size if current origin leaves insufficient space,
        // and clamps origin if current size exceeds destination boundaries.
        // Apply position first so expanding windows can grow, size to update dimensions,
        // then position again so shrinking windows placed near screen edges clear clamps.
        // The final position write decides where the window ends up, so its result is the one
        // reported; a size the window refuses (a fixed-size window) is no failure a retry fixes.
        setPosition(rect.origin)
        setSize(rect.size)
        return setPosition(rect.origin)
    }

    public var isHidden: Bool {
        get {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(rawElement, kAXHiddenAttribute as CFString, &value)
            guard error == .success, let boolVal = value as? Bool else { return false }
            return boolVal
        }
        set {
            let cfBool: CFBoolean = newValue ? kCFBooleanTrue : kCFBooleanFalse
            AXUIElementSetAttributeValue(rawElement, kAXHiddenAttribute as CFString, cfBool)
        }
    }

    public var enhancedUserInterface: Bool {
        get {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(rawElement, "AXEnhancedUserInterface" as CFString, &value)
            guard error == .success, let boolVal = value as? Bool else { return false }
            return boolVal
        }
        set {
            let cfBool: CFBoolean = newValue ? kCFBooleanTrue : kCFBooleanFalse
            AXUIElementSetAttributeValue(rawElement, "AXEnhancedUserInterface" as CFString, cfBool)
        }
    }

    public var isMinimized: Bool {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(rawElement, kAXMinimizedAttribute as CFString, &value)
        guard error == .success, let boolVal = value as? Bool else { return false }
        return boolVal
    }

    public var isFullscreen: Bool {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(rawElement, "AXFullScreen" as CFString, &value)
        guard error == .success, let boolVal = value as? Bool else { return false }
        return boolVal
    }

    public var windows: [AXElement] {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(rawElement, kAXWindowsAttribute as CFString, &value)
        guard error == .success, let array = value as? [AXUIElement] else { return [] }
        return array.map { AXElement($0) }
    }

    public var focusedWindow: AXElement? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(rawElement, kAXFocusedWindowAttribute as CFString, &value)
        guard error == .success, let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    // MARK: - Actions

    public func raise() {
        AXUIElementPerformAction(rawElement, kAXRaiseAction as CFString)
    }

    public func focus() {
        raise()
        AXUIElementSetAttributeValue(rawElement, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
}
