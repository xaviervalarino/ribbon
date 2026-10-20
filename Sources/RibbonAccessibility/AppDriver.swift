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
        /// A slide's settled frame; a later slide moving the window carries its own final, so this one is dropped.
        public let isSlideFinal: Bool

        public init(
            element: AXElement,
            windowID: CGWindowID,
            frame: CGRect,
            needsFullFrame: Bool,
            needsMove: Bool = true,
            shouldFocus: Bool = false,
            isSlideFinal: Bool = false
        ) {
            self.element = element
            self.windowID = windowID
            self.frame = frame
            self.needsFullFrame = needsFullFrame
            self.needsMove = needsMove
            self.shouldFocus = shouldFocus
            self.isSlideFinal = isSlideFinal
        }
    }

    public struct SlideStep: Sendable {
        public let element: AXElement
        public let windowID: CGWindowID
        public let origin: CGPoint
        /// Set only when the slide animates size; each step then costs a full AX resize.
        public let size: CGSize?

        public init(element: AXElement, windowID: CGWindowID, origin: CGPoint, size: CGSize? = nil) {
            self.element = element
            self.windowID = windowID
            self.origin = origin
            self.size = size
        }
    }

    /// Writes intermediate slide frames; the final mutation does logging and size bookkeeping.
    public func slide(_ steps: [SlideStep]) {
        for step in steps {
            // A resize the window has not started yet would stall this slide; the slide's own final resizes it.
            if let pending = pendingMutations[step.windowID], pending.isSlideFinal {
                pendingMutations[step.windowID] = pending.shouldFocus
                    ? WindowMutation(element: pending.element, windowID: pending.windowID, frame: pending.frame,
                                     needsFullFrame: false, needsMove: false, shouldFocus: true)
                    : nil
            }
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
    /// Called with a window's live height when it stays taller than a resize asked for.
    private let onMinHeight: ((CGWindowID, Double) -> Void)?

    public init(pid: pid_t, onMinHeight: ((CGWindowID, Double) -> Void)? = nil) {
        self.pid = pid
        self.onMinHeight = onMinHeight
    }

    /// Enqueues window mutations for this application process.
    /// New mutations for the same window overwrite pending ones to coalesce rapid retiles.
    /// Returns once the queue is drained, or at once when a drain already in progress picks them up.
    public func enqueue(_ mutations: [WindowMutation]) async {
        for mutation in mutations {
            if let existing = pendingMutations[mutation.windowID] {
                pendingMutations[mutation.windowID] = WindowMutation(
                    element: mutation.element,
                    windowID: mutation.windowID,
                    // A focus-only mutation carries the frame from when it was made, which a retarget can outdate.
                    frame: mutation.needsMove ? mutation.frame : existing.frame,
                    needsFullFrame: mutation.needsFullFrame || existing.needsFullFrame,
                    needsMove: mutation.needsMove || existing.needsMove,
                    shouldFocus: mutation.shouldFocus || existing.shouldFocus,
                    isSlideFinal: mutation.needsMove ? mutation.isSlideFinal : existing.isSlideFinal
                )
            } else {
                pendingMutations[mutation.windowID] = mutation
            }
        }
        guard !isDraining else { return }
        isDraining = true
        await drainQueue()
        isDraining = false
    }

    /// Focus targets first, so incoming focused windows move on screen before outgoing ones stash.
    private func popNextMutation() -> WindowMutation? {
        let next = pendingMutations.values.min { a, b in
            if a.shouldFocus != b.shouldFocus { return a.shouldFocus }
            return a.windowID < b.windowID
        }
        if let next { pendingMutations.removeValue(forKey: next.windowID) }
        return next
    }

    private func drainQueue() async {
        let appElem = AXElement.application(pid: pid)
        _ = appElem.setMessagingTimeout(Self.defaultTimeoutSeconds)

        let wasEnhanced = appElem.enhancedUserInterface
        // AXEnhancedUserInterface causes AppKit and Gecko to animate window frame changes.
        // Keep it disabled unless VoiceOver is actively running.
        if wasEnhanced {
            appElem.enhancedUserInterface = false
        }

        var focusTarget: WindowMutation?

        while let mutation = popNextMutation() {
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
                // Apps hold windows at their minimum height; the layout makes room once it knows it.
                if let live = mutation.element.size, live.height >= mutation.frame.height + 2 {
                    onMinHeight?(winID, live.height)
                }
            } else {
                // Pure translation: single AX position write with zero resize roundtrips.
                mutation.element.position = mutation.frame.origin
                RibbonLog.log(
                    "AX position applied wid=\(winID) pid=\(pid) target=\(mutation.frame.origin)",
                    category: "layout"
                )
            }
            lastAppliedSizes[winID] = mutation.frame.size
            // Each resize blocks this app for tens of ms; yielding lets a new slide's steps run
            // between them and drop finals it replaces.
            await Task.yield()
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
}
