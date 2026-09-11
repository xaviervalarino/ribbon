import Foundation
import AppKit
import ApplicationServices
import RibbonCore
import RibbonAccessibility

public final class WindowManager: AXEventObserverDelegate {
    public var ribbon = Ribbon()
    public var config = Config.default
    private let observer = AXEventObserver()
    private let socketServer = SocketServer()
    private var trackedWindows: [Int: AXElement] = [:]

    public init() {
        observer.delegate = self
    }

    public func start() {
        print("[ribbon-daemon] Starting WindowManager...")

        // Scan existing windows
        discoverExistingWindows()

        // Start event observer
        observer.start()

        // Start IPC Socket Server
        socketServer.onCommand = { [weak self] cmd in
            return self?.handleCommand(cmd) ?? "error: daemon unavailable"
        }
        do {
            try socketServer.start()
            print("[ribbon-daemon] IPC Socket listening on \(socketServer.socketPath)")
        } catch {
            print("[ribbon-daemon] Failed to start socket server: \(error)")
        }

        retile()
    }

    public func stop() {
        observer.stop()
        socketServer.stop()
    }

    // MARK: - Window Discovery

    private func discoverExistingWindows() {
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let appName = app.localizedName,
                  !config.ignoredApps.contains(appName) else { continue }

            let appElem = AXElement.application(pid: app.processIdentifier)
            for win in appElem.windows {
                guard win.role == (kAXWindowRole as String),
                      win.subrole == (kAXStandardWindowSubrole as String) else { continue }

                let id = Int(app.processIdentifier) ^ win.title.hashValue
                trackedWindows[id] = win
                let model = WindowModel(id: id, pid: app.processIdentifier, title: win.title, appName: appName)
                ribbon.addWindow(model, config: config)
            }
        }
    }

    // MARK: - Layout & Retile

    public func retile() {
        guard let screen = NSScreen.main else { return }
        // NSScreen coordinates have Y origin at bottom-left; WindowServer has Y origin at top-left
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cocoaFrame = screen.visibleFrame
        let windowServerFrame = CGRect(
            x: cocoaFrame.minX,
            y: primaryScreenHeight - cocoaFrame.maxY,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )

        let plan = LayoutEngine.computePlan(for: ribbon, screenFrame: windowServerFrame, config: config)

        for placement in plan.placements {
            guard let elem = trackedWindows[placement.windowID] else { continue }
            if placement.isHidden {
                elem.isHidden = true
            } else {
                elem.isHidden = false
                elem.setFrame(placement.frame)
            }
        }

        // Focus the active window
        if let active = ribbon.activeWindow, let elem = trackedWindows[active.id] {
            elem.focus()
        }
    }

    // MARK: - IPC Command Handling

    public func handleCommand(_ command: String) -> String {
        let parts = command.split(separator: " ").map(String.init)
        guard let action = parts.first?.lowercased() else { return "error: empty command" }

        switch action {
        case "focus":
            let dir = parts.dropFirst().first?.lowercased() ?? "right"
            switch dir {
            case "left", "h": ribbon.focusLeft()
            case "right", "l": ribbon.focusRight()
            case "up", "k": ribbon.focusUp()
            case "down", "j": ribbon.focusDown()
            default: return "error: unknown focus direction"
            }
        case "swap":
            let dir = parts.dropFirst().first?.lowercased() ?? "right"
            switch dir {
            case "left", "h": ribbon.swapLeft()
            case "right", "l": ribbon.swapRight()
            default: return "error: unknown swap direction"
            }
        case "cycle-width", "cycle":
            ribbon.cycleWidth(ratios: config.widthCycleRatios)
        case "slurp":
            ribbon.slurp()
        case "barf":
            ribbon.barf()
        case "status":
            return "columns: \(ribbon.columns.count), active: \(ribbon.activeColumnIndex)"
        default:
            return "error: unknown command '\(command)'"
        }

        retile()
        return "ok"
    }

    // MARK: - AXEventObserverDelegate

    public func windowCreated(element: AXElement, pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let appName = app.localizedName,
              !config.ignoredApps.contains(appName) else { return }

        let id = Int(pid) ^ element.title.hashValue
        trackedWindows[id] = element
        let model = WindowModel(id: id, pid: pid, title: element.title, appName: appName)
        ribbon.addWindow(model, config: config)
        retile()
    }

    public func windowDestroyed(element: AXElement, pid: pid_t) {
        let id = Int(pid) ^ element.title.hashValue
        trackedWindows.removeValue(forKey: id)
        ribbon.removeWindow(id: id)
        retile()
    }

    public func windowFocused(element: AXElement, pid: pid_t) {
        let id = Int(pid) ^ element.title.hashValue
        // Update active column if focused window is tracked
        for (cIdx, col) in ribbon.columns.enumerated() {
            if let rIdx = col.windows.firstIndex(where: { $0.id == id }) {
                if ribbon.activeColumnIndex != cIdx || col.activeRowIndex != rIdx {
                    ribbon.activeColumnIndex = cIdx
                    var updatedCol = col
                    updatedCol.activeRowIndex = rIdx
                    ribbon.columns[cIdx] = updatedCol
                    retile()
                }
                break
            }
        }
    }
}
