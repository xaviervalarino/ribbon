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
        if panController.isScrubbing { panController.endPan(snap: true) }
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

        guard config.swipeFingers > 0 else { return }
        if config.swipeMode == .follow {
            scrub(fingers: count, travel: travel, time: nsEvent.timestamp)
            return
        }
        guard let step = swipeStepper.feed(fingers: count, dx: travel.dx, dy: travel.dy, config: config) else { return }
        // Overview, the screenshot grid and a caps pan move focus their own way; their edges run nothing.
        let ribbon = ribbons[currentActiveSpaceID()] ?? Ribbon()
        let atEdge = ribbon.isAtEdge(step.direction)
            && !ribbon.isOverview && !screenshotGrid.isOpen && !panController.isPanning
        switch swipeStepper.resolve(step, atEdge: atEdge, config: config) {
        case .focus:
            let command = step == .focusLeft ? "focus left" : "focus right"
            RibbonLog.log("swipe step: \(command)", category: "input")
            _ = handleCommand(command)
        case .edge:
            runEdgeCommand(step)
        case nil:
            if atEdge && config.swipeEdgeSteps > 0 {
                RibbonLog.log("swipe edge push: \(step.direction)", category: "input")
            }
        }
    }

    private func scrub(fingers: Int, travel: CGVector, time: Double) {
        switch swipeStepper.feedScrub(fingers: fingers, dx: travel.dx, dy: travel.dy, config: config) {
        case .move(let fraction):
            guard !screenshotGrid.isOpen else { return }
            panController.scrub(fraction: fraction, time: time)
        case .end:
            if let edge = panController.liftScrub(time: time) {
                runEdgeCommand(edge)
            }
        case nil:
            break
        }
    }

    /// Runs the command for the edge a swipe pushed past, program first, off the main thread.
    private func runEdgeCommand(_ edge: SwipeStepper.Step) {
        let argv = edge == .focusLeft ? config.swipeLeftEdgeCommand : config.swipeRightEdgeCommand
        guard let program = argv.first else { return }
        RibbonLog.log("swipe edge command: \(argv.joined(separator: " "))", category: "input")
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = Array(argv.dropFirst())
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                RibbonLog.log("swipe edge command failed: \(error)", category: "input")
            }
        }
    }

    func swipe(_ event: CGEvent) {
        guard touchesProbe.isArmed, let nsEvent = NSEvent(cgEvent: event) else { return }
        touchesProbe.swipes += 1
        touchesProbe.swipeDX += Double(nsEvent.deltaX)
    }
}
