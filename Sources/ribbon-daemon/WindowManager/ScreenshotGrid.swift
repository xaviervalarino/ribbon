import AppKit
import ImageIO
import ScreenCaptureKit

/// An overlay over one display showing a capture of every window of a ribbon, packed into rows.
/// The real windows never move: `moveSelection` walks the tiles, and the caller focuses
/// `selectedWindowID` when it closes the grid.
///
/// Captures need Screen Recording; until it is granted every thumbnail stays a placeholder block.
/// The last capture per window is kept, so the next open shows it at once while a fresh capture
/// replaces it.
///
/// Confined to the main queue.
final class ScreenshotGrid {
    struct Thumbnail {
        let id: CGWindowID
        /// The window's frame on screen now, in Quartz coordinates.
        let windowFrame: CGRect
        /// The thumbnail's frame in the grid, in Quartz coordinates, at the window's aspect ratio.
        let tile: CGRect
    }

    /// Separates tiles from each other and from the display's visible edges.
    static let tileGap = 24.0
    static let zoomSeconds = 0.2

    /// Runs on a click in the grid with the clicked thumbnail's window, or nil for the backdrop.
    var onClick: ((CGWindowID?) -> Void)?

    /// Runs with true when the grid opens and false when it closes, by any path. Reopening an
    /// open grid runs neither.
    var onOpenChange: ((Bool) -> Void)?

    /// The Space whose ribbon the grid shows; nil while closed.
    private(set) var spaceID: WindowManager.SpaceID?
    var isOpen: Bool { spaceID != nil }
    var selectedWindowID: CGWindowID? { thumbnails.indices.contains(selectedIndex) ? thumbnails[selectedIndex].id : nil }

    /// The shown thumbnails in strip order; the index into them carries the selection ring.
    private var thumbnails: [Thumbnail] = []
    private var selectedIndex = 0

    private let panel: NSPanel
    private let root: CALayer
    /// The display's wallpaper, aspect-filled over a dark fill that shows while it loads or when
    /// it cannot load.
    private let backdrop = CALayer()
    /// A light dim that keeps the thumbnails standing out without hiding the wallpaper.
    private let dim = CALayer()
    /// The last wallpaper loaded per display, with the URL it came from.
    private var wallpapers: [CGDirectDisplayID: (url: URL, image: CGImage)] = [:]
    /// The wallpaper the open grid shows; a load that lands for any other is only cached.
    private var shownWallpaper: (display: CGDirectDisplayID, url: URL)?
    private let ring = CALayer()
    private static let thumbnailCornerRadius: CGFloat = 6
    private static let ringWidth: CGFloat = 5
    /// The ring's outer edge sits this far outside the thumbnail, leaving a 3pt gap inside it.
    private static let ringOutset: CGFloat = ringWidth + 3
    private var layers: [CGWindowID: CALayer] = [:]
    /// Each thumbnail's window frame in panel coordinates: where it zooms in from and out to.
    private var homeFrames: [CGWindowID: CGRect] = [:]
    private var cache: [CGWindowID: CGImage] = [:]
    /// The panel's display in Quartz coordinates; layer frames are relative to it.
    private var displayFrame = CGRect.zero
    /// Bumped per open and close, so a zoom's completion never acts on a newer open or close.
    private var generation = 0

    init() {
        panel = Self.makePanel()
        root = panel.contentView!.layer!
        (panel.contentView as? GridView)?.onMouseDown = { [weak self] point in self?.clicked(at: point) }
        backdrop.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        backdrop.opacity = 0
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.masksToBounds = true
        dim.backgroundColor = NSColor(white: 0, alpha: 0.2).cgColor
        backdrop.addSublayer(dim)
        root.addSublayer(backdrop)
        ring.borderColor = NSColor.controlAccentColor.cgColor
        ring.borderWidth = Self.ringWidth
        // Concentric with the thumbnail's corner.
        ring.cornerRadius = Self.thumbnailCornerRadius + Self.ringOutset
    }

