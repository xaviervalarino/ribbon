import Foundation

public enum StashCorner: String, Sendable, Codable {
    case bottomRight, bottomLeft, topRight, topLeft
}

/// When a sliding window's size change is applied.
public enum ResizeMode: String, Sendable, Codable {
    /// After the slide settles.
    case end
    /// At slide start, growing or shrinking; shrinking briefly opens a gap neighbors close.
    case instant
    /// Growth at slide start (neighbors slide out from under it); shrinking after it settles.
    case growFirst = "grow-first"
}

/// When a command's focus target is activated during a slide.
public enum FocusTiming: String, Sendable, Codable {
    /// With the slide's first step; keystrokes reach the window at once, but every press of a
    /// fast run activates its app mid-slide, and apps block AX calls while they redraw for it.
    case start
    /// Once the strip settles, so a fast run activates only the window it lands on.
    case end
}

/// What a three-finger horizontal swipe does: step focus a column at a time, or scrub the strip
/// with the fingers and settle on a column when they lift.
public enum SwipeMode: String, Sendable, Codable {
    case step, follow
}

public struct Config: Sendable, Codable {
    public var windowGap: Double
    public var edgeMargin: Double
    public var defaultWidthRatio: Double
    public var widthStep: Double
    public var widthCycleRatios: [Double]
    public var appWidthRatios: [String: Double]
    public var ignoredApps: Set<String>
    /// Windows whose title contains one of these (case-insensitive) float instead of tiling.
    /// Browser extension pop-outs (Bitwarden's passkey prompt) report as standard, resizable
    /// windows, so their title is the only thing that sets them apart.
    public var floatTitlePatterns: [String]
    public func floats(title: String) -> Bool {
        floatTitlePatterns.contains { title.localizedCaseInsensitiveContains($0) }
    }

    public var stashCorner: StashCorner
    public var stashSliverSize: Double
    public var spaceChangeDebounceMs: Int
    /// Duration of the slide for command-driven scrolls; 0 jumps windows straight to their targets.
    public var scrollAnimationMs: Int
    public var resizeMode: ResizeMode
    public var focusTiming: FocusTiming
    public var overviewColumnsPerRow: Int
    public var swipeFingers: Int
    public var swipeFirst: Double
    public var swipeStep: Double
    public var swipeReverse: Double
    public var swipeMode: SwipeMode
    /// Canvas widths a scrub moves the strip per full trackpad width of finger travel.
    public var swipeFollowScale: Double
    /// Swipe steps past the strip's edge, in a row in one gesture, that run the edge command; 0 turns
    /// edge commands off in both swipe modes.
    public var swipeEdgeSteps: Int
    /// Programs and arguments run when a swipe pushes past the strip's left or right edge.
    public var swipeLeftEdgeCommand: [String]
    public var swipeRightEdgeCommand: [String]
    /// A released pan centers the focused column when its center lies within this fraction of the
    /// canvas width from the canvas center; 0 leaves the strip where the pan put it.
    public var panCenterSnap: Double

    public init(
        windowGap: Double = 4.0,
        edgeMargin: Double = 2.0,
        defaultWidthRatio: Double = 0.5,
        widthStep: Double = 0.1,
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
            "borders",
            // A VM window sizes itself to the guest display, so tiling it rescales the guest.
            "UTM"
        ],
        floatTitlePatterns: [String] = ["Extension: ("],
        stashCorner: StashCorner = .bottomRight,
        stashSliverSize: Double = 2.0,
        spaceChangeDebounceMs: Int = 25,
        scrollAnimationMs: Int = 55,
        resizeMode: ResizeMode = .end,
        focusTiming: FocusTiming = .end,
        overviewColumnsPerRow: Int = 3,
        swipeFingers: Int = 3,
        swipeFirst: Double = 0.03,
        swipeStep: Double = 0.15,
        swipeReverse: Double = 0.04,
        swipeMode: SwipeMode = .follow,
        swipeFollowScale: Double = 1.5,
        swipeEdgeSteps: Int = 2,
        swipeLeftEdgeCommand: [String] = ["/Applications/InstantSpaceSwitcher.app/Contents/MacOS/ISSCli", "left"],
        swipeRightEdgeCommand: [String] = ["/Applications/InstantSpaceSwitcher.app/Contents/MacOS/ISSCli", "right"],
        panCenterSnap: Double = 0.15
    ) {
        self.windowGap = windowGap
        self.edgeMargin = edgeMargin
        self.defaultWidthRatio = defaultWidthRatio
        self.widthStep = widthStep
        self.widthCycleRatios = widthCycleRatios
        self.appWidthRatios = appWidthRatios
        self.ignoredApps = ignoredApps
        self.floatTitlePatterns = floatTitlePatterns
        self.stashCorner = stashCorner
        self.stashSliverSize = stashSliverSize
        self.spaceChangeDebounceMs = spaceChangeDebounceMs
        self.scrollAnimationMs = scrollAnimationMs
        self.resizeMode = resizeMode
        self.focusTiming = focusTiming
        self.overviewColumnsPerRow = overviewColumnsPerRow
        self.swipeFingers = swipeFingers
        self.swipeFirst = swipeFirst
        self.swipeStep = swipeStep
        self.swipeReverse = swipeReverse
        self.swipeMode = swipeMode
        self.swipeFollowScale = swipeFollowScale
        self.swipeEdgeSteps = swipeEdgeSteps
        self.swipeLeftEdgeCommand = swipeLeftEdgeCommand
        self.swipeRightEdgeCommand = swipeRightEdgeCommand
        self.panCenterSnap = panCenterSnap
    }

    public static let `default` = Config()
}
