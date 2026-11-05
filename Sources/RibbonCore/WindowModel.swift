import Foundation
import CoreGraphics

public struct WindowModel: Identifiable, Equatable, Sendable, Codable {
    public let id: CGWindowID
    public let pid: pid_t
    public let bundleId: String?
    public var title: String
    public var appName: String
    public var isFloating: Bool
    /// The smallest height the app accepts; a resize below it leaves the window at this height.
    public var minHeight: Double?
    /// The smallest width the app accepts; a resize below it leaves the window at this width.
    public var minWidth: Double?

    public init(
        id: CGWindowID,
        pid: pid_t,
        bundleId: String? = nil,
        title: String,
        appName: String,
        isFloating: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.bundleId = bundleId
        self.title = title
        self.appName = appName
        self.isFloating = isFloating
    }
}

public struct ColumnModel: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var windows: [WindowModel]
    public var widthRatio: Double
    public var hasExplicitSingleWidth: Bool
    public var activeRowIndex: Int

    public init(
        id: UUID = UUID(),
        windows: [WindowModel] = [],
        widthRatio: Double = 0.5,
        hasExplicitSingleWidth: Bool = false,
        activeRowIndex: Int = 0
    ) {
        self.id = id
        self.windows = windows
        self.widthRatio = widthRatio
        self.hasExplicitSingleWidth = hasExplicitSingleWidth
        self.activeRowIndex = activeRowIndex
    }

    public var activeWindow: WindowModel? {
        guard !windows.isEmpty else { return nil }
        let clamped = max(0, min(activeRowIndex, windows.count - 1))
        return windows[clamped]
    }

    /// The largest minimum width among the column's windows; the column is never laid out narrower.
    public var minWidth: Double {
        windows.compactMap(\.minWidth).max() ?? 0
    }
}