    /// Shows `thumbnails` on `screen`, whose Quartz frame is `displayFrame`, with `selectedID`
    /// ringed (the first thumbnail when absent), zooming each from its window's frame into its
    /// tile, and captures every window at its thumbnail's pixel size.
    func open(thumbnails: [Thumbnail], selectedID: CGWindowID?, spaceID: WindowManager.SpaceID,
              screen: NSScreen, displayFrame: CGRect) {
        let wasOpen = isOpen
        dismiss()
        self.thumbnails = thumbnails
        selectedIndex = thumbnails.firstIndex { $0.id == selectedID } ?? 0
        self.spaceID = spaceID
        if !wasOpen { onOpenChange?(true) }
        generation += 1
        let opening = generation
        self.displayFrame = displayFrame
        panel.setFrame(screen.frame, display: false)
        let shown = Set(thumbnails.map(\.id))
        cache = cache.filter { shown.contains($0.key) }

        var pixelSizes: [CGWindowID: CGSize] = [:]
        var gridFrames: [CGWindowID: CGRect] = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = CGRect(origin: .zero, size: screen.frame.size)
        dim.frame = backdrop.bounds
        showWallpaper(of: screen)
        for thumb in thumbnails {
            let layer = Self.makeThumbnailLayer()
            layer.frame = local(thumb.windowFrame)
            layer.contents = cache[thumb.id]
            root.addSublayer(layer)
            layers[thumb.id] = layer
            homeFrames[thumb.id] = layer.frame
            gridFrames[thumb.id] = local(thumb.tile)
            pixelSizes[thumb.id] = CGSize(width: thumb.tile.width * screen.backingScaleFactor,
                                          height: thumb.tile.height * screen.backingScaleFactor)
        }
        root.addSublayer(ring)
        ring.opacity = 0
        CATransaction.commit()
        panel.orderFrontRegardless()

        Self.animate {
            for (id, layer) in layers { layer.frame = gridFrames[id] ?? layer.frame }
            backdrop.opacity = 1
        } completion: { [weak self] in
            guard let self, self.generation == opening else { return }
            self.placeRing()
            Self.animate { self.ring.opacity = 1 }
        }
        capture(pixelSizes)
    }

    /// Moves the selection across the packed rows; false for an unknown direction.
    func moveSelection(_ direction: String) -> Bool {
        guard let next = LayoutEngine.packedGridStep(frames: thumbnails.map(\.tile), from: selectedIndex,
                                                     direction: direction) else { return false }
        selectedIndex = next
        placeRing()
        return true
    }

    /// Zooms every thumbnail back to its window's frame and hides the panel once they land.
    func close() {
        guard isOpen else { return }
        dismiss()
        onOpenChange?(false)
    }

    /// Closes as `close` does without running `onOpenChange`, for `open` to clear a shown grid.
    private func dismiss() {
        guard isOpen else { return }
        thumbnails = []
        spaceID = nil
        generation += 1
        let closing = generation
        let zooming = layers
        let homes = homeFrames
        layers.removeAll()
        homeFrames.removeAll()
        Self.animate {
            for (id, layer) in zooming { layer.frame = homes[id] ?? layer.frame }
            backdrop.opacity = 0
            ring.opacity = 0
        } completion: { [weak self] in
            for layer in zooming.values { layer.removeFromSuperlayer() }
            guard let self, self.generation == closing else { return }
            self.ring.removeFromSuperlayer()
            self.panel.orderOut(nil)
        }
    }

