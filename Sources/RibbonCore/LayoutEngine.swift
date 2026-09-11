import Foundation
import CoreGraphics

public struct WindowPlacement: Sendable {
    public let windowID: Int
    public let frame: CGRect
    public let isHidden: Bool

    public init(windowID: Int, frame: CGRect, isHidden: Bool) {
        self.windowID = windowID
        self.frame = frame
        self.isHidden = isHidden
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

    public static func computePlan(
        for ribbon: Ribbon,
        screenFrame: CGRect,
        config: Config
    ) -> TilingPlan {
        guard !ribbon.columns.isEmpty else { return TilingPlan() }

        var placements: [WindowPlacement] = []

        let canvasX = screenFrame.minX + config.edgeMargin
        let canvasY = screenFrame.minY + config.edgeMargin
        let canvasW = screenFrame.width - (config.edgeMargin * 2)
        let canvasH = screenFrame.height - (config.edgeMargin * 2)

        let activeIdx = max(0, min(ribbon.activeColumnIndex, ribbon.columns.count - 1))
        let activeCol = ribbon.columns[activeIdx]
        let activeWidth = min(canvasW, activeCol.widthRatio * canvasW)

        // Center the active column within the canvas
        let activeX = canvasX + (canvasW - activeWidth) / 2.0

        // 1. Place active column
        placements.append(contentsOf: layoutColumn(
            column: activeCol,
            x: activeX,
            width: activeWidth,
            canvasY: canvasY,
            canvasH: canvasH,
            gap: config.windowGap,
            isHidden: false
        ))

        // 2. Place left columns
        var leftEdge = activeX - config.windowGap
        if activeIdx > 0 {
            for colIdx in stride(from: activeIdx - 1, through: 0, by: -1) {
                let col = ribbon.columns[colIdx]
                let w = min(canvasW, col.widthRatio * canvasW)
                let colX = leftEdge - w

                // Zero-bleed: if completely off the left screen edge, hide windows
                let isOffScreen = (colX + w) < canvasX
                placements.append(contentsOf: layoutColumn(
                    column: col,
                    x: colX,
                    width: w,
                    canvasY: canvasY,
                    canvasH: canvasH,
                    gap: config.windowGap,
                    isHidden: isOffScreen
                ))

                leftEdge = colX - config.windowGap
            }
        }

        // 3. Place right columns
        var rightEdge = activeX + activeWidth + config.windowGap
        if activeIdx < ribbon.columns.count - 1 {
            for colIdx in (activeIdx + 1)..<ribbon.columns.count {
                let col = ribbon.columns[colIdx]
                let w = min(canvasW, col.widthRatio * canvasW)
                let colX = rightEdge

                // Zero-bleed: if completely off the right screen edge, hide windows
                let isOffScreen = colX > (canvasX + canvasW)
                placements.append(contentsOf: layoutColumn(
                    column: col,
                    x: colX,
                    width: w,
                    canvasY: canvasY,
                    canvasH: canvasH,
                    gap: config.windowGap,
                    isHidden: isOffScreen
                ))

                rightEdge = colX + w + config.windowGap
            }
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
        isHidden: Bool
    ) -> [WindowPlacement] {
        var results: [WindowPlacement] = []
        let count = column.windows.count
        guard count > 0 else { return results }

        if count == 1 {
            let frame = CGRect(x: x, y: canvasY, width: width, height: canvasH)
            results.append(WindowPlacement(windowID: column.windows[0].id, frame: frame, isHidden: isHidden))
        } else {
            // Distribute height evenly among stacked windows with inner gap
            let totalGaps = Double(count - 1) * gap
            let windowH = max(100.0, (canvasH - totalGaps) / Double(count))
            var currentY = canvasY

            for win in column.windows {
                let frame = CGRect(x: x, y: currentY, width: width, height: windowH)
                results.append(WindowPlacement(windowID: win.id, frame: frame, isHidden: isHidden))
                currentY += windowH + gap
            }
        }

        return results
    }
}
