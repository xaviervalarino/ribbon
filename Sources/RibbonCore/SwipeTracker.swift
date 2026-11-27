import Foundation

/// Velocity of a continuous swipe and how far it would glide after decelerating, as niri's
/// `SwipeTracker` (src/input/swipe_tracker.rs) computes them: velocity over the last 150ms of
/// motion, deceleration of 0.997 per millisecond. Velocity leaves out the oldest sample's delta,
/// which moved before that sample's time: a swipe's first sample can hold all travel up to an
/// axis lock.
public struct SwipeTracker: Sendable {
    private struct Sample: Sendable {
        let delta: Double
        let time: Double
    }

    private static let historySeconds = 0.15
    /// Distance travelled per unit of velocity while decelerating to a halt: -1 / (1000 * ln 0.997)
    /// seconds, about 0.333.
    private static let glideSeconds = -1 / (1000 * log(0.997))

    private var history: [Sample] = []

    public init() {}

    /// Adds motion `delta` at `time` (seconds, monotonic). A sample older than the last one is dropped.
    public mutating func push(delta: Double, time: Double) {
        if let last = history.last, time < last.time { return }
        history.append(Sample(delta: delta, time: time))
        history.removeAll { $0.time < time - Self.historySeconds }
    }

    /// Units per second over the recent history; 0 without two samples apart in time.
    public var velocity: Double {
        guard let first = history.first, let last = history.last, last.time > first.time else { return 0 }
        return history.dropFirst().reduce(0) { $0 + $1.delta } / (last.time - first.time)
    }

    /// How much further the swipe would travel decelerating from its current velocity to a halt.
    public var glide: Double {
        velocity * Self.glideSeconds
    }
}
