import Foundation
import CoreGraphics

public struct WindowPlacement: Sendable {
    public let windowID: CGWindowID
    public let frame: CGRect
    public let quartzFrame: QuartzRect
    public let isStashed: Bool
    /// Where the window sits on the strip before stashing; equals `frame` when not stashed.
    /// Slides interpolate along this so off-screen windows move with their neighbors.
    public let naturalFrame: CGRect

    public init(windowID: CGWindowID, quartzFrame: QuartzRect, isStashed: Bool, naturalFrame: CGRect? = nil) {
        self.windowID = windowID
        self.quartzFrame = quartzFrame
        self.frame = quartzFrame.cgRect
        self.isStashed = isStashed
        self.naturalFrame = naturalFrame ?? quartzFrame.cgRect
    }

    public init(windowID: CGWindowID, frame: CGRect, isStashed: Bool, naturalFrame: CGRect? = nil) {
        self.windowID = windowID
        self.quartzFrame = QuartzRect(frame)
        self.frame = frame
        self.isStashed = isStashed
        self.naturalFrame = naturalFrame ?? frame
    }
}

public struct TilingPlan: Sendable {
    public var placements: [WindowPlacement]

    public init(placements: [WindowPlacement] = []) {
        self.placements = placements
    }
}

public struct LayoutEngine: Sendable {
    public init() {}

    public static func columnGeometry(
        for ribbon: Ribbon,
        canvasWidth: Double,
        config: Config
    ) -> [(x: Double, width: Double)] {
        guard !ribbon.columns.isEmpty else { return [] }
        var result: [(x: Double, width: Double)] = []
        result.reserveCapacity(ribbon.columns.count)

        if ribbon.isOverview {
            let count = ribbon.columns.count
            let totalGaps = Double(max(0, count - 1)) * config.windowGap
            let availableWidth = max(Double(count) * 40.0, canvasWidth - totalGaps)
            let colWidth = floor(availableWidth / Double(count))
            var currentX = 0.0
            for _ in ribbon.columns {
                result.append((x: currentX, width: colWidth))
                currentX += colWidth + config.windowGap
            }
            return result
        }

        if ribbon.columns.count == 1 {
            let col = ribbon.columns[0]
            let effectiveRatio = col.hasExplicitSingleWidth ? col.widthRatio : 1.0
            let width = (effectiveRatio >= 0.999) ? canvasWidth : floor(min(canvasWidth, effectiveRatio * canvasWidth))
            return [(x: 0.0, width: width)]
        }

        var currentX = 0.0
        for col in ribbon.columns {
            let width: Double
            if col.widthRatio >= 0.999 {
                width = canvasWidth
            } else {
                let rawWidth = col.widthRatio * (canvasWidth + config.windowGap) - config.windowGap
                width = floor(max(50.0, min(canvasWidth, rawWidth)))
            }
            result.append((x: currentX, width: width))
            currentX += width + config.windowGap
        }
        return result
    }

    public static func minimalScrollOffset(
        for ribbon: Ribbon,
        canvasWidth: Double,
        config: Config
    ) -> Double {
        if ribbon.isOverview {
            return 0.0
        }
        guard !ribbon.columns.isEmpty else { return 0.0 }
        let geometry = columnGeometry(for: ribbon, canvasWidth: canvasWidth, config: config)
        guard !geometry.isEmpty else { return 0.0 }

        var offset = ribbon.viewportOffset
        let activeIdx = max(0, min(ribbon.activeColumnIndex, geometry.count - 1))
        let a = geometry[activeIdx]

        if a.width >= canvasWidth {
            offset = a.x
        } else if a.x < offset {
            offset = a.x
        } else if a.x + a.width > offset + canvasWidth {
            offset = a.x + a.width - canvasWidth
        }

        let last = geometry[geometry.count - 1]
        let totalStripWidth = last.x + last.width
        return floor(max(0.0, min(offset, max(0.0, totalStripWidth - canvasWidth))))
    }

    public static func computePlan(
        for ribbon: Ribbon,
        screenFrame: CGRect,
        config: Config,
        allowLeftBleed: Bool = true,
        allowRightBleed: Bool = true
    ) -> TilingPlan {
        return computePlan(
            for: ribbon,
            screenFrame: QuartzRect(screenFrame),
            config: config,
            allowLeftBleed: allowLeftBleed,
            allowRightBleed: allowRightBleed
        )
    }

