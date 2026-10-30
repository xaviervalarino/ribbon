import Foundation
import AppKit
import CoreGraphics
import QuartzCore

/// Slides windows to new ribbon positions with per-frame AX position writes, then hands each
/// window's final mutation (resize, logging, size cache) to its AppDriver.
///
/// - Windows move along their strip (natural) positions and are pinned at their stash sliver
///   only while past it, so off-screen windows join and leave in step with their neighbors.
///   Half past a shared display edge they show at their stash on the far side edge (or the
///   top/bottom) instead.
/// - Frames come from the main display's CADisplayLink (up to 120Hz), kept alive and paused
///   between slides so the first frame is not delayed by link creation.
/// - Each PID has at most one slide step in flight, so a slow app skips frames instead of
///   queueing them, and its final mutation waits for that step so a stale step never lands last.
/// - A fresh slide sends its first step immediately and holds the clock until every app has
///   landed it (capped), so slow apps (Electron) start with the rest of the strip. Apps still
///   applying the previous slide's resizes are not waited on.
/// - A retarget keeps each window's current velocity and eases it onto the new target, so
///   rapid presses read as one continuous glide instead of a stop and restart per press.
/// - Each app is sent the position it should show when its step lands (its measured step
///   round trip ahead), so a busy app lands in line with its neighbors instead of trailing them.
/// - A window whose app sits on a step past `ghostLagMs` gets a ghost block in its slot until the
///   app's final mutations are applied, so a slow app never leaves the strip looking empty.
///
/// Confined to the main queue: the display link, `animate`, and step completions all run there.
final class ScrollAnimator: @unchecked Sendable {
    /// Stash slivers a window is pinned to while its strip position lies beyond them.
    struct Parking {
        var minX: CGFloat?
        var maxX: CGFloat?
        /// Stashes off the window's path (far side edge, top or bottom) it shows at while its strip
        /// position lies half or more past a shared display edge, where macOS would move it to the
        /// neighbor and shrink it.
        var belowMinX: EdgeSwap?
        var aboveMaxX: EdgeSwap?
    }

    struct EdgeSwap {
        let stash: CGPoint
        /// The strip origin x past which half the window lies beyond the shared edge.
        let limitX: CGFloat
    }

    struct Slide {
        let pid: pid_t
        let element: AXElement
        let fromNatural: CGPoint
        let toNatural: CGPoint
        let parking: Parking
        let final: AppDriver.WindowMutation
    }

    private struct Track {
        let pid: pid_t
        let element: AXElement
        var fromNatural: CGPoint
        /// Strip velocity at the slide's start, in points per ms.
        var fromVelocity: CGVector = .zero
        let toNatural: CGPoint
        let parking: Parking
        let final: AppDriver.WindowMutation
    }

    /// Times a window from its first moving step to WindowServer showing it moved, which
    /// includes the app's redraw and commit that an AX round trip does not.
    private struct LandingWatch {
        let pid: pid_t
        let startOrigin: CGPoint
        /// The window started pinned at its stash sliver, so the slide brings it on screen.
        let joining: Bool
        var sentMs: Double?
    }

    /// Longest the clock waits for slow apps to land the first step.
    private static let maxStartHoldMs = 50.0
    /// Longest an app's steps run ahead; past this, the app is too busy for a lead to line it up.
    private static let maxLeadMs = 40.0
    private static let frameMs = 1000.0 / 120.0
    /// How long a running display link may go without a frame before the timer replaces it.
    private static let deadLinkMs = 250
    /// How late a link check may run before it counts as a main-thread stall rather than a check.
    private static let stalledCheckMs = 50.0
    /// Wait before a link that looks silent is dropped.
    private static let confirmSilentMs = 20
    /// How long an app may sit on a slide step before its windows' slots are ghosted.
    private static let ghostLagMs = 30.0

