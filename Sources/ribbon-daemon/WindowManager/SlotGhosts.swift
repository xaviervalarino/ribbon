import AppKit
import ScreenCaptureKit

/// Blocks drawn where a window belongs while its app is too slow to show it there, so a slide
/// never leaves an empty slot. A block shows an image of its window, captured when the ghost first
/// shows; a block with no image yet stays hidden until its capture lands, and fades in as a plain
/// fill when the capture fails (Screen Recording not granted). A block cut at a display
/// edge runs past it, so it reads as the window overflowing. The panels sit one level below normal
/// windows, so they show only through gaps; window discovery admits layer 0 only, so they are never
/// tiled.
///
/// Confined to the main queue.
final class SlotGhosts {
    private var panels: [CGWindowID: NSPanel] = [:]
    private var spare: [NSPanel] = []
    private var capturing: Set<CGWindowID> = []
    /// Ghosts kept invisible until their first capture lands or fails.
    private var awaitingImage: Set<CGWindowID> = []

    /// Window images shared by every `SlotGhosts`, so a window handed between the slide ghosts and
    /// the seam ghosts keeps its image instead of showing the plain fill while it is captured again.
    private static var snapshots: [CGWindowID: CGImage] = [:]
    /// Ghosts showing each window, across every `SlotGhosts`. `snapshotGrace` after a window's
    /// last ghost hides, its image shrinks to a quarter-size copy (a full-size capture runs to tens
    /// of MB), kept until `forget` so its next ghost never starts empty.
    private static var users: [CGWindowID: Int] = [:]
    /// Counts each window's last-ghost releases, so only the newest grace timer shrinks its image.
    private static var releases: [CGWindowID: Int] = [:]
    /// Windows whose image is the shrunken copy, which never shrinks again.
    private static var shrunk: Set<CGWindowID> = []
    /// Windows waiting for `warm`'s next batch.
    private static var toWarm: Set<CGWindowID> = []
    private static let snapshotGrace: DispatchTimeInterval = .seconds(3)
    /// How far a block runs past an edge where its window continues, so the panel clips the
    /// block's corners and border there; above the block's 10pt corner radius.
    private static let overflow: CGFloat = 12

