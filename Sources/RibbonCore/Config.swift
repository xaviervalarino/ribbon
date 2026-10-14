import Foundation

public enum StashCorner: String, Sendable, Codable {
    case bottomRight, bottomLeft, topRight, topLeft
}

public struct Config: Sendable, Codable {
    public var windowGap: Double
    public var edgeMargin: Double
    public var defaultWidthRatio: Double
    public var widthCycleRatios: [Double]
    public var appWidthRatios: [String: Double]
    public var ignoredApps: Set<String>
    public var stashCorner: StashCorner
    public var stashSliverSize: Double
    public var spaceChangeDebounceMs: Int

    public init(
        windowGap: Double = 8.0,
        edgeMargin: Double = 2.0,
        defaultWidthRatio: Double = 0.5,
        widthCycleRatios: [Double] = [0.382, 0.5, 0.618, 0.8, 1.0],
        appWidthRatios: [String: Double] = [
            "Zen Browser": 0.8,
            "Zen": 0.8,
            "Firefox Developer Edition": 0.8,
            "Safari": 0.8,
            "Google Chrome": 0.8,
            "Chromium": 0.8,
            "Slack": 0.8,
            "Code": 1.0,
            "Visual Studio Code": 1.0,
            "Mail": 1.0,
            "Figma": 1.0
        ],
        ignoredApps: Set<String> = [
            "Finder",
            "System Settings",
            "1Password",
            "Raycast",
            "Karabiner-Elements",
            "Activity Monitor",
            "borders"
        ],
        stashCorner: StashCorner = .bottomRight,
        stashSliverSize: Double = 2.0,
        spaceChangeDebounceMs: Int = 25
    ) {
        self.windowGap = windowGap
        self.edgeMargin = edgeMargin
        self.defaultWidthRatio = defaultWidthRatio
        self.widthCycleRatios = widthCycleRatios
        self.appWidthRatios = appWidthRatios
        self.ignoredApps = ignoredApps
        self.stashCorner = stashCorner
        self.stashSliverSize = stashSliverSize
        self.spaceChangeDebounceMs = spaceChangeDebounceMs
    }

    public static let `default` = Config()
}
