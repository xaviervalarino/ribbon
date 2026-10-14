import Foundation
import CoreGraphics

public struct WindowPlacement: Sendable {
    public let windowID: CGWindowID
    public let frame: CGRect
    public let isStashed: Bool

    public init(windowID: CGWindowID, frame: CGRect, isStashed: Bool) {
        self.windowID = windowID
        self.frame = frame
        self.isStashed = isStashed
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
            let colWidth = availableWidth / Double(count)
            var currentX = 0.0
            for _ in ribbon.columns {
                result.append((x: currentX, width: colWidth))
                currentX += colWidth + config.windowGap
            }
            return result
        }

        var currentX = 0.0
        for col in ribbon.columns {
            let width = min(canvasWidth, col.widthRatio * canvasWidth)
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
        return max(0.0, min(offset, max(0.0, totalStripWidth - canvasWidth)))
    }

    public static func computePlan(
        for ribbon: Ribbon,
        screenFrame: CGRect,
        config: Config,
        allowLeftBleed: Bool = true,
        allowRightBleed: Bool = true
    ) -> TilingPlan {
        guard !ribbon.columns.isEmpty else { return TilingPlan() }

        let canvasX = screenFrame.minX + config.edgeMargin
        let canvasY = screenFrame.minY + config.edgeMargin
        let canvasW = screenFrame.width - (config.edgeMargin * 2)
        let canvasH = screenFrame.height - (config.edgeMargin * 2)

        let geometry = columnGeometry(for: ribbon, canvasWidth: canvasW, config: config)
        var placements: [WindowPlacement] = []
        let canvasRight = canvasX + canvasW

        for (index, col) in ribbon.columns.enumerated() {
            let geo = geometry[index]
            let colX = canvasX + geo.x - ribbon.viewportOffset
            let colW = geo.width

            let leftEdge = colX
            let rightEdge = colX + colW

            let isStashed: Bool
            if rightEdge <= canvasX || leftEdge >= canvasRight {
                isStashed = true
            } else if leftEdge < canvasX && !allowLeftBleed {
                isStashed = true
            } else if rightEdge > canvasRight && !allowRightBleed {
                isStashed = true
            } else {
                isStashed = false
            }

            placements.append(contentsOf: layoutColumn(
                column: col,
                x: colX,
                width: colW,
                canvasY: canvasY,
                canvasH: canvasH,
                gap: config.windowGap,
                isStashed: isStashed,
                screenFrame: screenFrame,
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
        screenFrame: CGRect,
        config: Config
    ) -> [WindowPlacement] {
        var results: [WindowPlacement] = []
        let count = column.windows.count
        guard count > 0 else { return results }

        let s = config.stashSliverSize

        func makePlacement(winID: CGWindowID, tiledFrame: CGRect) -> WindowPlacement {
            if !isStashed {
                return WindowPlacement(windowID: winID, frame: tiledFrame, isStashed: false)
            } else {
                let w = tiledFrame.width
                let h = tiledFrame.height
                let origin: CGPoint
                switch config.stashCorner {
                case .bottomRight:
                    origin = CGPoint(x: screenFrame.maxX - s, y: screenFrame.maxY - s)
                case .bottomLeft:
                    origin = CGPoint(x: screenFrame.minX - w + s, y: screenFrame.maxY - s)
                // WindowServer refuses to place a title bar above the screen
                // top, so top corners can only hide windows horizontally: the
                // sliver is a full-height vertical strip at the screen edge.
                case .topRight:
                    origin = CGPoint(x: screenFrame.maxX - s, y: screenFrame.minY)
                case .topLeft:
                    origin = CGPoint(x: screenFrame.minX - w + s, y: screenFrame.minY)
                }
                let stashedFrame = CGRect(origin: origin, size: CGSize(width: w, height: h))
                return WindowPlacement(windowID: winID, frame: stashedFrame, isStashed: true)
            }
        }

        if count == 1 {
            let frame = CGRect(x: x, y: canvasY, width: width, height: canvasH)
            results.append(makePlacement(winID: column.windows[0].id, tiledFrame: frame))
        } else {
            // Distribute height evenly among stacked windows with inner gap.
            // Scale inner gap down if necessary so windows never overflow canvas bottom.
            let minWindowHeight = 30.0
            let maxGaps = max(0.0, canvasH - (Double(count) * minWindowHeight))
            let effectiveGap = count > 1 ? min(gap, maxGaps / Double(count - 1)) : 0.0
            let totalGaps = Double(count - 1) * effectiveGap
            let windowH = max(minWindowHeight, (canvasH - totalGaps) / Double(count))
            var currentY = canvasY
            let bottomLimit = canvasY + canvasH

            for (idx, win) in column.windows.enumerated() {
                let available = max(minWindowHeight, bottomLimit - currentY)
                let h = (idx == count - 1) ? available : min(windowH, available)
                let frame = CGRect(x: x, y: currentY, width: width, height: h)
                results.append(makePlacement(winID: win.id, tiledFrame: frame))
                currentY += windowH + effectiveGap
            }
        }

        return results
    }
}