    private let driverFor: (pid_t) -> AppDriver
    /// Runs when a slide finishes and no further slide is pending.
    var onIdle: (() -> Void)?
    /// Runs once, after `onIdle`, when the current slide finishes; a later assignment replaces it.
    var onNextIdle: (() -> Void)?
    /// Runs when a held focus is sent, so its echoes are judged from then.
    var onSettledFocus: ((CGWindowID, pid_t) -> Void)?
    private let ghosts = SlotGhosts()
    private var ghosted: Set<CGWindowID> = []
    /// Ghosts held at their window's final frame until the app's finals drain.
    private var ghostsAwaitingFinals: [pid_t: [CGWindowID]] = [:]

    private var tracks: [CGWindowID: Track] = [:]
    private var startMs: Double = 0
    private var durationMs: Double = 0
    private var holdStartMs: Double?
    private var displayLink: CADisplayLink?
    private var fallbackTimer: DispatchSourceTimer?
    private lazy var linkTarget = DisplayLinkTarget { [weak self] in self?.tick() }
    private var inFlight: Set<pid_t> = []
    private var sentAtMs: [pid_t: Double] = [:]
    /// Smoothed step round trip per app, which sets how far ahead its steps run.
    private var stepLatencyMs: [pid_t: Double] = [:]
    private var landingWatches: [CGWindowID: LandingWatch] = [:]
    private var settledFocus: (pid: pid_t, mutation: AppDriver.WindowMutation)?
    private var pendingFinals: [pid_t: [AppDriver.WindowMutation]] = [:]
    /// Final batches each app's driver is still applying; their resizes block the app's steps.
    private var finalsDraining: [pid_t: Int] = [:]
    private var sentWhileDraining: Set<pid_t> = []
    private var framesThisSlide = 0
    private var linkResumes = 0
    /// Set when a link went silent; slides use the timer until displays change.
    private var linkWentSilent = false
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
        return Self.shown(track, progress: progress(at: Self.nowMs()), durationMs: durationMs)
    }

    /// The window's strip position mid-slide, or nil when not sliding.
    func currentNatural(_ id: CGWindowID) -> CGPoint? {
        guard let track = tracks[id] else { return nil }
        return Self.natural(track, progress: progress(at: Self.nowMs()), durationMs: durationMs)
    }

    /// Starts or retargets slides. Windows already sliding restart from their current strip
    /// position and velocity, so every window shares one clock and the strip moves as a unit.
    /// Duration grows with the longest strip distance, up to twice `baseDurationMs` for a full
    /// screen width.
    func animate(_ slides: [CGWindowID: Slide], baseDurationMs: Double, referenceWidth: Double) {
        let now = Self.nowMs()
        let wasActive = isActive
        let p = progress(at: now)
        var velocities: [CGWindowID: CGVector] = [:]
        for (id, track) in tracks {
            tracks[id]?.fromNatural = Self.natural(track, progress: p, durationMs: durationMs)
            velocities[id] = Self.velocity(track, progress: p, durationMs: durationMs)
        }
        for (id, slide) in slides {
            let track = Track(pid: slide.pid, element: slide.element, fromNatural: slide.fromNatural,
                              toNatural: slide.toNatural, parking: slide.parking, final: slide.final)
            // Watch windows starting from rest, including ones a retarget releases from their sliver.
            // The loop above restarted existing tracks from their current position, so progress 0 is now.
            if tracks[id].map(Self.isPinnedAtStart) ?? true, landingWatches[id] == nil {
                landingWatches[id] = LandingWatch(pid: slide.pid,
                                                  startOrigin: Self.shown(track, progress: 0, durationMs: 0),
                                                  joining: Self.isPinnedAtStart(track))
            }
            tracks[id] = track
        }
        // The new slide carries its own finals; a held focus waiting on the old one still applies.
        for pid in pendingFinals.keys {
            pendingFinals[pid] = pendingFinals[pid]?.compactMap { slides[$0.windowID] == nil ? $0 : $0.focusOnly }
        }

        let longest = tracks.values.map {
            hypot($0.toNatural.x - $0.fromNatural.x, $0.toNatural.y - $0.fromNatural.y)
        }.max() ?? 0
        durationMs = baseDurationMs * (1 + min(1, longest / max(1, referenceWidth)))
        startMs = now
        for (id, velocity) in velocities {
            guard let track = tracks[id] else { continue }
            tracks[id]?.fromVelocity = Self.carriedVelocity(velocity, track: track, durationMs: durationMs)
        }

        guard !wasActive else { return }
        // A fresh slide (not a retarget) sends its first step now and holds the clock until it lands.
        framesThisSlide = 0
        holdMsThisSlide = 0
        holdStartMs = now
        sendSteps(at: now)
        resumeFrames()
    }

    /// Holds a focus until the strip settles; a later press replaces it, so a fast run
    /// activates only the window it lands on.
    func focusWhenSettled(_ mutation: AppDriver.WindowMutation, pid: pid_t) {
        settledFocus = (pid, mutation)
    }

    /// Stops in-flight slides for `windowIDs` without running their final mutations, so direct
    /// position writes (such as a pan) take over immediately. A focus held for the strip to
    /// settle is sent now, since AppDriver already expects it.
    func cancel(windowIDs: Set<CGWindowID>) {
        let wasActive = isActive
        for id in windowIDs {
            tracks.removeValue(forKey: id)
            landingWatches.removeValue(forKey: id)
        }
        let cancelledGhosts = ghosted.intersection(windowIDs)
        ghosted.subtract(cancelledGhosts)
        ghosts.hide(Array(cancelledGhosts))
        if let focus = settledFocus, windowIDs.contains(focus.mutation.windowID) {
            settledFocus = nil
            if let focusOnly = focus.mutation.focusOnly {
                if inFlight.contains(focus.pid) {
                    pendingFinals[focus.pid, default: []].append(focusOnly)
                } else {
                    enqueueFinals([focusOnly], pid: focus.pid)
                }
                onSettledFocus?(focus.mutation.windowID, focus.pid)
            }
        }
        if wasActive && !isActive {
            pauseFrames()
            holdStartMs = nil
            onIdle?()
        }
    }

    private func resumeFrames() {
        lastTickMs = nil
        if displayLink == nil, fallbackTimer == nil, !linkWentSilent,
           let link = NSScreen.main?.displayLink(target: linkTarget, selector: #selector(DisplayLinkTarget.step(_:))) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        if let link = displayLink {
            link.isPaused = false
            linkResumes += 1
            watchLink(resume: linkResumes, since: Self.nowMs())
            return
        }
        startFallbackTimer()
    }

    private func startFallbackTimer() {
        guard fallbackTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .microseconds(Int(Self.frameMs * 1000)), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        fallbackTimer = t
        t.resume()
    }

    /// Drops the display link: a link stops ticking once its display is removed or asleep, and a
    /// slide waiting on it never ends. A running slide continues on the timer; the next slide links
    /// to the display that is main then.
    func displaysChanged() {
        linkWentSilent = false
        dropDisplayLink()
    }

    private func dropDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        if isActive { startFallbackTimer() }
    }

    /// Checks the running link every `deadLinkMs` until the slide ends. A link silent that long
    /// belongs to a display that is gone or asleep; slides use the timer until displays change.
    /// A check that runs late means the main thread stalled, which holds the link's frames too, so
    /// it checks again instead of judging the link.
    private func watchLink(resume: Int, since startMs: Double) {
        let dueMs = Self.nowMs() + Double(Self.deadLinkMs)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.deadLinkMs)) { [weak self] in
            guard let self, resume == self.linkResumes, self.isActive, self.displayLink != nil else { return }
            guard Self.nowMs() - dueMs <= Self.stalledCheckMs else {
                self.watchLink(resume: resume, since: startMs)
                return
            }
            let silentMs = Self.nowMs() - (self.lastTickMs ?? startMs)
            guard silentMs >= Double(Self.deadLinkMs) else {
                self.watchLink(resume: resume, since: startMs)
                return
            }
            self.confirmLinkSilent(resume: resume, since: startMs, lastTick: self.lastTickMs)
        }
    }

    /// A stall that began just after a frame can still look like silence on time; a live link's
    /// queued frame runs before this second look.
    private func confirmLinkSilent(resume: Int, since startMs: Double, lastTick: Double?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.confirmSilentMs)) { [weak self] in
            guard let self, resume == self.linkResumes, self.isActive, self.displayLink != nil else { return }
            guard self.lastTickMs == lastTick else {
                self.watchLink(resume: resume, since: startMs)
                return
            }
            let silentMs = Self.nowMs() - (lastTick ?? startMs)
            RibbonLog.log("display link silent \(Int(silentMs))ms; using timer", category: "slide")
            self.linkWentSilent = true
            self.dropDisplayLink()
        }
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
            // Apps still applying the last slide's resizes cannot land a step soon; the strip starts without them.
            let landed = inFlight.allSatisfy { finalsDraining[$0] != nil }
            guard landed || now - holdStart >= Self.maxStartHoldMs else { return }
            // Resume the clock from the first step's progress, as if it had just been shown.
            holdStartMs = nil
            holdMsThisSlide = now - holdStart
            startMs = now - Self.frameMs
        }

        checkLandings(at: now)
        sendSteps(at: now)
        showGhosts(at: now)
        if progress(at: now) >= 1 {
            finish()
        }
    }

    private func sendSteps(at nowMs: Double) {
        var tracksByPID: [pid_t: [(CGWindowID, Track)]] = [:]
        for (id, track) in tracks where !inFlight.contains(track.pid) {
            tracksByPID[track.pid, default: []].append((id, track))
        }
        for (pid, pidTracks) in tracksByPID {
            let p = progress(at: nowMs + leadMs(pid))
            let steps = pidTracks.map { id, track in
                let origin = Self.shown(track, progress: p, durationMs: durationMs)
                if let watch = landingWatches[id], watch.sentMs == nil,
                   hypot(origin.x - watch.startOrigin.x, origin.y - watch.startOrigin.y) > 1 {
                    landingWatches[id]?.sentMs = nowMs
                }
                return AppDriver.SlideStep(element: track.element, windowID: id, origin: origin)
            }
            send(steps, to: pid)
        }
    }

    /// Ghosts the slot of each window whose app has sat on its step past the lag; a ghosted window
    /// keeps its ghost until the slide ends, so steps landing between lags do not flicker it.
    private func showGhosts(at nowMs: Double) {
        let p = progress(at: nowMs)
        for (id, track) in tracks {
            let lagging = sentAtMs[track.pid].map { nowMs - $0 >= Self.ghostLagMs } ?? false
            guard lagging || ghosted.contains(id) else { continue }
            ghosted.insert(id)
            let origin = Self.shown(track, progress: p, durationMs: durationMs)
            ghosts.show(id, frame: CGRect(origin: origin, size: track.final.frame.size))
        }
    }

    /// Logs when WindowServer first shows each watched window off its start position.
    private func checkLandings(at nowMs: Double) {
        let sent = landingWatches.filter { $0.value.sentMs != nil }
        guard !sent.isEmpty else { return }
        // The window list API takes CGWindowIDs packed as raw pointer values.
        var ids = sent.keys.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let idArray = CFArrayCreate(nil, &ids, ids.count, nil),
              let infos = CGWindowListCreateDescriptionFromArray(idArray) as? [NSDictionary] else { return }
        for info in infos {
            guard let num = info[kCGWindowNumber as String] as? NSNumber,
                  let watch = sent[num.uint32Value], let sentMs = watch.sentMs,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let moved = hypot(bounds.origin.x - watch.startOrigin.x, bounds.origin.y - watch.startOrigin.y) > 1
            guard moved || nowMs - sentMs > 500 else { continue }
            landingWatches.removeValue(forKey: num.uint32Value)
            logLanding(id: num.uint32Value, watch, result: moved ? "\(Int(nowMs - sentMs))ms" : "none in 500ms")
        }
    }

    private func logLanding(id: CGWindowID, _ watch: LandingWatch, result: String) {
        RibbonLog.log(
            "landing pid=\(watch.pid) wid=\(id) joining=\(watch.joining) \(result) stepRTT=\(Int(stepLatencyMs[watch.pid] ?? 0))ms",
            category: "slide"
        )
    }

    private func leadMs(_ pid: pid_t) -> Double {
        min(Self.maxLeadMs, stepLatencyMs[pid] ?? 0)
    }

    private func finish() {
        let leads = Set(tracks.values.map(\.pid))
            .filter { leadMs($0) >= 2 }
            .sorted()
            .map { "\($0):\(Int(leadMs($0)))ms" }
        RibbonLog.log(
            "slide done windows=\(tracks.count) duration=\(Int(durationMs))ms frames=\(framesThisSlide) hold=\(Int(holdMsThisSlide))ms clock=\(displayLink != nil ? "display" : "timer") lead=[\(leads.joined(separator: " "))]",
            category: "slide"
        )
        pauseFrames()
        holdStartMs = nil
        let now = Self.nowMs()
        checkLandings(at: now)
        for (id, watch) in landingWatches {
            guard let sentMs = watch.sentMs else { continue }
            let inFlight = sentAtMs[watch.pid].map { "\(Int(now - $0))ms" } ?? "no"
            logLanding(id: id, watch, result: "none by slide end (\(Int(now - sentMs))ms) stepInFlight=\(inFlight)")
        }
        landingWatches.removeAll()
        for id in ghosted {
            guard let track = tracks[id] else { continue }
            ghosts.show(id, frame: track.final.frame)
            ghostsAwaitingFinals[track.pid, default: []].append(id)
        }
        ghosted.removeAll()
        var finalsByPID: [pid_t: [AppDriver.WindowMutation]] = [:]
        for track in tracks.values {
            finalsByPID[track.pid, default: []].append(track.final)
        }
        tracks.removeAll()
        // After the window's final in the same batch, so AppDriver merges them into one mutation.
        if let focus = settledFocus {
            settledFocus = nil
            finalsByPID[focus.pid, default: []].append(focus.mutation)
            onSettledFocus?(focus.mutation.windowID, focus.pid)
        }
        for (pid, finals) in finalsByPID {
            if inFlight.contains(pid) {
                pendingFinals[pid, default: []].append(contentsOf: finals)
            } else {
                enqueueFinals(finals, pid: pid)
            }
        }
        onIdle?()
        let next = onNextIdle
        onNextIdle = nil
        next?()
    }

    /// Marks the app busy until its driver drains, so a slide starting meanwhile does not wait on it.
    private func enqueueFinals(_ finals: [AppDriver.WindowMutation], pid: pid_t) {
        finalsDraining[pid, default: 0] += 1
        let driver = driverFor(pid)
        Task { [weak self] in
            await driver.enqueue(finals)
            DispatchQueue.main.async {
                guard let self else { return }
                self.finalsDraining[pid, default: 1] -= 1
                if self.finalsDraining[pid] == 0 {
                    self.finalsDraining.removeValue(forKey: pid)
                    // A window a newer slide ghosts again keeps its ghost.
                    let held = self.ghostsAwaitingFinals.removeValue(forKey: pid) ?? []
                    self.ghosts.hide(held.filter { !self.ghosted.contains($0) })
                }
            }
        }
    }

    private func send(_ steps: [AppDriver.SlideStep], to pid: pid_t) {
        inFlight.insert(pid)
        sentAtMs[pid] = Self.nowMs()
        if finalsDraining[pid] != nil { sentWhileDraining.insert(pid) }
        let driver = driverFor(pid)
        Task { [weak self] in
            await driver.slide(steps)
            DispatchQueue.main.async { self?.stepLanded(pid: pid) }
        }
    }

    private func stepLanded(pid: pid_t) {
        inFlight.remove(pid)
        let queuedBehindFinals = sentWhileDraining.remove(pid) != nil
        if let sent = sentAtMs.removeValue(forKey: pid) {
            let roundTrip = Self.nowMs() - sent
            if roundTrip > 40 {
                RibbonLog.log("slow step pid=\(pid) blocked \(Int(roundTrip))ms\(queuedBehindFinals ? " behind finals" : "")",
                              category: "slide")
            }
            // A step queued behind a resize measures the resize, not the app's step latency.
            if !queuedBehindFinals {
                stepLatencyMs[pid] = stepLatencyMs[pid].map { $0 * 0.7 + roundTrip * 0.3 } ?? roundTrip
            }
        }
        guard let finals = pendingFinals.removeValue(forKey: pid), !finals.isEmpty else { return }
        enqueueFinals(finals, pid: pid)
    }

    /// While holding, progress stays at the first step so retargets and lookups agree with it.
    private func progress(at nowMs: Double) -> Double {
        guard durationMs > 0 else { return 1 }
        if holdStartMs != nil { return min(1, Self.frameMs / durationMs) }
        return min(1, max(0, (nowMs - startMs) / durationMs))
    }

    /// Cubic Hermite from the start position and velocity to rest at the target. From rest it is
    /// the smoothstep ease-in-out; with a carried velocity the strip glides on without stopping.
    private static func hermite(from: Double, velocity: Double, to: Double, t: Double, durationMs: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * from + (t3 - 2 * t2 + t) * durationMs * velocity + (3 * t2 - 2 * t3) * to
    }

    /// The Hermite curve's slope, in points per ms.
    private static func hermiteSlope(from: Double, velocity: Double, to: Double, t: Double, durationMs: Double) -> Double {
        guard durationMs > 0 else { return 0 }
        let t2 = t * t
        return ((6 * t2 - 6 * t) * from + (3 * t2 - 4 * t + 1) * durationMs * velocity + (6 * t - 6 * t2) * to) / durationMs
    }

    private static func natural(_ track: Track, progress: Double, durationMs: Double) -> CGPoint {
        CGPoint(
            x: hermite(from: track.fromNatural.x, velocity: track.fromVelocity.dx, to: track.toNatural.x,
                       t: progress, durationMs: durationMs),
            y: hermite(from: track.fromNatural.y, velocity: track.fromVelocity.dy, to: track.toNatural.y,
                       t: progress, durationMs: durationMs)
        )
    }

    private static func velocity(_ track: Track, progress: Double, durationMs: Double) -> CGVector {
        CGVector(
            dx: hermiteSlope(from: track.fromNatural.x, velocity: track.fromVelocity.dx, to: track.toNatural.x,
                             t: progress, durationMs: durationMs),
            dy: hermiteSlope(from: track.fromNatural.y, velocity: track.fromVelocity.dy, to: track.toNatural.y,
                             t: progress, durationMs: durationMs)
        )
    }

    /// The share of a retargeted window's velocity that carries into its new slide, per axis.
    /// Motion away from the new target stops (a reversal), and speed is capped where the curve
    /// would overshoot the target (a Hermite to rest stays monotonic while v * T <= 3 * distance).
    private static func carriedVelocity(_ v: CGVector, track: Track, durationMs: Double) -> CGVector {
        func carry(_ v: Double, distance: Double) -> Double {
            guard durationMs > 0, v * distance > 0 else { return 0 }
            let cap = 3 * abs(distance) / durationMs
            return min(abs(v), cap) * (v < 0 ? -1 : 1)
        }
        return CGVector(dx: carry(v.dx, distance: track.toNatural.x - track.fromNatural.x),
                        dy: carry(v.dy, distance: track.toNatural.y - track.fromNatural.y))
    }

    /// True when the track starts held at a stash sliver rather than at its strip position.
    private static func isPinnedAtStart(_ track: Track) -> Bool {
        abs(shown(track, progress: 0, durationMs: 0).x - track.fromNatural.x.rounded()) > 1
    }

    /// The strip position pinned at the window's stash slivers, or its top/bottom stash past a shared edge.
    private static func shown(_ track: Track, progress: Double, durationMs: Double) -> CGPoint {
        var p = natural(track, progress: progress, durationMs: durationMs)
        if let swap = track.parking.belowMinX, p.x < swap.limitX { return swap.stash }
        if let swap = track.parking.aboveMaxX, p.x > swap.limitX { return swap.stash }
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