    /// Puts `screen`'s wallpaper on the backdrop: at once when cached for its current URL,
    /// otherwise once a background load lands.
    private func showWallpaper(of screen: NSScreen) {
        let display = screen.displayID
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            shownWallpaper = nil
            backdrop.contents = nil
            return
        }
        shownWallpaper = (display, url)
        if let cached = wallpapers[display], cached.url == url {
            backdrop.contents = cached.image
            return
        }
        backdrop.contents = nil
        let screenPixels = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                  height: screen.frame.height * screen.backingScaleFactor)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.loadImage(url, filling: screenPixels)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let image else {
                    RibbonLog.log("grid wallpaper failed to load \(url.path)", category: "grid")
                    return
                }
                self.wallpapers[display] = (url, image)
                if self.isOpen, self.shownWallpaper?.display == display, self.shownWallpaper?.url == url {
                    self.backdrop.contents = image
                }
            }
        }
    }

    /// Decodes `url` at the size that aspect-fills `screenPixels`, never above the image's own
    /// size, so a large wallpaper costs no more memory than the display shows and a wallpaper of
    /// another shape is not upscaled past its decoded size. An image without a pixel size
    /// decodes with its longest side at the screen's longest side.
    private static func loadImage(_ url: URL, filling screenPixels: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var maxPixelSize = max(screenPixels.width, screenPixels.height)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           var imageWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           var imageHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           imageWidth > 0, imageHeight > 0 {
            // EXIF orientations 5-8 turn the image a quarter, and the decode applies the turn.
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
                swap(&imageWidth, &imageHeight)
            }
            let longestSide = max(imageWidth, imageHeight)
            let fillScale = max(screenPixels.width / imageWidth, screenPixels.height / imageHeight)
            maxPixelSize = min(longestSide, (fillScale * longestSide).rounded(.up))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Reports the thumbnail under `point` (panel coordinates), or nil for the backdrop.
    private func clicked(at point: CGPoint) {
        guard isOpen else { return }
        onClick?(layers.first(where: { $0.value.frame.contains(point) })?.key)
    }

    /// Moves the ring onto the selected thumbnail without animating.
    private func placeRing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let id = selectedWindowID, let layer = layers[id] else {
            ring.isHidden = true
            return
        }
        ring.isHidden = false
        // A layer mid-zoom reports its target frame, which is where the ring belongs.
        ring.frame = layer.frame.insetBy(dx: -Self.ringOutset, dy: -Self.ringOutset)
    }

    private static func animate(_ changes: () -> Void, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(zoomSeconds)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock(completion)
        changes()
        CATransaction.commit()
    }

    /// One shared content fetch, then one capture per window at its requested pixel size.
    private func capture(_ pixelSizes: [CGWindowID: CGSize]) {
        guard #available(macOS 14, *), !pixelSizes.isEmpty else { return }
        let started = DispatchTime.now()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let content else {
                RibbonLog.log("grid content fetch failed \(error.map { "\($0)" } ?? "")", category: "grid")
                return
            }
            RibbonLog.log("grid content fetch \(Self.elapsedMs(since: started))ms", category: "grid")
            for (id, size) in pixelSizes {
                guard let window = content.windows.first(where: { $0.windowID == id }) else {
                    RibbonLog.log("grid capture wid=\(id) not in shareable content", category: "grid")
                    continue
                }
                let config = SCStreamConfiguration()
                config.width = Int(size.width)
                config.height = Int(size.height)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                 configuration: config) { image, error in
                    DispatchQueue.main.async { self?.captured(id, image, error, started) }
                }
            }
        }
    }

    private func captured(_ id: CGWindowID, _ image: CGImage?, _ error: Error?, _ started: DispatchTime) {
        RibbonLog.log("grid capture wid=\(id) \(image == nil ? "failed \(error.map { "\($0)" } ?? "")" : "ok") \(Self.elapsedMs(since: started))ms",
                      category: "grid")
        guard let image else { return }
        cache[id] = image
        layers[id]?.contents = image
    }

    private static func elapsedMs(since started: DispatchTime) -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
    }

    /// A Quartz rect as a layer frame in the panel, whose layer origin is its bottom-left corner.
    private func local(_ quartz: CGRect) -> CGRect {
        CGRect(x: quartz.minX - displayFrame.minX, y: displayFrame.maxY - quartz.maxY,
               width: quartz.width, height: quartz.height)
    }

    private static func makeThumbnailLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer.cornerRadius = thumbnailCornerRadius
        layer.masksToBounds = true
        layer.contentsGravity = .resizeAspect
        return layer
    }

    /// Window discovery admits layer 0 only, so the panel, above normal windows, is never tiled.
    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = GridView()
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }
}

/// Reports clicks in its own coordinates, which match the layer frames above.
private final class GridView: NSView {
    var onMouseDown: ((CGPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(convert(event.locationInWindow, from: nil))
    }
}