    /// Computes the tiling geometry and stashed window placements for a ribbon in Quartz space.
    /// - Parameters:
    ///   - ribbon: The ribbon being tiled.
    ///   - screenFrame: The display's visible bounding rectangle in top-left Quartz coordinates.
    ///   - config: Layout configuration (margins, inner gaps, sliver sizing).
    ///   - allowLeftBleed: True if stashed windows may park past the left edge (when no monitor is to the left).
    ///   - allowRightBleed: True if stashed windows may park past the right edge (when no monitor is to the right).
    public static func computePlan(
        for ribbon: Ribbon,
        screenFrame: QuartzRect,
        config: Config,
        targetDisplay: DisplayBounds? = nil,
        allDisplays: [DisplayBounds] = [],
        allowLeftBleed: Bool = true,
        allowRightBleed: Bool = true
    ) -> TilingPlan {
        guard !ribbon.columns.isEmpty else { return TilingPlan() }

        let canvasX = floor(screenFrame.minX + config.edgeMargin)
        let canvasY = floor(screenFrame.minY + config.edgeMargin)
        let canvasW = floor(screenFrame.width - (config.edgeMargin * 2))
        let canvasH = floor(screenFrame.height - (config.edgeMargin * 2))

        let geometry = columnGeometry(for: ribbon, canvasWidth: canvasW, config: config)
        var placements: [WindowPlacement] = []
        let canvasRight = canvasX + canvasW

        for (index, col) in ribbon.columns.enumerated() {
            let geo = geometry[index]
            let colX = floor(canvasX + geo.x - ribbon.viewportOffset)
            let colW = geo.width

            let leftEdge = colX
            let rightEdge = colX + colW

            let isStashed: Bool
            let wing: StripWing
            if rightEdge <= canvasX {
                isStashed = true
                wing = .left
            } else if leftEdge >= canvasRight {
                isStashed = true
                wing = .right
            } else {
                isStashed = false
                wing = (colX + colW / 2.0 < canvasX + canvasW / 2.0) ? .left : .right
            }

            placements.append(contentsOf: layoutColumn(
                column: col,
                x: colX,
                width: colW,
                canvasY: canvasY,
                canvasH: canvasH,
                gap: config.windowGap,
                isStashed: isStashed,
                wing: wing,
                screenFrame: screenFrame,
                targetDisplay: targetDisplay,
                allDisplays: allDisplays,
                config: config
            ))
        }

        return TilingPlan(placements: placements)
    }

    private static func layoutColumn(
        column: ColumnModel,
        x: Double,
        width: Double,
        canvasY: Double,
        canvasH: Double,
        gap: Double,
        isStashed: Bool,
        wing: StripWing,
        screenFrame: QuartzRect,
        targetDisplay: DisplayBounds?,
        allDisplays: [DisplayBounds],
        config: Config
    ) -> [WindowPlacement] {
        var results: [WindowPlacement] = []
        let count = column.windows.count
        guard count > 0 else { return results }

        func makePlacement(winID: CGWindowID, tiledFrame: QuartzRect) -> WindowPlacement {
            if !isStashed {
                return WindowPlacement(windowID: winID, quartzFrame: tiledFrame, isStashed: false)
            } else {
                let origin: QuartzPoint
                if let target = targetDisplay {
                    origin = FreeEdgeStashEngine.parkedOrigin(
                        windowSize: tiledFrame.size,
                        tiledY: tiledFrame.y,
                        wing: wing,
                        targetDisplay: target,
                        allDisplays: allDisplays
                    )
                } else {
                    if wing == .left {
                        origin = QuartzPoint(x: screenFrame.minX - tiledFrame.width + FreeEdgeStashEngine.sliverAnchorSize, y: tiledFrame.y)
                    } else {
                        origin = QuartzPoint(x: screenFrame.maxX - FreeEdgeStashEngine.sliverAnchorSize, y: tiledFrame.y)
                    }
                }
                let stashedFrame = QuartzRect(origin: origin, size: tiledFrame.size)
                return WindowPlacement(windowID: winID, quartzFrame: stashedFrame, isStashed: true, naturalFrame: tiledFrame.cgRect)
            }
        }

        if count == 1 {
            let frame = QuartzRect(x: x, y: canvasY, width: width, height: canvasH)
            results.append(makePlacement(winID: column.windows[0].id, tiledFrame: frame))
        } else {
            // Distribute height evenly among stacked windows with inner gap.
            // Scale inner gap down if necessary so windows never overflow canvas bottom.
            let minWindowHeight = 30.0
            let maxGaps = max(0.0, canvasH - (Double(count) * minWindowHeight))
            let effectiveGap = count > 1 ? min(gap, maxGaps / Double(count - 1)) : 0.0
            let totalGaps = Double(count - 1) * effectiveGap
            let windowH = floor(max(minWindowHeight, (canvasH - totalGaps) / Double(count)))
            var currentY = canvasY
            let bottomLimit = canvasY + canvasH

            for (idx, win) in column.windows.enumerated() {
                let available = max(minWindowHeight, bottomLimit - currentY)
                let h = (idx == count - 1) ? available : min(windowH, available)
                let frame = QuartzRect(x: x, y: currentY, width: width, height: floor(h))
                results.append(makePlacement(winID: win.id, tiledFrame: frame))
                currentY += windowH + effectiveGap
            }
        }

        return results
    }
}
