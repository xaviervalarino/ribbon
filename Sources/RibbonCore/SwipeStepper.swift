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
    }

    private enum Axis: Sendable, Equatable {
        case x
        case y
    }

    private var travelX: Double = 0
    private var travelY: Double = 0
    private var axis: Axis?
    private var lastDir: Int?

    public init() {}

    public mutating func feed(fingers: Int, dx: Double, dy: Double, config: Config) -> Step? {
        guard fingers == config.swipeFingers, fingers > 0 else {
            travelX = 0
            travelY = 0
            axis = nil
            lastDir = nil
            return nil
        }

        travelX += dx / Double(fingers)
        travelY += dy / Double(fingers)
        if axis == nil, max(abs(travelX), abs(travelY)) >= config.swipeFirst {
            axis = abs(travelX) > abs(travelY) ? .x : .y
        }
        guard axis == .x else { return nil }

        let dir = travelX < 0 ? -1 : 1
        let threshold: Double
        if let last = lastDir {
            threshold = (dir == last) ? config.swipeStep : config.swipeReverse
        } else {
            threshold = config.swipeFirst
        }

        guard abs(travelX) >= threshold else { return nil }
        lastDir = dir
        travelX = 0
        return dir < 0 ? .focusRight : .focusLeft
    }
}