    /// Shows or moves the ghost for `id` at `frame`, the part of the window's whole strip frame
    /// `window` (`frame` when nil) to show, both in Quartz coordinates (top-left origin).
    func show(_ id: CGWindowID, frame: CGRect, window: CGRect? = nil) {
        let isNew = panels[id] == nil
        let panel = panels[id] ?? spare.popLast() ?? Self.makePanel()
        panels[id] = panel
        if isNew {
            Self.users[id, default: 0] += 1
            if Self.snapshots[id] == nil { awaitingImage.insert(id) }
            // A cached image shows at once; a fresh capture replaces it.
            capture(id)
        }
        panel.alphaValue = awaitingImage.contains(id) ? 0 : 1
        panel.setFrame(Self.cocoaRect(frame), display: false)
        let window = window ?? frame
        if let block = Self.block(of: panel), window.width > 0, window.height > 0 {
            // Each side where the window continues past `frame` overflows the panel.
            let reach = { (beyond: CGFloat) in max(0, min(Self.overflow, beyond)) }
            let left = reach(frame.minX - window.minX)
            let right = reach(window.maxX - frame.maxX)
            let top = reach(frame.minY - window.minY)
            let bottom = reach(window.maxY - frame.maxY)
            let shown = CGRect(x: frame.minX - left, y: frame.minY - top,
                               width: frame.width + left + right, height: frame.height + top + bottom)
            // Cocoa view coordinates: y grows upward, so the bottom overflow sits below zero.
            block.frame = CGRect(x: -left, y: -bottom, width: shown.width, height: shown.height)
            block.layer?.contents = Self.snapshots[id]
            block.layer?.contentsRect = CGRect(x: (shown.minX - window.minX) / window.width,
                                               y: (window.maxY - shown.maxY) / window.height,
                                               width: shown.width / window.width,
                                               height: shown.height / window.height)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Shows exactly `frames`, fading out every other ghost; `windows` holds each window's whole frame.
    func sync(_ frames: [CGWindowID: CGRect], windows: [CGWindowID: CGRect]) {
        hide(panels.keys.filter { frames[$0] == nil })
        for (id, frame) in frames { show(id, frame: frame, window: windows[id]) }
    }

    /// Fades the ghosts of `ids` out. A fading panel is reused only after its fade completes.
    func hide(_ ids: [CGWindowID]) {
        var fading: [NSPanel] = []
        for id in ids {
            guard let panel = panels.removeValue(forKey: id) else { continue }
            awaitingImage.remove(id)
            Self.release(id)
            fading.append(panel)
        }
        guard !fading.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            for panel in fading { panel.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            for panel in fading {
                panel.orderOut(nil)
                // A spare panel holding its image would keep it alive past the grace.
                Self.block(of: panel)?.layer?.contents = nil
            }
            spare.append(contentsOf: fading)
        })
    }

    private static func release(_ id: CGWindowID) {
        users[id, default: 1] -= 1
        guard users[id] == 0 else { return }
        users[id] = nil
        let release = releases[id, default: 0] + 1
        releases[id] = release
        DispatchQueue.main.asyncAfter(deadline: .now() + snapshotGrace) {
            guard users[id] == nil, releases[id] == release else { return }
            releases[id] = nil
            guard let image = snapshots[id], !shrunk.contains(id) else { return }
            DispatchQueue.global(qos: .utility).async {
                let small = quarterSize(image)
                DispatchQueue.main.async {
                    // A capture that landed meanwhile is newer.
                    guard snapshots[id] === image else { return }
                    snapshots[id] = small
                    shrunk.insert(id)
                }
            }
        }
    }

    /// Captures `id` at quarter size within a second, unless it already has an image, so its first
    /// ghost never starts empty. Calls inside that second share one capture batch.
    static func warm(_ id: CGWindowID) {
        let isFirst = toWarm.isEmpty
        toWarm.insert(id)
        guard isFirst else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let ids = toWarm.filter { snapshots[$0] == nil }
            toWarm = []
            guard #available(macOS 14, *), !ids.isEmpty else { return }
            RibbonLog.log("ghost warm \(ids.count) windows", category: "slide")
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
                for window in content?.windows ?? [] where ids.contains(window.windowID) {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = screenshotConfig(window, filter)
                    config.width = max(1, config.width / 4)
                    config.height = max(1, config.height / 4)
                    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                        guard let image else { return }
                        DispatchQueue.main.async {
                            // A ghost's own capture is sharper.
                            guard snapshots[window.windowID] == nil else { return }
                            snapshots[window.windowID] = image
                            shrunk.insert(window.windowID)
                        }
                    }
                }
            }
        }
    }

    /// Drops `id`'s image; call once its window is gone.
    static func forget(_ id: CGWindowID) {
        snapshots[id] = nil
        releases[id] = nil
        shrunk.remove(id)
    }

    private static func quarterSize(_ image: CGImage) -> CGImage? {
        let width = max(1, image.width / 4)
        let height = max(1, image.height / 4)
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
            let config = Self.screenshotConfig(window, filter)
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                self.captured(id, image, started, error)
            }
        }
    }

    /// A full-pixel-size, cursorless, shadowless screenshot of `window`.
    @available(macOS 14, *)
    private static func screenshotConfig(_ window: SCWindow, _ filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
        config.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return config
    }

    private func captured(_ id: CGWindowID, _ image: CGImage?, _ started: DispatchTime, _ error: Error?) {
        DispatchQueue.main.async {
            self.capturing.remove(id)
            let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            RibbonLog.log("ghost capture wid=\(id) \(image == nil ? "failed \(error.map { "\($0)" } ?? "no window")" : "ok") \(ms)ms",
                          category: "slide")
            if let image, Self.users[id] != nil {
                Self.snapshots[id] = image
                Self.shrunk.remove(id)
            }
            guard let panel = self.panels[id] else { return }
            if let image { Self.block(of: panel)?.layer?.contents = image }
            // The first capture fades its image in; a failed one (no Screen Recording grant), the plain fill.
            if self.awaitingImage.remove(id) != nil {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    panel.animator().alphaValue = 1
                }
            }
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
        let container = NSView()
        container.wantsLayer = true
        let block = NSView()
        block.wantsLayer = true
        block.layer?.backgroundColor = NSColor(white: 0, alpha: 0.95).cgColor
        block.layer?.borderColor = NSColor(white: 1, alpha: 0.45).cgColor
        block.layer?.borderWidth = 1
        block.layer?.cornerRadius = 10
        block.layer?.masksToBounds = true
        block.layer?.contentsGravity = .resize
        container.addSubview(block)
        panel.contentView = container
        return panel
    }

    private static func block(of panel: NSPanel) -> NSView? {
        panel.contentView?.subviews.first
    }
}
