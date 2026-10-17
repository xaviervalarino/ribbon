import Foundation
import AppKit
import CoreGraphics

/// One-off measurements that need Ribbon.app's TCC grants (Accessibility, Screen Recording).
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
        case "capture":
            guard CGPreflightScreenCaptureAccess() else {
                _ = CGRequestScreenCaptureAccess()
                return "needs Screen Recording: enable Ribbon in System Settings > Privacy & Security > Screen & System Audio Recording, then `ribbon restart`"
            }
            return start("capture", CaptureProbe.run)
        case "ax-latency":
            return start("ax-latency") { AXLatencyProbe.run(targets) }
        default:
            return "error: debug probes: capture, ax-latency"
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

/// Measures capture of other apps' windows (visible, partial, parked) for the curtain idea.
/// Records stats only; never saves window images.
enum CaptureProbe {
    private typealias MainCID = @convention(c) () -> Int32
    private typealias HWCapture = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?
    private typealias CGWLCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private struct Win {
        let id: CGWindowID
        let owner: String
        let frame: CGRect
    }

    static func run() -> [String] {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let cidSym = dlsym(sky, "SLSMainConnectionID"),
              let hwSym = dlsym(sky, "SLSHWCaptureWindowList"),
              let cgSym = dlsym(cg, "CGWindowListCreateImage") else {
            return ["error: capture symbols unavailable"]
        }
        let cid = unsafeBitCast(cidSym, to: MainCID.self)()
        let hwCapture = unsafeBitCast(hwSym, to: HWCapture.self)
        // CGWindowListCreateImage is unavailable to Swift on macOS 15+ but still exported.
        let cgCreateImage = unsafeBitCast(cgSym, to: CGWLCreateImage.self)

        func slsCapture(_ ids: [CGWindowID]) -> [CGImage] {
            var ids = ids
            guard let arr = hwCapture(cid, &ids, Int32(ids.count), (1 << 11) | (1 << 8))?.takeRetainedValue() else { return [] }
            return (arr as? [CGImage]) ?? []
        }

        func cgCapture(_ id: CGWindowID) -> CGImage? {
            // kCGWindowListOptionIncludingWindow; BoundsIgnoreFraming | BestResolution
            cgCreateImage(.null, 1 << 3, id, (1 << 0) | (1 << 3))?.takeRetainedValue()
        }

        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map {
            QuartzGeometry.toQuartzRect(cocoaFrame: $0.frame, primaryScreenHeight: Double(primaryH)).cgRect
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let wins: [Win] = info.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  (d[kCGWindowOwnerPID as String] as? Int32) != me,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 50, r.height > 50 else { return nil }
            return Win(id: id, owner: d[kCGWindowOwnerName as String] as? String ?? "?", frame: r)
        }

        func visibleFraction(_ r: CGRect) -> Double {
            let visible = screens.reduce(0.0) { acc, s in
                let i = r.intersection(s)
                return acc + (i.isNull ? 0 : Double(i.width * i.height))
            }
            return visible / Double(r.width * r.height)
        }

        var lines = [
            "capture probe \(Date()) — \(wins.count) other-app windows",
            "kind | owner | wid | frame | method | image px | expected px | opaque | capture+pixels ms (median of 10)",
        ]
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)

        for w in wins {
            let vf = visibleFraction(w.frame)
            let kind = vf > 0.99 ? "visible" : (vf < 0.05 ? "parked" : "partial")
            let expected = "\(Int(w.frame.width * scale))x\(Int(w.frame.height * scale))"
            let frame = "(\(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height)))"

            func measure(_ method: String, _ capture: () -> CGImage?) {
                var times: [Double] = []
                var size = "none"
                var opaque = 0.0
                for _ in 0..<10 {
                    let t0 = DebugProbes.nowMs()
                    if let img = capture() {
                        opaque = materialize(img)
                        size = "\(img.width)x\(img.height)"
                    }
                    times.append(DebugProbes.nowMs() - t0)
                }
                lines.append("\(kind) | \(w.owner) | \(w.id) | \(frame) | \(method) | \(size) | \(expected) | \(String(format: "%.2f", opaque)) | \(String(format: "%.1f", DebugProbes.median(times)))")
            }
            measure("SLS") { slsCapture([w.id]).first }
            measure("CG") { cgCapture(w.id) }
        }

        // What one scroll would capture: up to 5 windows in one SLS call.
        let batch = wins.prefix(5).map(\.id)
        if !batch.isEmpty {
            var times: [Double] = []
            for _ in 0..<10 {
                let t0 = DebugProbes.nowMs()
                for img in slsCapture(batch) { _ = materialize(img) }
                times.append(DebugProbes.nowMs() - t0)
            }
            lines.append("batch | SLS one call, \(batch.count) windows | capture+pixels median ms: \(String(format: "%.1f", DebugProbes.median(times)))")
        }

        // Floor: the same pixel work on an image already in memory.
        if let w = wins.first, let img = cgCapture(w.id) {
            var times: [Double] = []
            for _ in 0..<10 {
                let t0 = DebugProbes.nowMs()
                _ = materialize(img)
                times.append(DebugProbes.nowMs() - t0)
            }
            lines.append("floor | re-materialize captured \(img.width)x\(img.height) | median ms: \(String(format: "%.1f", DebugProbes.median(times)))")
        }
        return lines
    }

    /// Draws the image into a bitmap (the pixel work a layer upload needs) and
    /// returns the sampled fraction of non-transparent pixels.
    private static func materialize(_ img: CGImage) -> Double {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var opaque = 0, samples = 0
        var i = 3
        while i < w * h * 4 {
            if px[i] > 0 { opaque += 1 }
            samples += 1
            i += 4 * 97
        }
        return samples == 0 ? 0 : Double(opaque) / Double(samples)
    }
}
