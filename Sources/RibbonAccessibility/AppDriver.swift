import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Serial background actor dedicated to a single application process (pid).
///
/// Isolates all blocking AXUIElement calls away from the main thread.
/// Enforces a hard 250ms Mach messaging timeout so that hanging, frozen,
/// or beachballing applications never stall Ribbon daemon responsiveness.
public actor AppDriver {
    public let pid: pid_t
    public static let defaultTimeoutSeconds: Float = 0.250

    public struct WindowMutation: Sendable {
        public let element: AXElement
        public let windowID: CGWindowID
        public let frame: CGRect
        public let needsFullFrame: Bool
        public let needsMove: Bool
        public let shouldFocus: Bool

        public init(
            element: AXElement,
            windowID: CGWindowID,
            frame: CGRect,
            needsFullFrame: Bool,
            needsMove: Bool = true,
            shouldFocus: Bool = false
        ) {
            self.element = element
            self.windowID = windowID
            self.frame = frame
            self.needsFullFrame = needsFullFrame
            self.needsMove = needsMove
            self.shouldFocus = shouldFocus
        }
    }

    public struct SlideStep: Sendable {
        public let element: AXElement
        public let origin: CGPoint
        /// Set only when the slide animates size; each step then costs a full AX resize.
        public let size: CGSize?

        public init(element: AXElement, origin: CGPoint, size: CGSize? = nil) {
            self.element = element
            self.origin = origin
            self.size = size
        }
    }

    /// Writes intermediate slide frames; the final mutation does logging and size bookkeeping.
    public func slide(_ steps: [SlideStep]) {
        for step in steps {
            _ = step.element.setMessagingTimeout(Self.defaultTimeoutSeconds)
            if let size = step.size {
                step.element.setFrame(CGRect(origin: step.origin, size: size))
            } else {
                step.element.position = step.origin
            }
        }
    }

    private var pendingMutations: [CGWindowID: WindowMutation] = [:]
    private var lastAppliedSizes: [CGWindowID: CGSize] = [:]
    private var isDraining: Bool = false

    public init(pid: pid_t) {
        self.pid = pid
    }

    /// Enqueues window mutations for this application process.
    /// New mutations for the same window overwrite pending ones to coalesce rapid retiles.
    public func enqueue(_ mutations: [WindowMutation]) {
        for mutation in mutations {
            if let existing = pendingMutations[mutation.windowID] {
                pendingMutations[mutation.windowID] = WindowMutation(
                    element: mutation.element,
                    windowID: mutation.windowID,
                    frame: mutation.frame,
                    needsFullFrame: mutation.needsFullFrame || existing.needsFullFrame,
                    needsMove: mutation.needsMove || existing.needsMove,
                    shouldFocus: mutation.shouldFocus || existing.shouldFocus
                )
            } else {
                pendingMutations[mutation.windowID] = mutation
            }
        }
        guard !isDraining else { return }
        isDraining = true
        drainQueue()
    }

    private func drainQueue() {
        let appElem = AXElement.application(pid: pid)
        _ = appElem.setMessagingTimeout(Self.defaultTimeoutSeconds)

        while !pendingMutations.isEmpty {
            let batch = pendingMutations
            pendingMutations.removeAll(keepingCapacity: true)

            let wasEnhanced = appElem.enhancedUserInterface
            // AXEnhancedUserInterface causes AppKit and Gecko to animate window frame changes.
            // Keep it disabled unless VoiceOver is actively running.
            if wasEnhanced {
                appElem.enhancedUserInterface = false
            }

            // Move incoming focused windows onto the screen before stashing outgoing windows.
            let orderedMutations = batch.values.sorted { a, b in
                if a.shouldFocus != b.shouldFocus { return a.shouldFocus }
                return a.windowID < b.windowID
            }

            var focusTarget: WindowMutation?

            for mutation in orderedMutations {
                let winID = mutation.windowID
                if mutation.shouldFocus {
                    focusTarget = mutation
                }
                guard mutation.needsMove else { continue }

                _ = mutation.element.setMessagingTimeout(Self.defaultTimeoutSeconds)

                // An invalidated diff cache means the user may have resized the window; read its live size.
                let currentKnownSize = mutation.needsFullFrame
                    ? mutation.element.size
                    : (lastAppliedSizes[winID] ?? mutation.element.size)
                let sizeChanged: Bool = {
                    guard let cur = currentKnownSize else { return mutation.needsFullFrame }
                    return abs(cur.width - mutation.frame.size.width) >= 1.5 ||
                           abs(cur.height - mutation.frame.size.height) >= 1.5
                }()

                if sizeChanged {
                    // Window size genuinely changed: AX resize required so target app reflows views.
                    mutation.element.setFrame(mutation.frame)
                    RibbonLog.log(
                        "AX frame applied wid=\(winID) pid=\(pid) target=\(mutation.frame.integral)",
                        category: "layout"
                    )
                } else {
                    // Pure translation: single AX position write with zero resize roundtrips.
                    mutation.element.position = mutation.frame.origin
                    RibbonLog.log(
                        "AX position applied wid=\(winID) pid=\(pid) target=\(mutation.frame.origin)",
                        category: "layout"
                    )
                }
                lastAppliedSizes[winID] = mutation.frame.size
            }

            if let target = focusTarget {
                _ = target.element.setMessagingTimeout(Self.defaultTimeoutSeconds)
                NSRunningApplication(processIdentifier: pid)?.activate()
                target.element.focus()
            }

            if wasEnhanced && NSWorkspace.shared.isVoiceOverEnabled {
                appElem.enhancedUserInterface = true
            }
        }
        isDraining = false
    }
}
