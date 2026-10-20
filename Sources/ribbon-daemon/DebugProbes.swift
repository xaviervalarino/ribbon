import Foundation
import AppKit
import CoreGraphics

/// One-off measurements that need Ribbon.app's Accessibility grant.
/// Probes run off the main thread and write results to `/tmp/ribbon-debug-<name>.txt`.
enum DebugProbes {
    struct Target {
        let id: CGWindowID
        let pid: pid_t
        let app: String
        let element: AXElement
    }

    static func run(_ args: [String], targets: [Target]) -> String {
        switch args.first?.lowercased() {
        case "ax-latency":
            return start("ax-latency") { AXLatencyProbe.run(targets) }
        default:
            return "error: debug probes: ax-latency"
        }
    }

    private static func start(_ name: String, _ body: @escaping () -> [String]) -> String {
        let path = "/tmp/ribbon-debug-\(name).txt"
        try? "running\n".write(toFile: path, atomically: true, encoding: .utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = body()
            try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        return "started; results in \(path)"
    }

    static let axTimeout = AppDriver.defaultTimeoutSeconds

    static func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    static func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    /// WindowServer's view of a window's bounds (no app IPC).
    static func serverBounds(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }
}

/// Times AX position reads and writes per app, and how long each move takes to land in
/// WindowServer's bounds. Writes nudge each on-screen window 20pt and back, so windows
/// jitter visibly while it runs.
enum AXLatencyProbe {
    private static let reps = 10

    static func run(_ targets: [DebugProbes.Target]) -> [String] {
        var lines = [
            "ax-latency probe \(Date()) — \(targets.count) on-screen ribbon windows, \(reps) reps each",
            "app | wid | read ms | write same ms | write moved ms | landed in WindowServer ms | timeouts | write errors (medians)",
        ]
        var movedByApp: [String: [Double]] = [:]
        var landedByApp: [String: [Double]] = [:]
        var resizeCallsByApp: [String: [Double]] = [:]
        var resizeLandedByApp: [String: [Double]] = [:]

        for t in targets {
            _ = t.element.setMessagingTimeout(DebugProbes.axTimeout)
            guard let origin = t.element.position else {
                lines.append("\(t.app) | \(t.id) | position unreadable")
                continue
            }
            var reads: [Double] = [], same: [Double] = [], moved: [Double] = [], landed: [Double] = []
            var errors = Set<Int32>()
            var timeouts = 0

            /// Polls WindowServer bounds until the window's x matches; returns ms since `t0`, or nil after 250ms.
            func waitForServerX(_ x: CGFloat, since t0: Double) -> Double? {
                while DebugProbes.nowMs() - t0 < 250 {
                    if let b = DebugProbes.serverBounds(t.id), abs(b.minX - x) < 0.5 {
                        return DebugProbes.nowMs() - t0
                    }
                    usleep(200)
                }
                return nil
            }

            func moveAndLand(_ p: CGPoint) {
                let t0 = DebugProbes.nowMs()
                moved.append(write(p))
                if let dt = waitForServerX(p.x, since: t0) { landed.append(dt) } else { timeouts += 1 }
            }

            func write(_ p: CGPoint) -> Double {
                var point = p
                let value = AXValueCreate(.cgPoint, &point)!
                let t0 = DebugProbes.nowMs()
                let err = AXUIElementSetAttributeValue(t.element.rawElement, kAXPositionAttribute as CFString, value)
                let dt = DebugProbes.nowMs() - t0
                if err != .success { errors.insert(err.rawValue) }
                return dt
            }

            for _ in 0..<reps {
                let t0 = DebugProbes.nowMs()
                _ = t.element.position
                reads.append(DebugProbes.nowMs() - t0)
                same.append(write(origin))
                moveAndLand(CGPoint(x: origin.x + 20, y: origin.y))
                moveAndLand(origin)
            }

            // Resize: shrink 40pt and restore; the app re-lays out and redraws at each size.
            var resizeCalls: [Double] = [], resizeLanded: [Double] = []
            var resizeTimeouts = 0
            if let size = t.element.size {
                func resizeAndLand(_ width: CGFloat) {
                    let t0 = DebugProbes.nowMs()
                    t.element.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: size.height)))
                    resizeCalls.append(DebugProbes.nowMs() - t0)
                    while DebugProbes.nowMs() - t0 < 250 {
                        if let b = DebugProbes.serverBounds(t.id), abs(b.width - width) < 0.5 {
                            resizeLanded.append(DebugProbes.nowMs() - t0)
                            return
                        }
                        usleep(200)
                    }
                    resizeTimeouts += 1
                }
                for _ in 0..<(reps / 2) {
                    resizeAndLand(size.width - 40)
                    resizeAndLand(size.width)
                }
            }
            resizeCallsByApp[t.app, default: []].append(contentsOf: resizeCalls)
            resizeLandedByApp[t.app, default: []].append(contentsOf: resizeLanded)
            let resizeText = resizeLanded.isEmpty ? "never" : "\(fmt(resizeCalls)) / \(fmt(resizeLanded)) (\(resizeTimeouts) timeouts)"

            movedByApp[t.app, default: []].append(contentsOf: moved)
            landedByApp[t.app, default: []].append(contentsOf: landed)
            let errText = errors.isEmpty ? "none" : errors.sorted().map(String.init).joined(separator: ",")
            let landedText = landed.isEmpty ? "never" : fmt(landed)
            lines.append("\(t.app) | \(t.id) | \(fmt(reads)) | \(fmt(same)) | \(fmt(moved)) | \(landedText) | \(timeouts)/\(reps * 2) | \(errText) | resize call/landed \(resizeText)")
        }

        lines.append("per app (call returned → WindowServer bounds updated): " + landedByApp.keys.sorted().map { app in
            let xs = landedByApp[app]!.sorted()
            guard !xs.isEmpty else { return "\(app) never landed" }
            return "\(app) median \(String(format: "%.1f", DebugProbes.median(xs))) p90 \(String(format: "%.1f", xs[xs.count * 9 / 10]))"
        }.joined(separator: "; "))
        lines.append("per app resize (call / landed, median): " + resizeLandedByApp.keys.sorted().map { app in
            let landed = resizeLandedByApp[app]!
            guard !landed.isEmpty else { return "\(app) never landed" }
            return "\(app) \(fmt(resizeCallsByApp[app]!)) / \(fmt(landed))ms (~\(Int(1000 / DebugProbes.median(landed)))fps)"
        }.joined(separator: "; "))
        lines.append("per app (write call only): " + movedByApp.keys.sorted().map { app in
            let xs = movedByApp[app]!.sorted()
            return "\(app) median \(String(format: "%.1f", DebugProbes.median(xs))) p90 \(String(format: "%.1f", xs[xs.count * 9 / 10]))"
        }.joined(separator: "; "))
        return lines
    }

    private static func fmt(_ xs: [Double]) -> String { String(format: "%.2f", DebugProbes.median(xs)) }
}
