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
