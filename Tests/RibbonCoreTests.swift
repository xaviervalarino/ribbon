import Foundation
import CoreGraphics

// Simple test harness that runs without requiring external test runners
public enum TestRunner {
    private static var failures: Int = 0
    private static var passes: Int = 0

    public static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #file, line: Int = #line) {
        if actual == expected {
            passes += 1
        } else {
            failures += 1
            let baseFile = (file as NSString).lastPathComponent
            print("❌ FAIL [\(baseFile):\(line)]: expected \(expected), got \(actual). \(message)")
        }
    }

    public static func assertTrue(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
        if condition {
            passes += 1
        } else {
            failures += 1
            let baseFile = (file as NSString).lastPathComponent
            print("❌ FAIL [\(baseFile):\(line)]: expected true. \(message)")
        }
    }

    public static func assertFalse(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
        if !condition {
            passes += 1
        } else {
            failures += 1
            let baseFile = (file as NSString).lastPathComponent
            print("❌ FAIL [\(baseFile):\(line)]: expected false. \(message)")
        }
    }

    public static func summary() -> Bool {
        print("\n================ Test Summary ================")
        print("Passed: \(passes) | Failed: \(failures)")
        print("==============================================")
        return failures == 0
    }
}

func runTests() {
    print("Running QuartzGeometry and LayoutEngine tests...")

    // 1. QuartzPoint & QuartzSize
    let p1 = QuartzPoint(x: 10, y: 20)
    TestRunner.assertEqual(p1.cgPoint, CGPoint(x: 10, y: 20), "QuartzPoint to CGPoint")
    let s1 = QuartzSize(width: 800, height: 600)
    TestRunner.assertEqual(s1.cgSize, CGSize(width: 800, height: 600), "QuartzSize to CGSize")

    // 2. QuartzRect Basic Geometry
    let r1 = QuartzRect(x: 100, y: 50, width: 400, height: 300)
    TestRunner.assertEqual(r1.minX, 100.0)
    TestRunner.assertEqual(r1.maxX, 500.0)
    TestRunner.assertEqual(r1.minY, 50.0)
    TestRunner.assertEqual(r1.maxY, 350.0)
    TestRunner.assertEqual(r1.midX, 300.0)
    TestRunner.assertEqual(r1.midY, 200.0)
    TestRunner.assertEqual(r1.area, 120000.0)

    // 3. QuartzRect Intersection & Containment
    let r2 = QuartzRect(x: 300, y: 200, width: 400, height: 300)
    TestRunner.assertTrue(r1.intersects(r2), "r1 should intersect r2")
    let inter = r1.intersection(r2)!
    TestRunner.assertEqual(inter, QuartzRect(x: 300, y: 200, width: 200, height: 150), "Intersection rect")

    let rDisjoint = QuartzRect(x: 600, y: 50, width: 100, height: 100)
    TestRunner.assertFalse(r1.intersects(rDisjoint), "Disjoint rects should not intersect")
    TestRunner.assertEqual(r1.intersection(rDisjoint), nil, "Disjoint intersection is nil")

    // 4. Inset & Offset
    let inset = r1.insetBy(dx: 10, dy: 10)
    TestRunner.assertEqual(inset, QuartzRect(x: 110, y: 60, width: 380, height: 280), "Inset rect")

    // 5. Single Monitor Cocoa <-> Quartz Conversion
    // Primary screen: 1920 x 1080.
    // Menu bar (25pt at top) + Dock (60pt at bottom):
    // Cocoa frame: origin (0, 60), size (1920, 995)
    let cocoaFrame = CGRect(x: 0, y: 60, width: 1920, height: 995)
    let quartzFrame = QuartzGeometry.toQuartzRect(cocoaFrame: cocoaFrame, primaryScreenHeight: 1080)
    // In Quartz: y = 1080 - (60 + 995) = 25 (menu bar offset)
    TestRunner.assertEqual(quartzFrame.x, 0.0)
    TestRunner.assertEqual(quartzFrame.y, 25.0, "Quartz Y should start below menu bar")
    TestRunner.assertEqual(quartzFrame.width, 1920.0)
    TestRunner.assertEqual(quartzFrame.height, 995.0)

    // Invert back to Cocoa
    let invertedCocoa = QuartzGeometry.toCocoaRect(quartzRect: quartzFrame, primaryScreenHeight: 1080)
    TestRunner.assertEqual(invertedCocoa, cocoaFrame, "Roundtrip Cocoa <-> Quartz should be lossless")

    // 6. Asymmetric Dual-Monitor Multi-Monitor Topology
    // Display 1 (Primary 1080p): (0, 0, 1920, 1080) in Cocoa
    // Display 2 (Secondary 1440p): (1920, -360, 2560, 1440) in Cocoa (top-aligned with Display 1)
    let d1Cocoa = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let d2Cocoa = CGRect(x: 1920, y: -360, width: 2560, height: 1440)

    let d1Quartz = QuartzGeometry.toQuartzRect(cocoaFrame: d1Cocoa, primaryScreenHeight: 1080)
    let d2Quartz = QuartzGeometry.toQuartzRect(cocoaFrame: d2Cocoa, primaryScreenHeight: 1080)

    TestRunner.assertEqual(d1Quartz, QuartzRect(x: 0, y: 0, width: 1920, height: 1080))
    TestRunner.assertEqual(d2Quartz, QuartzRect(x: 1920, y: 0, width: 2560, height: 1440))

    // Adjacency checks
    TestRunner.assertTrue(QuartzGeometry.isAdjacentLeft(rect: d2Quartz, candidate: d1Quartz), "D1 is adjacent left to D2")
    TestRunner.assertTrue(QuartzGeometry.isAdjacentRight(rect: d1Quartz, candidate: d2Quartz), "D2 is adjacent right to D1")
    TestRunner.assertFalse(QuartzGeometry.isAdjacentLeft(rect: d1Quartz, candidate: d2Quartz), "D2 is not left to D1")

    // 7. Best Screen Resolution in Quartz Space
    let screens = [
        (id: CGDirectDisplayID(1), bounds: d1Quartz),
        (id: CGDirectDisplayID(2), bounds: d2Quartz)
    ]
    let winOnD1 = QuartzRect(x: 100, y: 100, width: 800, height: 600)
    let winOnD2 = QuartzRect(x: 2000, y: 100, width: 800, height: 600)
    let winCrossing = QuartzRect(x: 1800, y: 100, width: 600, height: 600) // 120pt on D1, 480pt on D2

    TestRunner.assertEqual(QuartzGeometry.bestScreenID(forFrame: winOnD1, screens: screens), 1)
    TestRunner.assertEqual(QuartzGeometry.bestScreenID(forFrame: winOnD2, screens: screens), 2)
    TestRunner.assertEqual(QuartzGeometry.bestScreenID(forFrame: winCrossing, screens: screens), 2, "Crossing window resolves to screen with greater overlap area")

    // 8. LayoutEngine Zero Off-By-One Gaps in Quartz Plan
    let ribbon = Ribbon(
        columns: [
            ColumnModel(windows: [WindowModel(id: 101, pid: 1, title: "W1", appName: "App1")], widthRatio: 0.5),
            ColumnModel(windows: [WindowModel(id: 102, pid: 2, title: "W2", appName: "App2")], widthRatio: 0.5)
        ]
    )
    let config = Config()
    let screenBounds = QuartzRect(x: 0, y: 25, width: 1920, height: 1055)
    let plan = LayoutEngine.computePlan(for: ribbon, screenFrame: screenBounds, config: config)

    TestRunner.assertEqual(plan.placements.count, 2)
    let pA = plan.placements[0]
    let pB = plan.placements[1]

    TestRunner.assertFalse(pA.isStashed)
    TestRunner.assertFalse(pB.isStashed)

    // Check inner gap between column A and column B matches config.windowGap exactly
    let gapBetween = pB.quartzFrame.minX - pA.quartzFrame.maxX
    TestRunner.assertEqual(gapBetween, config.windowGap, "Gap between columns should match config.windowGap exactly")

    // Check vertical bounds match canvas exactly
    let expectedY = screenBounds.minY + config.edgeMargin
    let expectedH = screenBounds.height - (config.edgeMargin * 2)
    TestRunner.assertEqual(pA.quartzFrame.minY, expectedY)
    TestRunner.assertEqual(pA.quartzFrame.height, expectedH)

    // 9. SkyLightBridge Linker & Symbol Availability
    let bridge = SkyLightBridge.shared
    TestRunner.assertTrue(bridge.isAvailable, "SkyLightBridge must dynamically resolve SLSMoveWindowWithGroup on macOS")

    // 10. FreeEdgeStashEngine Multi-Monitor Free Edges
    let d1Bounds = DisplayBounds(id: 1, frame: d1Quartz, visibleFrame: d1Quartz)
    let d2Bounds = DisplayBounds(id: 2, frame: d2Quartz, visibleFrame: d2Quartz)
    let displays = [d1Bounds, d2Bounds]

    let d1Free = FreeEdgeStashEngine.freeEdges(for: 1, in: displays)
    TestRunner.assertTrue(d1Free.contains(.left), "D1 left edge is free")
    TestRunner.assertTrue(d1Free.contains(.top), "D1 top edge is free")
    TestRunner.assertTrue(d1Free.contains(.bottom), "D1 bottom edge is free")
    TestRunner.assertFalse(d1Free.contains(.right), "D1 right edge touches D2 and is not free")

    let d2Free = FreeEdgeStashEngine.freeEdges(for: 2, in: displays)
    TestRunner.assertTrue(d2Free.contains(.right), "D2 right edge is free")
    TestRunner.assertTrue(d2Free.contains(.top), "D2 top edge is free")
    TestRunner.assertTrue(d2Free.contains(.bottom), "D2 bottom edge is free")
    TestRunner.assertFalse(d2Free.contains(.left), "D2 left edge touches D1 and is not free")

    // 11. FreeEdgeStashEngine Parked Origin & 1pt Anchor
    let winSize = QuartzSize(width: 800, height: 600)
    let leftOrigin = FreeEdgeStashEngine.parkedOrigin(
        windowSize: winSize,
        tiledY: 100,
        wing: .left,
        targetDisplay: d1Bounds,
        allDisplays: displays
    )
    let leftParkedRect = QuartzRect(origin: leftOrigin, size: winSize)
    TestRunner.assertEqual(leftParkedRect.maxX, 1.0, "Left parked window retains exactly 1.0pt sliver on host display")
    TestRunner.assertTrue(FreeEdgeStashEngine.isZeroBleed(rect: leftParkedRect, hostID: 1, allDisplays: displays), "Left parked window has zero bleed into other displays")

    let rightOrigin = FreeEdgeStashEngine.parkedOrigin(
        windowSize: winSize,
        tiledY: 100,
        wing: .right,
        targetDisplay: d1Bounds,
        allDisplays: displays
    )
    let rightParkedRect = QuartzRect(origin: rightOrigin, size: winSize)
    TestRunner.assertTrue(FreeEdgeStashEngine.isZeroBleed(rect: rightParkedRect, hostID: 1, allDisplays: displays), "Blocked right edge parks window with zero bleed into D2")

    // 12. Stashed Window Size Invariance (Zero AX Resize / Delta W/H = 0)
    let threeColRibbon = Ribbon(
        columns: [
            ColumnModel(windows: [WindowModel(id: 201, pid: 1, title: "Left", appName: "App1")], widthRatio: 1.0),
            ColumnModel(windows: [WindowModel(id: 202, pid: 2, title: "Center", appName: "App2")], widthRatio: 1.0),
            ColumnModel(windows: [WindowModel(id: 203, pid: 3, title: "Right", appName: "App3")], widthRatio: 1.0)
        ],
        activeColumnIndex: 1,
        viewportOffset: LayoutEngine.minimalScrollOffset(
            for: Ribbon(
                columns: [
                    ColumnModel(windows: [WindowModel(id: 201, pid: 1, title: "Left", appName: "App1")], widthRatio: 1.0),
                    ColumnModel(windows: [WindowModel(id: 202, pid: 2, title: "Center", appName: "App2")], widthRatio: 1.0),
                    ColumnModel(windows: [WindowModel(id: 203, pid: 3, title: "Right", appName: "App3")], widthRatio: 1.0)
                ],
                activeColumnIndex: 1,
                viewportOffset: 0.0
            ),
            canvasWidth: screenBounds.width - (config.edgeMargin * 2),
            config: config
        )
    )
    let threeColPlan = LayoutEngine.computePlan(
        for: threeColRibbon,
        screenFrame: screenBounds,
        config: config,
        targetDisplay: d1Bounds,
        allDisplays: displays
    )
    TestRunner.assertEqual(threeColPlan.placements.count, 3)
    let pLeft = threeColPlan.placements[0]
    let pCenter = threeColPlan.placements[1]
    let pRight = threeColPlan.placements[2]

    TestRunner.assertTrue(pLeft.isStashed, "Column 0 should be stashed to the left")
    TestRunner.assertFalse(pCenter.isStashed, "Column 1 should be visible/active")
    TestRunner.assertTrue(pRight.isStashed, "Column 2 should be stashed to the right")

    TestRunner.assertEqual(pLeft.quartzFrame.height, pCenter.quartzFrame.height, "Stashed window height matches active column height")
    TestRunner.assertEqual(pLeft.quartzFrame.width, pCenter.quartzFrame.width, "Stashed window width matches active column width")
    TestRunner.assertEqual(pRight.quartzFrame.height, pCenter.quartzFrame.height, "Stashed window height matches active column height")
    TestRunner.assertEqual(pRight.quartzFrame.width, pCenter.quartzFrame.width, "Stashed window width matches active column width")

    // 9. Stacked rows make room for a window's minimum height
    var tallTop = WindowModel(id: 301, pid: 1, title: "Top", appName: "App1")
    tallTop.minHeight = 600
    let stackedRibbon = Ribbon(columns: [
        ColumnModel(windows: [tallTop, WindowModel(id: 302, pid: 2, title: "Bottom", appName: "App2")], widthRatio: 1.0)
    ])
    let stacked = LayoutEngine.computePlan(for: stackedRibbon, screenFrame: screenBounds, config: config).placements
    let canvasBottom = screenBounds.maxY - config.edgeMargin
    TestRunner.assertEqual(stacked[0].quartzFrame.height, 600.0, "Row keeps its minimum height")
    TestRunner.assertEqual(stacked[1].quartzFrame.minY, stacked[0].quartzFrame.maxY + config.windowGap, "Next row starts below the tall row")
    TestRunner.assertEqual(stacked[1].quartzFrame.maxY, canvasBottom, "Shrinking row ends at the canvas bottom")
    TestRunner.assertEqual(LayoutEngine.rowHeights(minimums: [30, 30, 30], usable: 900), [300, 300, 300], "Rows split evenly without minimums")
    TestRunner.assertEqual(LayoutEngine.rowHeights(minimums: [500, 500], usable: 900), [500, 500], "Minimums that do not fit overflow")

    // 10. Slurp keeps focus on the current window
    var slurpRibbon = Ribbon(columns: [
        ColumnModel(windows: [WindowModel(id: 401, pid: 1, title: "Current", appName: "App1")]),
        ColumnModel(windows: [WindowModel(id: 402, pid: 2, title: "Pulled", appName: "App2")])
    ])
    slurpRibbon.slurp()
    TestRunner.assertEqual(slurpRibbon.columns.count, 1, "Slurp merges the right column")
    TestRunner.assertEqual(slurpRibbon.activeWindow?.id, 401, "Slurp keeps focus on the current window")

    // 11. A column half past a shared display edge scrolls off; under half stays as a peek
    func straddleRibbon(middleWidth: Double) -> Ribbon {
        Ribbon(columns: [
            ColumnModel(windows: [WindowModel(id: 501, pid: 1, title: "A", appName: "App1")], widthRatio: 0.5),
            ColumnModel(windows: [WindowModel(id: 502, pid: 2, title: "B", appName: "App2")], widthRatio: middleWidth),
            ColumnModel(windows: [WindowModel(id: 503, pid: 3, title: "C", appName: "App3")], widthRatio: 0.5)
        ], activeColumnIndex: 1)
    }
    let d2Shared = SharedEdges(screenFrame: d2Quartz, config: config, targetDisplay: d2Bounds, allDisplays: displays)
    TestRunner.assertEqual(d2Shared, SharedEdges(left: config.edgeMargin, right: nil), "D2 shares only its left edge")
    let d2CanvasW = d2Quartz.width - (config.edgeMargin * 2)
    var snapped = straddleRibbon(middleWidth: 0.8)
    snapped.viewportOffset = LayoutEngine.minimalScrollOffset(for: snapped, canvasWidth: d2CanvasW, config: config, sharedEdges: d2Shared)
    let snappedGeometry = LayoutEngine.columnGeometry(for: snapped, canvasWidth: d2CanvasW, config: config)
    TestRunner.assertEqual(snapped.viewportOffset, snappedGeometry[1].x, "Active column moves flush to the shared edge")
    let snappedPlan = LayoutEngine.computePlan(for: snapped, screenFrame: d2Quartz, config: config, targetDisplay: d2Bounds, allDisplays: displays)
    TestRunner.assertTrue(snappedPlan.placements[0].isStashed, "Column past the shared edge stashes")
    TestRunner.assertFalse(snappedPlan.placements[2].isStashed, "Next column peeks past the free edge")
    var peek = straddleRibbon(middleWidth: 0.62)
    let unsnapped = LayoutEngine.minimalScrollOffset(for: peek, canvasWidth: d2CanvasW, config: config)
    peek.viewportOffset = LayoutEngine.minimalScrollOffset(for: peek, canvasWidth: d2CanvasW, config: config, sharedEdges: d2Shared)
    TestRunner.assertEqual(peek.viewportOffset, unsnapped, "A column under half past the shared edge stays")
    let peekPlan = LayoutEngine.computePlan(for: peek, screenFrame: d2Quartz, config: config, targetDisplay: d2Bounds, allDisplays: displays)
    TestRunner.assertFalse(peekPlan.placements[0].isStashed, "Column under half past the shared edge stays tiled")
    TestRunner.assertTrue(peekPlan.placements[0].quartzFrame.minX < d2Quartz.minX, "It overhangs the shared edge")

    // D1 shares its right edge: scrolling left onto the wide column leaves the next one half past it.
    let d1Shared = SharedEdges(screenFrame: d1Quartz, config: config, targetDisplay: d1Bounds, allDisplays: displays)
    TestRunner.assertEqual(d1Shared, SharedEdges(left: nil, right: config.edgeMargin), "D1 shares only its right edge")
    let d1CanvasW = d1Quartz.width - (config.edgeMargin * 2)
    var snappedRight = straddleRibbon(middleWidth: 0.8)
    snappedRight.viewportOffset = 10_000
    snappedRight.viewportOffset = LayoutEngine.minimalScrollOffset(for: snappedRight, canvasWidth: d1CanvasW, config: config, sharedEdges: d1Shared)
    let rightGeometry = LayoutEngine.columnGeometry(for: snappedRight, canvasWidth: d1CanvasW, config: config)
    TestRunner.assertEqual(snappedRight.viewportOffset, rightGeometry[1].x + rightGeometry[1].width - d1CanvasW,
                           "Active column moves flush to the shared right edge")
    let rightPlan = LayoutEngine.computePlan(for: snappedRight, screenFrame: d1Quartz, config: config, targetDisplay: d1Bounds, allDisplays: displays)
    TestRunner.assertTrue(rightPlan.placements[2].isStashed, "Column past the shared right edge stashes")
    TestRunner.assertFalse(rightPlan.placements[0].isStashed, "Previous column peeks past the free left edge")

    // 12. SwipeStepper thresholds, axis lock, reversal, finger reset, and excess drop
    var stepper = SwipeStepper()
    TestRunner.assertEqual(stepper.feed(fingers: 3, dx: -0.06, dy: 0, config: config), nil, "Under 0.03 travel does not step")
    TestRunner.assertEqual(stepper.feed(fingers: 3, dx: -0.03, dy: 0, config: config), .focusRight, "First negative crossing at 0.03 steps focus right")
    TestRunner.assertEqual(stepper.feed(fingers: 3, dx: -0.42, dy: 0, config: config), nil, "Second step the same way needs 0.15 travel")
    TestRunner.assertEqual(stepper.feed(fingers: 3, dx: -0.03, dy: 0, config: config), .focusRight, "Second step fires at 0.15 travel")
    TestRunner.assertEqual(stepper.feed(fingers: 3, dx: 0.09, dy: 0, config: config), nil, "Reversal under 0.04 travel does not step")
    TestRunner.assertEqual(stepper.feed(fingers: 3, dx: 0.03, dy: 0, config: config), .focusLeft, "Reversal at 0.04 travel steps focus left")

    var verticalStepper = SwipeStepper()
    TestRunner.assertEqual(verticalStepper.feed(fingers: 3, dx: 0, dy: 0.09, config: config), nil, "Vertical crossing at 0.03 locks y axis without stepping")
    TestRunner.assertEqual(verticalStepper.feed(fingers: 3, dx: -0.60, dy: 0, config: config), nil, "Locked y axis never steps on horizontal motion")
    TestRunner.assertEqual(verticalStepper.feed(fingers: 2, dx: 0, dy: 0, config: config), nil, "Finger count of 2 resets travel and axis")
    TestRunner.assertEqual(verticalStepper.feed(fingers: 3, dx: 0.09, dy: 0, config: config), .focusLeft, "After 2-finger reset, 0.03 positive travel steps focus left")

    var flickStepper = SwipeStepper()
    TestRunner.assertEqual(flickStepper.feed(fingers: 3, dx: -0.90, dy: 0, config: config), .focusRight, "Fast flick fires one step")
    TestRunner.assertEqual(flickStepper.feed(fingers: 3, dx: -0.03, dy: 0, config: config), nil, "Excess travel past threshold is dropped")

    // 13. A released pan focuses a fully visible column so the strip stays put
    let panGeometry: [(x: Double, width: Double)] = [(x: 0, width: 750), (x: 760, width: 1200), (x: 1970, width: 1200)]
    TestRunner.assertEqual(LayoutEngine.panSnapColumn(geometry: panGeometry, offset: 0, canvasWidth: 1500, activeIndex: 1), 0,
                           "Panned to the left end, the fully visible left column wins over the half-visible active one")
    TestRunner.assertEqual(LayoutEngine.panSnapColumn(geometry: panGeometry, offset: 700, canvasWidth: 1500, activeIndex: 0), 1,
                           "The active column scrolled off loses to the fully visible one")
    TestRunner.assertEqual(LayoutEngine.panSnapColumn(geometry: panGeometry, offset: 1100, canvasWidth: 1500, activeIndex: 2), 1,
                           "With nothing fully visible, the most visible column wins over the active one")
    TestRunner.assertEqual(LayoutEngine.panSnapColumn(geometry: panGeometry, offset: 1215, canvasWidth: 1500, activeIndex: 2), 2,
                           "A tie in visible width keeps the active column")
    let narrowGeometry: [(x: Double, width: Double)] = [(x: 0, width: 400), (x: 410, width: 400), (x: 820, width: 400)]
    TestRunner.assertEqual(LayoutEngine.panSnapColumn(geometry: narrowGeometry, offset: 0, canvasWidth: 1500, activeIndex: 2), 2,
                           "A fully visible active column keeps focus")
    let fourGeometry: [(x: Double, width: Double)] = [(x: 0, width: 400), (x: 410, width: 400), (x: 820, width: 400), (x: 1230, width: 400)]
    TestRunner.assertEqual(LayoutEngine.panSnapColumn(geometry: fourGeometry, offset: 700, canvasWidth: 1000, activeIndex: 0), 2,
                           "The fully visible column nearest the active one wins")
    TestRunner.assertEqual(LayoutEngine.panSnapColumn(geometry: panGeometry, offset: 1215, canvasWidth: 1500, activeIndex: 9), 2,
                           "An out-of-range active index clamps to the last column")
    TestRunner.assertEqual(LayoutEngine.panSnapColumn(geometry: [], offset: 0, canvasWidth: 1500, activeIndex: 0), nil,
                           "No columns, no target")

    guard TestRunner.summary() else {
        exit(1)
    }
}

@main
struct RibbonCoreTests {
    static func main() {
        runTests()
    }
}
