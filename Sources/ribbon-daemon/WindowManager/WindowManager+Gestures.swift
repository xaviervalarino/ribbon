import AppKit
import CoreGraphics

// MARK: - Gestures

extension WindowManager {
    func setTouchesProbe(_ on: Bool) {
        touchesProbe.bucketTimer?.cancel()
        touchesProbe.bucketTimer = nil
        touchesProbe.endWork?.cancel()
        touchesProbe.endWork = nil

        if !on {
            if touchesProbe.isArmed {
                flushTouchesProbeBucket()
                touchesProbe = TouchesProbeState()
                updateGestureTap()
                RibbonLog.log("touches probe off", category: "input")
            }
            return
        }

        flushTouchesProbeBucket()
        touchesProbe = TouchesProbeState(isArmed: true)
        updateGestureTap()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.flushTouchesProbeBucket()
        }
        timer.resume()
        touchesProbe.bucketTimer = timer

        let endWork = DispatchWorkItem { [weak self] in
            self?.setTouchesProbe(false)
        }
        touchesProbe.endWork = endWork
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(10), execute: endWork)
    }

    private func flushTouchesProbeBucket() {
        guard touchesProbe.events > 0 || touchesProbe.swipes > 0 else { return }
        let dxText = String(format: "%.3f", touchesProbe.dx)
        RibbonLog.log(
            "touches=\(touchesProbe.maxTouches) events=\(touchesProbe.events) dx=\(dxText) swipes=\(touchesProbe.swipes) swipeDX=\(touchesProbe.swipeDX)",
            category: "input"
        )
        touchesProbe.maxTouches = 0
        touchesProbe.events = 0
        touchesProbe.dx = 0
        touchesProbe.swipes = 0
        touchesProbe.swipeDX = 0
    }

    /// The gesture tap runs while native swipe is on (`swipeFingers > 0`) or the touches probe is
    /// armed. Each call recreates it, which also restores touch data after sleep.
    func updateGestureTap() {
        // A recreated tap may have missed the lift that ended the last gesture.
        lastTouch = nil
        swipeStepper = SwipeStepper()
        if config.swipeFingers > 0 || touchesProbe.isArmed {
            gestureTap.start()
        } else {
            gestureTap.stop()
        }
    }

    func gesture(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        // "indirect" touches are the trackpad's; "direct" ones are the Touch Bar's.
        let touches = nsEvent.touches(matching: .touching, in: nil).filter { $0.type == .indirect }
        let count = touches.count
        let sum = touches.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.normalizedPosition.x, y: $0.y + $1.normalizedPosition.y)
        }
        // Travel summed over fingers, measured only between events with the same finger count.
        var travel = CGVector.zero
        if count > 0, let last = lastTouch, last.count == count {
            travel = CGVector(dx: sum.x - last.sum.x, dy: sum.y - last.sum.y)
        }
        lastTouch = count > 0 ? (count, sum) : nil

        if touchesProbe.isArmed {
            if count > 0 {
                touchesProbe.dx += travel.dx / Double(count)
            }
            touchesProbe.events += 1
            touchesProbe.maxTouches = max(touchesProbe.maxTouches, count)
        }

        guard config.swipeFingers > 0,
              let step = swipeStepper.feed(fingers: count, dx: travel.dx, dy: travel.dy, config: config) else { return }
        let command = step == .focusLeft ? "focus left" : "focus right"
        RibbonLog.log("swipe step: \(command)", category: "input")
        _ = handleCommand(command)
    }

    func swipe(_ event: CGEvent) {
        guard touchesProbe.isArmed, let nsEvent = NSEvent(cgEvent: event) else { return }
        touchesProbe.swipes += 1
        touchesProbe.swipeDX += Double(nsEvent.deltaX)
    }
}
