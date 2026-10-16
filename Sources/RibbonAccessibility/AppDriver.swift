import Foundation
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

        public init(
            element: AXElement,
            windowID: CGWindowID,
            frame: CGRect,
            needsFullFrame: Bool
        ) {
            self.element = element
            self.windowID = windowID
            self.frame = frame
            self.needsFullFrame = needsFullFrame
        }
    }

    private var pendingMutations: [CGWindowID: WindowMutation] = [:]
    private var lastAppliedSizes: [CGWindowID: CGSize] = [:]
    private var pendingAXSyncPositions: [CGWindowID: (element: AXElement, position: CGPoint)] = [:]
    private var axSyncTask: Task<Void, Never>?
    private var isDraining: Bool = false

    public init(pid: pid_t) {
        self.pid = pid
    }

    /// Enqueues window mutations for this application process.
    /// New mutations for the same window overwrite pending ones to coalesce rapid retiles.
    public func enqueue(_ mutations: [WindowMutation]) {
        for mutation in mutations {
            pendingMutations[mutation.windowID] = mutation
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
            // VoiceOver animates window bounds when AXEnhancedUserInterface is active,
            // causing visible frame stutter during batch programmatic positioning.
            if wasEnhanced {
                appElem.enhancedUserInterface = false
            }

            for (winID, mutation) in batch {
                _ = mutation.element.setMessagingTimeout(Self.defaultTimeoutSeconds)

                if mutation.needsFullFrame || lastAppliedSizes[winID] != mutation.frame.size {
                    // Window size changed: AX resizing is required so the target app reflows views.
                    mutation.element.setFrame(mutation.frame)
                    lastAppliedSizes[winID] = mutation.frame.size
                    pendingAXSyncPositions.removeValue(forKey: winID)
                    RibbonLog.log(
                        "AX frame applied wid=\(winID) pid=\(pid) target=\(mutation.frame.integral)",
                        category: "layout"
                    )
                } else {
                    // Fast path: Pure translation moves surface directly in WindowServer GPU memory.
                    let movedViaSkyLight = SkyLightBridge.shared.moveWindow(id: winID, to: mutation.frame.origin)
                    if movedViaSkyLight {
                        pendingAXSyncPositions[winID] = (element: mutation.element, position: mutation.frame.origin)
                        RibbonLog.log(
                            "SkyLight moved wid=\(winID) pid=\(pid) target=\(mutation.frame.origin)",
                            category: "layout"
                        )
                    } else {
                        mutation.element.position = mutation.frame.origin
                        RibbonLog.log(
                            "AX fallback position applied wid=\(winID) pid=\(pid) target=\(mutation.frame.origin)",
                            category: "layout"
                        )
                    }
                }
            }

            if wasEnhanced {
                appElem.enhancedUserInterface = true
            }
        }
        isDraining = false

        if !pendingAXSyncPositions.isEmpty {
            axSyncTask?.cancel()
            axSyncTask = Task { [weak self] in
                // Debounce 120ms after gesture or scrolling activity ceases.
                // Syncs the target application's internal frame cache so context menus and tooltips align.
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                await self?.flushPendingAXSync()
            }
        }
    }

    private func flushPendingAXSync() {
        guard !pendingAXSyncPositions.isEmpty else { return }
        let toSync = pendingAXSyncPositions
        pendingAXSyncPositions.removeAll()
        for (winID, item) in toSync {
            _ = item.element.setMessagingTimeout(Self.defaultTimeoutSeconds)
            // Skip write if the element's cached position matches, avoiding redundant windowDidMove: flashes
            if let curPos = item.element.position {
                if abs(curPos.x - item.position.x) < 1.0 && abs(curPos.y - item.position.y) < 1.0 {
                    continue
                }
            }
            item.element.position = item.position
            RibbonLog.log(
                "AX debounced position synced wid=\(winID) pid=\(pid) pos=\(item.position)",
                category: "ax-sync"
            )
        }
    }
}
