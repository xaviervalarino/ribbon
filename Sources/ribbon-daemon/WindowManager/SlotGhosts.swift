import AppKit
import ScreenCaptureKit

/// Blocks drawn where a window belongs while its app is too slow to show it there, so a slide
/// never leaves an empty slot. A block shows an image of its window, captured when the ghost first
/// shows, once Screen Recording is granted; until then it is a plain fill. The panels sit one level below normal windows, so they show
/// only through gaps; window discovery admits layer 0 only, so they are never tiled.
///
/// Confined to the main queue.
final class SlotGhosts {
    private var panels: [CGWindowID: NSPanel] = [:]
    private var spare: [NSPanel] = []
    private var snapshots: [CGWindowID: CGImage] = [:]
    private var capturing: Set<CGWindowID> = []

    /// Shows or moves the ghost for `id` at `frame`, the part of the window's whole strip frame
    /// `window` (`frame` when nil) to show, both in Quartz coordinates (top-left origin).
    func show(_ id: CGWindowID, frame: CGRect, window: CGRect? = nil) {
        let isNew = panels[id] == nil
        let panel = panels[id] ?? spare.popLast() ?? Self.makePanel()
        panels[id] = panel
        panel.alphaValue = 1
        panel.setFrame(Self.cocoaRect(frame), display: false)
        let window = window ?? frame
        if let layer = panel.contentView?.layer, window.width > 0 {
            layer.contents = snapshots[id]
            layer.contentsRect = CGRect(x: (frame.minX - window.minX) / window.width, y: 0,
                                        width: frame.width / window.width, height: 1)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if isNew { capture(id) }
    }

    /// Shows exactly `frames`, fading out every other ghost; `windows` holds each window's whole frame.
    func sync(_ frames: [CGWindowID: CGRect], windows: [CGWindowID: CGRect]) {
        hide(panels.keys.filter { frames[$0] == nil })
        for (id, frame) in frames { show(id, frame: frame, window: windows[id]) }
    }

    /// Fades the ghosts of `ids` out. A fading panel is reused only after its fade completes.
    func hide(_ ids: [CGWindowID]) {
        let fading = ids.compactMap { panels.removeValue(forKey: $0) }
        guard !fading.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            for panel in fading { panel.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            for panel in fading { panel.orderOut(nil) }
            spare.append(contentsOf: fading)
            for id in ids where panels[id] == nil { snapshots[id] = nil }
        })
    }

    /// Captures `id`'s window into its ghost. Fails, leaving the plain fill, until Screen Recording
    /// is granted to Ribbon.
    private func capture(_ id: CGWindowID) {
        guard #available(macOS 14, *), capturing.insert(id).inserted else { return }
        let started = DispatchTime.now()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            guard let window = content?.windows.first(where: { $0.windowID == id }) else {
                return self.captured(id, nil, started, error)
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
            config.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                self.captured(id, image, started, error)
            }
        }
    }

    private func captured(_ id: CGWindowID, _ image: CGImage?, _ started: DispatchTime, _ error: Error?) {
        DispatchQueue.main.async {
            self.capturing.remove(id)
            let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            RibbonLog.log("ghost capture wid=\(id) \(image == nil ? "failed \(error.map { "\($0)" } ?? "no window")" : "ok") \(ms)ms",
                          category: "slide")
            guard let image, let panel = self.panels[id] else { return }
            self.snapshots[id] = image
            panel.contentView?.layer?.contents = image
        }
    }

    private static func cocoaRect(_ quartz: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: quartz.minX, y: primaryHeight - quartz.maxY, width: quartz.width, height: quartz.height)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let block = NSView()
        block.wantsLayer = true
        block.layer?.backgroundColor = NSColor(white: 0, alpha: 0.95).cgColor
        block.layer?.borderColor = NSColor(white: 1, alpha: 0.45).cgColor
        block.layer?.borderWidth = 1
        block.layer?.cornerRadius = 10
        block.layer?.masksToBounds = true
        block.layer?.contentsGravity = .resize
        panel.contentView = block
        return panel
    }
}
