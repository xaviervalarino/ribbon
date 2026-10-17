import Foundation
import AppKit
import CoreGraphics
import QuartzCore

/// Slides windows to new ribbon positions with per-frame AX position writes, then hands each
/// window's final mutation (resize, logging, size cache) to its AppDriver.
///
/// - Windows move along their strip (natural) positions and are pinned at their stash sliver
///   only while past it, so off-screen windows join and leave in step with their neighbors.
/// - Frames come from the main display's CADisplayLink (up to 120Hz), kept alive and paused
///   between slides so the first frame is not delayed by link creation.
/// - Each PID has at most one slide step in flight, so a slow app skips frames instead of
///   queueing them, and its final mutation waits for that step so a stale step never lands last.
/// - A fresh slide sends its first step immediately and holds the clock until every app has
///   landed it (capped), so slow apps (Electron) start with the rest of the strip.
///
/// Confined to the main queue: the display link, `animate`, and step completions all run there.
final class ScrollAnimator: @unchecked Sendable {
    /// Stash slivers a window is pinned to while its strip position lies beyond them.
    struct Parking {
        var minX: CGFloat?
        var maxX: CGFloat?
    }

    struct Slide {
        let pid: pid_t
        let element: AXElement
        let fromNatural: CGPoint
        let toNatural: CGPoint
        let parking: Parking
        /// Both set when the size animates with the position (`ResizeMode.animate`).
        let fromSize: CGSize?
        let toSize: CGSize?
        let final: AppDriver.WindowMutation
    }

    private struct Track {
        let pid: pid_t
        let element: AXElement
        var fromNatural: CGPoint
        let toNatural: CGPoint
        let parking: Parking
        var fromSize: CGSize?
        let toSize: CGSize?
        let final: AppDriver.WindowMutation
    }

    /// Longest the clock waits for slow apps to land the first step.
    private static let maxStartHoldMs = 50.0
    private static let frameMs = 1000.0 / 120.0

    private let driverFor: (pid_t) -> AppDriver
    /// Runs when a slide finishes and no further slide is pending.
    var onIdle: (() -> Void)?

    private var tracks: [CGWindowID: Track] = [:]
    private var startMs: Double = 0
    private var durationMs: Double = 0
    private var holdStartMs: Double?
    private var displayLink: CADisplayLink?
    private var fallbackTimer: DispatchSourceTimer?
    private lazy var linkTarget = DisplayLinkTarget { [weak self] in self?.tick() }
    private var inFlight: Set<pid_t> = []
    private var pendingFinals: [pid_t: [AppDriver.WindowMutation]] = [:]
    private var framesThisSlide = 0
    private var holdMsThisSlide = 0.0
    private var lastTickMs: Double?

    init(driverFor: @escaping (pid_t) -> AppDriver) {
        self.driverFor = driverFor
    }

    /// True while a slide runs; main-thread event handlers wait until it ends.
    var isActive: Bool {
        !tracks.isEmpty
    }

    func isAnimating(_ id: CGWindowID) -> Bool {
        tracks[id] != nil
    }

    /// Where the window shows mid-slide (pinned at its sliver), or nil when not sliding.
    func currentOrigin(_ id: CGWindowID) -> CGPoint? {
        guard let track = tracks[id] else { return nil }
        return Self.shown(track, progress: progress(at: Self.nowMs()))
    }

    /// The window's size mid-slide when its size animates, or nil.
    func currentSize(_ id: CGWindowID) -> CGSize? {
        guard let track = tracks[id] else { return nil }
        return Self.size(track, progress: progress(at: Self.nowMs()))
    }

    /// The window's strip position mid-slide, or nil when not sliding.
    func currentNatural(_ id: CGWindowID) -> CGPoint? {
        guard let track = tracks[id] else { return nil }
        return Self.natural(track, progress: progress(at: Self.nowMs()))
    }

    /// Starts or retargets slides. Windows already sliding restart from their current strip
    /// position, so every window shares one clock and the strip moves as a unit. Duration grows
    /// with the longest strip distance, up to twice `baseDurationMs` for a full screen width.
    func animate(_ slides: [CGWindowID: Slide], baseDurationMs: Double, referenceWidth: Double) {
        let now = Self.nowMs()
        let wasActive = isActive
        let p = progress(at: now)
        for (id, track) in tracks {
            tracks[id]?.fromNatural = Self.natural(track, progress: p)
            tracks[id]?.fromSize = Self.size(track, progress: p)
        }
        for (id, slide) in slides {
            tracks[id] = Track(pid: slide.pid, element: slide.element, fromNatural: slide.fromNatural,
                               toNatural: slide.toNatural, parking: slide.parking,
                               fromSize: slide.fromSize, toSize: slide.toSize, final: slide.final)
        }
        for pid in pendingFinals.keys {
            pendingFinals[pid]?.removeAll { slides[$0.windowID] != nil }
        }

        let longest = tracks.values.map {
            hypot($0.toNatural.x - $0.fromNatural.x, $0.toNatural.y - $0.fromNatural.y)
        }.max() ?? 0
        durationMs = baseDurationMs * (1 + min(1, longest / max(1, referenceWidth)))
        startMs = now

        guard !wasActive else { return }
        // A fresh slide (not a retarget) sends its first step now and holds the clock until it lands.
        framesThisSlide = 0
        holdMsThisSlide = 0
        holdStartMs = now
        sendSteps(progress: progress(at: now))
        resumeFrames()
    }

