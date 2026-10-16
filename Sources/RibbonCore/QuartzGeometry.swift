import Foundation
import CoreGraphics

/// Top-left anchored 2D point in canonical Quartz / WindowServer coordinates.
/// Origin (0, 0) is at the top-left of the primary display.
public struct QuartzPoint: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ cgPoint: CGPoint) {
        self.x = Double(cgPoint.x)
        self.y = Double(cgPoint.y)
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    public static let zero = QuartzPoint(x: 0, y: 0)
}

/// 2D dimensions in canonical Quartz coordinates.
public struct QuartzSize: Sendable, Equatable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init(_ cgSize: CGSize) {
        self.width = Double(cgSize.width)
        self.height = Double(cgSize.height)
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    public static let zero = QuartzSize(width: 0, height: 0)
}

/// Canonical top-left anchored rectangle in Quartz / WindowServer coordinates.
///
/// Unlike AppKit/Cocoa frames whose origin (0, 0) is at the bottom-left of the primary display
/// with Y extending upward, `QuartzRect` matches WindowServer, SkyLight, and Accessibility:
/// - Origin (0, 0) is top-left of primary display.
/// - X increases rightward.
/// - Y increases downward.
public struct QuartzRect: Sendable, Equatable, Hashable, Codable {
    public var origin: QuartzPoint
    public var size: QuartzSize

    public init(origin: QuartzPoint, size: QuartzSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = QuartzPoint(x: x, y: y)
        self.size = QuartzSize(width: width, height: height)
    }

    public init(_ rect: CGRect) {
        self.origin = QuartzPoint(rect.origin)
        self.size = QuartzSize(rect.size)
    }

    public var x: Double {
        get { origin.x }
        set { origin.x = newValue }
    }

    public var y: Double {
        get { origin.y }
        set { origin.y = newValue }
    }

    public var width: Double {
        get { size.width }
        set { size.width = newValue }
    }

    public var height: Double {
        get { size.height }
        set { size.height = newValue }
    }

    public var minX: Double { origin.x }
    public var maxX: Double { origin.x + size.width }
    public var minY: Double { origin.y }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + (size.width / 2.0) }
    public var midY: Double { origin.y + (size.height / 2.0) }

    public var area: Double {
        max(0.0, size.width) * max(0.0, size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = QuartzRect(x: 0, y: 0, width: 0, height: 0)

    public func intersects(_ other: QuartzRect) -> Bool {
        return minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
    }

    public func intersection(_ other: QuartzRect) -> QuartzRect? {
        let iMinX = max(minX, other.minX)
        let iMaxX = min(maxX, other.maxX)
        let iMinY = max(minY, other.minY)
        let iMaxY = min(maxY, other.maxY)

        guard iMinX < iMaxX && iMinY < iMaxY else {
            return nil
        }
        return QuartzRect(x: iMinX, y: iMinY, width: iMaxX - iMinX, height: iMaxY - iMinY)
    }

    public func contains(_ point: QuartzPoint) -> Bool {
        return point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func contains(_ other: QuartzRect) -> Bool {
        return other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    public func insetBy(dx: Double, dy: Double) -> QuartzRect {
        QuartzRect(
            x: origin.x + dx,
            y: origin.y + dy,
            width: max(0.0, size.width - (dx * 2.0)),
            height: max(0.0, size.height - (dy * 2.0))
        )
    }

    public func offsetBy(dx: Double, dy: Double) -> QuartzRect {
        QuartzRect(
            x: origin.x + dx,
            y: origin.y + dy,
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - Conversions & Multi-Monitor Topology

public enum QuartzGeometry {
    /// Converts an AppKit/Cocoa CGRect (bottom-left origin, Y-up) to a QuartzRect (top-left origin, Y-down).
    ///
    /// The primary display height defines the Y-axis reflection plane in AppKit.
    public static func toQuartzRect(cocoaFrame: CGRect, primaryScreenHeight: Double) -> QuartzRect {
        let quartzY = primaryScreenHeight - (Double(cocoaFrame.origin.y) + Double(cocoaFrame.height))
        return QuartzRect(
            x: Double(cocoaFrame.origin.x),
            y: quartzY,
            width: Double(cocoaFrame.width),
            height: Double(cocoaFrame.height)
        )
    }

    /// Converts a QuartzRect (top-left origin, Y-down) back to an AppKit/Cocoa CGRect (bottom-left origin, Y-up).
    public static func toCocoaRect(quartzRect: QuartzRect, primaryScreenHeight: Double) -> CGRect {
        let cocoaY = primaryScreenHeight - (quartzRect.y + quartzRect.height)
        return CGRect(
            x: quartzRect.x,
            y: cocoaY,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    /// Determines if `candidate` is directly adjacent to the left edge of `rect`.
    public static func isAdjacentLeft(
        rect: QuartzRect,
        candidate: QuartzRect,
        tolerance: Double = 1.0
    ) -> Bool {
        let verticalOverlap = max(rect.minY, candidate.minY) < min(rect.maxY, candidate.maxY)
        guard verticalOverlap else { return false }
        return abs(candidate.maxX - rect.minX) <= tolerance
    }

    /// Determines if `candidate` is directly adjacent to the right edge of `rect`.
    public static func isAdjacentRight(
        rect: QuartzRect,
        candidate: QuartzRect,
        tolerance: Double = 1.0
    ) -> Bool {
        let verticalOverlap = max(rect.minY, candidate.minY) < min(rect.maxY, candidate.maxY)
        guard verticalOverlap else { return false }
        return abs(rect.maxX - candidate.minX) <= tolerance
    }

    /// Resolves which screen best contains a given QuartzRect based on maximal intersection area.
    public static func bestScreenID(
        forFrame frame: QuartzRect,
        screens: [(id: CGDirectDisplayID, bounds: QuartzRect)]
    ) -> CGDirectDisplayID? {
        guard !screens.isEmpty else { return nil }
        var bestID: CGDirectDisplayID?
        var maxArea: Double = 0

        for screen in screens {
            if let intersection = screen.bounds.intersection(frame) {
                let area = intersection.area
                if area > maxArea {
                    maxArea = area
                    bestID = screen.id
                }
            }
        }
        return bestID ?? screens.first?.id
    }
}
