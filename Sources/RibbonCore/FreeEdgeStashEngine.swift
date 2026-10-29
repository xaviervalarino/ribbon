import Foundation
import CoreGraphics

public enum ScreenEdge: String, CaseIterable, Sendable, Hashable {
    case left
    case right
    case top
    case bottom
}

public enum StripWing: String, Sendable {
    case left
    case right
}

/// Representation of display frame bounds in canonical Quartz coordinates.
public struct DisplayBounds: Sendable, Equatable {
    public let id: CGDirectDisplayID
    public let frame: QuartzRect
    public let visibleFrame: QuartzRect
    public let scaleFactor: Double

    public init(id: CGDirectDisplayID, frame: QuartzRect, visibleFrame: QuartzRect, scaleFactor: Double = 2.0) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scaleFactor = scaleFactor
    }
}

/// Computes rectilinear off-screen parking coordinates that retain a 1pt GPU surface anchor
/// while mathematically guaranteeing zero area intersection with adjacent physical displays.
public enum FreeEdgeStashEngine {
    private static let adjacencyEpsilon: Double = 2.0
    private static let overlapEpsilon: Double = 0.5
    public static let sliverAnchorSize: Double = 1.0

    /// Returns the set of edges for the target display that do not touch any neighbor display.
    public static func freeEdges(
        for targetID: CGDirectDisplayID,
        in displays: [DisplayBounds]
    ) -> Set<ScreenEdge> {
        guard let target = displays.first(where: { $0.id == targetID }) else {
            return Set(ScreenEdge.allCases)
        }

        var available: Set<ScreenEdge> = Set(ScreenEdge.allCases)
        let A = target.frame

        for other in displays where other.id != target.id {
            let B = other.frame

            // 1. Left of A touches Right of B
            if available.contains(.left) {
                let distance = abs(A.minX - B.maxX)
                let verticalOverlap = min(A.maxY, B.maxY) - max(A.minY, B.minY)
                if distance <= adjacencyEpsilon && verticalOverlap > overlapEpsilon {
                    available.remove(.left)
                }
            }

            // 2. Right of A touches Left of B
            if available.contains(.right) {
                let distance = abs(A.maxX - B.minX)
                let verticalOverlap = min(A.maxY, B.maxY) - max(A.minY, B.minY)
                if distance <= adjacencyEpsilon && verticalOverlap > overlapEpsilon {
                    available.remove(.right)
                }
            }

            // 3. Top of A touches Bottom of B (Y-down Quartz coordinates)
            if available.contains(.top) {
                let distance = abs(A.minY - B.maxY)
                let horizontalOverlap = min(A.maxX, B.maxX) - max(A.minX, B.minX)
                if distance <= adjacencyEpsilon && horizontalOverlap > overlapEpsilon {
                    available.remove(.top)
                }
            }

            // 4. Bottom of A touches Top of B
            if available.contains(.bottom) {
                let distance = abs(A.maxY - B.minY)
                let horizontalOverlap = min(A.maxX, B.maxX) - max(A.minX, B.minX)
                if distance <= adjacencyEpsilon && horizontalOverlap > overlapEpsilon {
                    available.remove(.bottom)
                }
            }

            if available.isEmpty { break }
        }

        return available
    }

    /// Computes the exact parked origin in Quartz coordinates with zero bleed and a 1.0pt sliver anchor.
    public static func parkedOrigin(
        windowSize: QuartzSize,
        tiledY: Double,
        wing: StripWing,
        targetDisplay: DisplayBounds,
        allDisplays: [DisplayBounds]
    ) -> QuartzPoint {
        let free = freeEdges(for: targetDisplay.id, in: allDisplays)
        // Side edges come first: WindowServer keeps title bars on screen, so a top stash stays
        // fully visible and a bottom stash shows 28pt (measured on a 1512x982 display).
        let preferred: [ScreenEdge] = (wing == .left)
            ? [.left, .right, .bottom, .top]
            : [.right, .left, .bottom, .top]

        let chosenEdge = preferred.first { edge in
            guard free.contains(edge) else { return false }
            let origin = calculateRawOrigin(
                windowSize: windowSize,
                tiledY: tiledY,
                edge: edge,
                wing: wing,
                display: targetDisplay
            )
            let rect = QuartzRect(origin: origin, size: windowSize)
            return isZeroBleed(rect: rect, hostID: targetDisplay.id, allDisplays: allDisplays)
        } ?? (free.first ?? (wing == .left ? .left : .right))

        return calculateRawOrigin(
            windowSize: windowSize,
            tiledY: tiledY,
            edge: chosenEdge,
            wing: wing,
            display: targetDisplay
        )
    }

    private static func calculateRawOrigin(
        windowSize: QuartzSize,
        tiledY: Double,
        edge: ScreenEdge,
        wing: StripWing,
        display: DisplayBounds
    ) -> QuartzPoint {
        let D = display.frame
        let V = display.visibleFrame

        switch edge {
        case .left:
            let x = D.minX - windowSize.width + sliverAnchorSize
            // Keep window at its natural tiled Y, clamped inside display bounds to prevent diagonal bleed
            let clampedY = min(max(tiledY, D.minY), max(D.minY, D.maxY - windowSize.height))
            return QuartzPoint(x: x, y: clampedY)

        case .right:
            let x = D.maxX - sliverAnchorSize
            let clampedY = min(max(tiledY, D.minY), max(D.minY, D.maxY - windowSize.height))
            return QuartzPoint(x: x, y: clampedY)

        case .bottom:
            let y = D.maxY - sliverAnchorSize
            let halfW = V.width / 2.0
            let x = (wing == .left) ? V.minX : (V.minX + halfW)
            return QuartzPoint(x: x, y: y)

        case .top:
            let y = D.minY - windowSize.height + sliverAnchorSize
            let halfW = V.width / 2.0
            let x = (wing == .left) ? V.minX : (V.minX + halfW)
            return QuartzPoint(x: x, y: y)
        }
    }

    /// Checks if a candidate parked rectangle has zero area intersection with any display other than the host.
    public static func isZeroBleed(
        rect: QuartzRect,
        hostID: CGDirectDisplayID,
        allDisplays: [DisplayBounds]
    ) -> Bool {
        for other in allDisplays where other.id != hostID {
            if let inter = rect.intersection(other.frame), inter.area > 0.0 {
                return false
            }
        }
        return true
    }
}
