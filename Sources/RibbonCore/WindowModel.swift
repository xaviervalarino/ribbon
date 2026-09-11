import Foundation

public struct WindowModel: Identifiable, Equatable, Sendable {
    public let id: Int
    public let pid: pid_t
    public var title: String
    public var appName: String
    public var isFloating: Bool

    public init(id: Int, pid: pid_t, title: String, appName: String, isFloating: Bool = false) {
        self.id = id
        self.pid = pid
        self.title = title
        self.appName = appName
        self.isFloating = isFloating
    }
}

public struct ColumnModel: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var windows: [WindowModel]
    public var widthRatio: Double
    public var activeRowIndex: Int

    public init(
        id: UUID = UUID(),
        windows: [WindowModel] = [],
        widthRatio: Double = 0.5,
        activeRowIndex: Int = 0
    ) {
        self.id = id
        self.windows = windows
        self.widthRatio = widthRatio
        self.activeRowIndex = activeRowIndex
    }

    public var activeWindow: WindowModel? {
        guard !windows.isEmpty else { return nil }
        let clamped = max(0, min(activeRowIndex, windows.count - 1))
        return windows[clamped]
    }
}
