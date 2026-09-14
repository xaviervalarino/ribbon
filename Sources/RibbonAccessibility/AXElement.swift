import Foundation
import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

public final class AXElement {
    public let rawElement: AXUIElement

    public init(_ rawElement: AXUIElement) {
        self.rawElement = rawElement
    }

    public static func application(pid: pid_t) -> AXElement {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 1.0)
        return AXElement(app)
    }

    public static func systemWide() -> AXElement {
        return AXElement(AXUIElementCreateSystemWide())
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

    public var position: CGPoint? {
        get {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(rawElement, kAXPositionAttribute as CFString, &value)
            guard error == .success, let axVal = value else { return nil }
            var point = CGPoint.zero
            AXValueGetValue(axVal as! AXValue, .cgPoint, &point)
            return point
        }
        set {
            guard var newPoint = newValue else { return }
            guard let axVal = AXValueCreate(.cgPoint, &newPoint) else { return }
            AXUIElementSetAttributeValue(rawElement, kAXPositionAttribute as CFString, axVal)
        }
    }

    public var size: CGSize? {
        get {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(rawElement, kAXSizeAttribute as CFString, &value)
            guard error == .success, let axVal = value else { return nil }
            var size = CGSize.zero
            AXValueGetValue(axVal as! AXValue, .cgSize, &size)
            return size
        }
        set {
            guard var newSize = newValue else { return }
            guard let axVal = AXValueCreate(.cgSize, &newSize) else { return }
            AXUIElementSetAttributeValue(rawElement, kAXSizeAttribute as CFString, axVal)
        }
    }

    public var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    public func setFrame(_ rect: CGRect) {
        // Set size first then position (or position then size) to avoid WindowServer bounce
        size = rect.size
        position = rect.origin
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
