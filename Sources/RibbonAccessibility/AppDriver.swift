import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import os

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
        /// Skips per-write AX log lines during high-frequency flushes such as a strip pan.
        public let quiet: Bool

        public init(
            element: AXElement,
            windowID: CGWindowID,
            frame: CGRect,
            needsFullFrame: Bool,
            needsMove: Bool = true,
            shouldFocus: Bool = false,
            isSlideFinal: Bool = false,
            quiet: Bool = false
        ) {
            self.element = element
            self.windowID = windowID
            self.frame = frame
            self.needsFullFrame = needsFullFrame
            self.needsMove = needsMove
            self.shouldFocus = shouldFocus
            self.isSlideFinal = isSlideFinal
            self.quiet = quiet
        }

        /// Keeps only the focus, for when a newer mutation replaces this one's frame.
        public var focusOnly: WindowMutation? {
            guard shouldFocus else { return nil }
            return WindowMutation(element: element, windowID: windowID, frame: frame,
                                  needsFullFrame: false, needsMove: false, shouldFocus: true)
        }
    }

    /// The window the latest focus request targets. Each app's driver focuses on its own
    /// schedule, so a driver skips a focus that a newer request has replaced.
    private static let latestFocus = OSAllocatedUnfairLock<(id: CGWindowID, at: DispatchTime)?>(initialState: nil)

    /// Records a focus request made at `at`; returns false, changing nothing, when a newer one exists.
    /// Focus events arrive late (replayed after a slide, or answered by a lookup), so order goes by `at`.
    @discardableResult
    public static func focusRequested(_ windowID: CGWindowID, at: DispatchTime = .now()) -> Bool {
        latestFocus.withLock { latest in
            if let latest, latest.at > at { return false }
            latest = (windowID, at)
            return true
        }
    }

    public struct SlideStep: Sendable {
        public let element: AXElement
        public let windowID: CGWindowID
        public let origin: CGPoint

        public init(element: AXElement, windowID: CGWindowID, origin: CGPoint) {
            self.element = element
            self.windowID = windowID
            self.origin = origin
        }
    }

    /// Writes intermediate slide positions; the final mutation does logging and size bookkeeping.
    public func slide(_ steps: [SlideStep]) {
        for step in steps {
            // A resize the window has not started yet would stall this slide; the slide's own final resizes it.
            if let pending = pendingMutations[step.windowID], pending.isSlideFinal {
                pendingMutations[step.windowID] = pending.focusOnly
            }
            _ = step.element.setMessagingTimeout(Self.defaultTimeoutSeconds)
            step.element.position = step.origin
        }
    }

    /// The app's focused window when WindowServer shows it, else its first window on screen.
    /// An app redrawing for activation answers slowly, so callers run this off the main thread.
    public func frontWindow(onScreen: Set<CGWindowID>?) -> (element: AXElement, windowID: CGWindowID)? {
        let app = AXElement.application(pid: pid)
        _ = app.setMessagingTimeout(Self.defaultTimeoutSeconds)
        if let focused = app.focusedWindow, let id = focused.windowID, onScreen?.contains(id) ?? true {
            return (focused, id)
        }
        for win in app.windows {
            if let id = win.windowID, onScreen?.contains(id) ?? false { return (win, id) }
        }
        return nil
    }

    private var pendingMutations: [CGWindowID: WindowMutation] = [:]
    private var lastAppliedSizes: [CGWindowID: CGSize] = [:]
    private var isDraining: Bool = false
    /// Called with a window's live width and height, each only when the window stays larger than
    /// a resize asked for in that dimension.
    private let onMinSize: ((CGWindowID, Double?, Double?) -> Void)?
    private let onWriteFailed: ((CGWindowID, CGRect, AXError) -> Void)?

    public init(
        pid: pid_t,
        onMinSize: ((CGWindowID, Double?, Double?) -> Void)? = nil,
        onWriteFailed: ((CGWindowID, CGRect, AXError) -> Void)? = nil
    ) {
        self.pid = pid
        self.onMinSize = onMinSize
        self.onWriteFailed = onWriteFailed
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
                    isSlideFinal: mutation.needsMove ? mutation.isSlideFinal : existing.isSlideFinal,
                    quiet: mutation.needsMove ? (mutation.quiet && existing.quiet) : existing.quiet
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
            // A slide can carry a window near another display, where macOS moves and shrinks it.
            let currentKnownSize = mutation.needsFullFrame || mutation.isSlideFinal
                ? mutation.element.size
                : (lastAppliedSizes[winID] ?? mutation.element.size)
            let sizeChanged: Bool = {
                guard let cur = currentKnownSize else { return mutation.needsFullFrame }
                return abs(cur.width - mutation.frame.size.width) >= 1.5 ||
                       abs(cur.height - mutation.frame.size.height) >= 1.5
            }()

            let writeError: AXError
            if sizeChanged {
                // Window size genuinely changed: AX resize required so target app reflows views.
                writeError = mutation.element.setFrame(mutation.frame)
                if writeError == .success {
                    if !mutation.quiet {
                        RibbonLog.log(
                            "AX frame applied wid=\(winID) pid=\(pid) target=\(mutation.frame.integral)",
                            category: "layout"
                        )
                    }
                    // Apps hold windows at their minimum size; the layout makes room once it knows it.
                    // Terminals round widths to a character cell, so a width counts as a minimum
                    // only past 16pt over the request.
                    if let live = mutation.element.size {
                        let minWidth = live.width >= mutation.frame.width + 16 ? Double(live.width) : nil
                        let minHeight = live.height >= mutation.frame.height + 2 ? Double(live.height) : nil
                        if minWidth != nil || minHeight != nil { onMinSize?(winID, minWidth, minHeight) }
                    }
                }
            } else {
                // Pure translation: single AX position write with zero resize roundtrips.
                writeError = mutation.element.setPosition(mutation.frame.origin)
                if writeError == .success, !mutation.quiet {
                    RibbonLog.log(
                        "AX position applied wid=\(winID) pid=\(pid) target=\(mutation.frame.origin)",
                        category: "layout"
                    )
                }
            }

            if writeError == .success {
                lastAppliedSizes[winID] = mutation.frame.size
            } else {
                RibbonLog.log(
                    "AX write failed wid=\(winID) pid=\(pid) err=\(writeError.rawValue)",
                    category: "layout"
                )
                onWriteFailed?(winID, mutation.frame, writeError)
            }
            // Each resize blocks this app for tens of ms; yielding lets a new slide's steps run
            // between them and drop finals it replaces.
            await Task.yield()
        }

        if let target = focusTarget {
            if Self.latestFocus.withLock({ $0 == nil || $0?.id == target.windowID }) {
                _ = target.element.setMessagingTimeout(Self.defaultTimeoutSeconds)
                NSRunningApplication(processIdentifier: pid)?.activate()
                target.element.focus()
            } else {
                RibbonLog.log("focus skipped wid=\(target.windowID) pid=\(pid): a newer focus replaced it", category: "focus")
            }
        }

        if wasEnhanced && NSWorkspace.shared.isVoiceOverEnabled {
            appElem.enhancedUserInterface = true
        }
    }
}
