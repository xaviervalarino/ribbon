import Foundation

/// Three-finger horizontal trackpad swipe state machine.
///
/// Per-gesture state resets whenever the finger count leaves `config.swipeFingers`. The axis
/// locks on the first crossing of `config.swipeFirst`: horizontal motion claims the gesture,
/// vertical motion leaves it to Mission Control. The first step fires at `swipeFirst`,
/// continuing the same way needs `swipeStep`, and a reversal steps back after `swipeReverse`.
/// Horizontal travel resets to zero after each step so a fast flick's excess is dropped.
/// `feedScrub` uses the same axis lock for a continuous scrub instead of steps.
public struct SwipeStepper: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case focusLeft
        case focusRight

        public var direction: FocusDirection { self == .focusLeft ? .left : .right }
    }

    public enum ScrubEvent: Sendable, Equatable {
        /// Horizontal travel since the last event, as a fraction of the trackpad's width.
        case move(Double)
        /// The fingers lifted after a horizontal scrub.
        case end
    }

    /// What a step does once the strip's edge is known.
    public enum Action: Sendable, Equatable {
        case focus
        /// The step pushed past the strip's edge `config.swipeEdgeSteps` times in one gesture.
        case edge
    }

    private var travelX: Double = 0
    private var travelY: Double = 0
    private var isHorizontal: Bool?
    private var lastDir: Int?
    /// Consecutive pushes past the edge, all toward `edgeStep`.
    private var edgeStep: Step?
    private var edgePushes = 0
    /// Set by an edge action or `cancel()`: nothing more comes out until the fingers lift. An edge
    /// action (a Space switch) changes the strip asynchronously.
    private var waitsForLift = false

    public init() {}

    public mutating func feed(fingers: Int, dx: Double, dy: Double, config: Config) -> Step? {
        guard accumulate(fingers: fingers, dx: dx, dy: dy, config: config) else { return nil }

        let dir = travelX < 0 ? -1 : 1
        let threshold = lastDir == nil ? config.swipeFirst : (dir == lastDir ? config.swipeStep : config.swipeReverse)
        guard abs(travelX) >= threshold else { return nil }
        lastDir = dir
        travelX = 0
        return dir < 0 ? .focusRight : .focusLeft
    }

    /// Resolves a step from `feed` against the strip: away from the edge it moves focus; at the edge
    /// it counts a push, and the `config.swipeEdgeSteps`-th push in a row fires the edge action.
    /// Nil while pushes are still counting, or when `swipeEdgeSteps` is 0 and the step is at the edge.
    public mutating func resolve(_ step: Step, atEdge: Bool, config: Config) -> Action? {
        guard atEdge else {
            edgeStep = nil
            edgePushes = 0
            return .focus
        }
        guard config.swipeEdgeSteps > 0 else { return nil }
        edgePushes = edgeStep == step ? edgePushes + 1 : 1
        edgeStep = step
        guard edgePushes >= config.swipeEdgeSteps else { return nil }
        waitsForLift = true
        return .edge
    }

    /// The scrub counterpart of `feed`: once the gesture locks horizontal, each event's travel
    /// (the travel up to the lock included) comes out as `.move`, and lifting ends it with `.end`.
    public mutating func feedScrub(fingers: Int, dx: Double, dy: Double, config: Config) -> ScrubEvent? {
        guard fingers == config.swipeFingers, fingers > 0 else {
            let scrubbed = isHorizontal == true && !waitsForLift
            self = SwipeStepper()
            return scrubbed ? .end : nil
        }
        guard accumulate(fingers: fingers, dx: dx, dy: dy, config: config), travelX != 0 else { return nil }
        defer { travelX = 0 }
        return .move(travelX)
    }

    /// Ignores the rest of the gesture: nothing more comes out until the fingers lift.
    public mutating func cancel() {
        waitsForLift = true
    }

    /// Adds one event's travel, resetting on a finger count other than `swipeFingers`. True when the
    /// gesture is locked horizontal and still live.
    private mutating func accumulate(fingers: Int, dx: Double, dy: Double, config: Config) -> Bool {
        guard fingers == config.swipeFingers, fingers > 0 else {
            self = SwipeStepper()
            return false
        }
        guard !waitsForLift else { return false }
        travelX += dx / Double(fingers)
        travelY += dy / Double(fingers)
        if isHorizontal == nil, max(abs(travelX), abs(travelY)) >= config.swipeFirst {
            isHorizontal = abs(travelX) > abs(travelY)
        }
        return isHorizontal == true
    }
}