    private func resumeFrames() {
        lastTickMs = nil
        if displayLink == nil, fallbackTimer == nil,
           let link = NSScreen.main?.displayLink(target: linkTarget, selector: #selector(DisplayLinkTarget.step(_:))) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        if let link = displayLink {
            link.isPaused = false
            return
        }
        guard fallbackTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .microseconds(Int(Self.frameMs * 1000)), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        fallbackTimer = t
        t.resume()
    }

    private func pauseFrames() {
        displayLink?.isPaused = true
        fallbackTimer?.cancel()
        fallbackTimer = nil
        lastTickMs = nil
    }

    private func tick() {
        guard isActive else {
            pauseFrames()
            return
        }
        let now = Self.nowMs()
        framesThisSlide += 1
        // A gap this long means the main thread was blocked, not that the display skipped.
        if let last = lastTickMs, now - last > 50 {
            RibbonLog.log("slide stall \(Int(now - last))ms between frames", category: "slide")
        }
        lastTickMs = now

        if let holdStart = holdStartMs {
            guard inFlight.isEmpty || now - holdStart >= Self.maxStartHoldMs else { return }
            // Resume the clock from the first step's progress, as if it had just been shown.
            holdStartMs = nil
            holdMsThisSlide = now - holdStart
            startMs = now - Self.frameMs
        }

        let p = progress(at: now)
        sendSteps(progress: p)
        if p >= 1 {
            finish()
        }
    }

    private func sendSteps(progress p: Double) {
        var stepsByPID: [pid_t: [AppDriver.SlideStep]] = [:]
        for track in tracks.values {
            stepsByPID[track.pid, default: []].append(
                AppDriver.SlideStep(element: track.element, origin: Self.shown(track, progress: p),
                                    size: Self.size(track, progress: p))
            )
        }
        for (pid, steps) in stepsByPID where !inFlight.contains(pid) {
            send(steps, to: pid)
        }
    }

    private func finish() {
        RibbonLog.log(
            "slide done windows=\(tracks.count) duration=\(Int(durationMs))ms frames=\(framesThisSlide) hold=\(Int(holdMsThisSlide))ms clock=\(displayLink != nil ? "display" : "timer")",
            category: "slide"
        )
        pauseFrames()
        holdStartMs = nil
        var finalsByPID: [pid_t: [AppDriver.WindowMutation]] = [:]
        for track in tracks.values {
            finalsByPID[track.pid, default: []].append(track.final)
        }
        tracks.removeAll()
        for (pid, finals) in finalsByPID {
            if inFlight.contains(pid) {
                pendingFinals[pid, default: []].append(contentsOf: finals)
            } else {
                let driver = driverFor(pid)
                Task { await driver.enqueue(finals) }
            }
        }
        onIdle?()
    }

    private func send(_ steps: [AppDriver.SlideStep], to pid: pid_t) {
        inFlight.insert(pid)
        let driver = driverFor(pid)
        Task { [weak self] in
            await driver.slide(steps)
            DispatchQueue.main.async { self?.stepLanded(pid: pid) }
        }
    }

    private func stepLanded(pid: pid_t) {
        inFlight.remove(pid)
        guard let finals = pendingFinals.removeValue(forKey: pid), !finals.isEmpty else { return }
        let driver = driverFor(pid)
        Task { await driver.enqueue(finals) }
    }

    /// While holding, progress stays at the first step so retargets and lookups agree with it.
    private func progress(at nowMs: Double) -> Double {
        guard durationMs > 0 else { return 1 }
        if holdStartMs != nil { return min(1, Self.frameMs / durationMs) }
        return min(1, max(0, (nowMs - startMs) / durationMs))
    }

    /// Ease-in-out sine: the strip starts and settles gently, so long jumps never lurch.
    private static func eased(_ progress: Double) -> Double {
        0.5 - 0.5 * cos(Double.pi * progress)
    }

    private static func size(_ track: Track, progress: Double) -> CGSize? {
        guard let from = track.fromSize, let to = track.toSize else { return nil }
        let e = eased(progress)
        return CGSize(width: (from.width + (to.width - from.width) * e).rounded(),
                      height: (from.height + (to.height - from.height) * e).rounded())
    }

    private static func natural(_ track: Track, progress: Double) -> CGPoint {
        let e = eased(progress)
        return CGPoint(
            x: track.fromNatural.x + (track.toNatural.x - track.fromNatural.x) * e,
            y: track.fromNatural.y + (track.toNatural.y - track.fromNatural.y) * e
        )
    }

    /// The strip position pinned at the window's stash slivers.
    private static func shown(_ track: Track, progress: Double) -> CGPoint {
        var p = natural(track, progress: progress)
        if let maxX = track.parking.maxX { p.x = min(p.x, maxX) }
        if let minX = track.parking.minX { p.x = max(p.x, minX) }
        return CGPoint(x: p.x.rounded(), y: p.y.rounded())
    }

    private static func nowMs() -> Double {
        CACurrentMediaTime() * 1000
    }
}

/// CADisplayLink needs an Objective-C target; forwards each frame to a closure.
private final class DisplayLinkTarget: NSObject {
    private let onFrame: () -> Void

    init(onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
    }

    @objc func step(_ link: CADisplayLink) {
        onFrame()
    }
}
