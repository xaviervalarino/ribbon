import Foundation

/// Three-finger horizontal trackpad swipe state machine.
///
/// Per-gesture state resets whenever the finger count leaves `config.swipeFingers`. The axis
/// locks on the first crossing of `config.swipeFirst`: horizontal motion claims the gesture,
/// vertical motion leaves it to Mission Control. The first step fires at `swipeFirst`,
/// continuing the same way needs `swipeStep`, and a reversal steps back after `swipeReverse`.
/// Horizontal travel resets to zero after each step so a fast flick's excess is dropped.
public struct SwipeStepper: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case focusLeft
        case focusRight

        public var direction: FocusDirection { self == .focusLeft ? .left : .right }
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
    /// Set once a gesture fires its edge action; `feed` returns no steps until the fingers lift,
    /// since the edge action (a Space switch) changes the strip asynchronously.
    private var edgeFired = false

    public init() {}

    public mutating func feed(fingers: Int, dx: Double, dy: Double, config: Config) -> Step? {
        guard fingers == config.swipeFingers, fingers > 0 else {
            self = SwipeStepper()
            return nil
        }
        guard !edgeFired else { return nil }

        travelX += dx / Double(fingers)
        travelY += dy / Double(fingers)
        if isHorizontal == nil, max(abs(travelX), abs(travelY)) >= config.swipeFirst {
            isHorizontal = abs(travelX) > abs(travelY)
        }
        guard isHorizontal == true else { return nil }

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
        edgeFired = true
        return .edge
    }
}
