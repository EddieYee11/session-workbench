import Foundation
import CoreGraphics

public enum DevicePosture: Equatable, Sendable {
    case outerSingle          // width < 700pt, 0°~30°
    case innerFlatDual(bookCurvature: Bool) // width >= 700pt, 115°~180° (115°~169° = book curvature)
    case innerTabletop        // width >= 700pt, 75°~115°, horizontal orientation
    case innerTent            // 260°~350°
}

public final class DuoPosture {
    public var posture: DevicePosture = .outerSingle
    public var screenWidth: CGFloat = 0
    public var screenHeight: CGFloat = 0
    public var creaseRect: CGRect?
    public var hingeAngle: Double = 180.0
    public var isWide: Bool { screenWidth >= 700 }

    public init() {}

    public func updateGeometry(width: CGFloat, height: CGFloat, crease: CGRect?, angle: Double = 180) {
        self.screenWidth = width
        self.screenHeight = height
        self.creaseRect = crease
        self.hingeAngle = angle

        if width < 700 {
            self.posture = .outerSingle
        } else if angle >= 75 && angle <= 115 {
            self.posture = .innerTabletop
        } else if angle > 115 && angle < 170 {
            self.posture = .innerFlatDual(bookCurvature: true)
        } else {
            self.posture = .innerFlatDual(bookCurvature: false)
        }
    }
}

// Surface Layout Evaluator matching HerdrTerminalSurface lines 51-63 & 124-126
struct SurfaceLayoutEvaluator {
    static func evaluate(containerWidth: CGFloat, posture: DuoPosture?) -> (isWide: Bool, isTabletop: Bool, leftWidth: CGFloat, gap: CGFloat, rightWidth: CGFloat, overflows: Bool) {
        let isWide = containerWidth >= 700 || (posture?.isWide ?? false)
        let isTabletop = (posture?.posture == .innerTabletop) || (isWide && (posture?.hingeAngle ?? 180) >= 75 && (posture?.hingeAngle ?? 180) <= 115)
        
        let leftWidth: CGFloat = posture?.creaseRect.map { $0.minX.rounded() } ?? min(420, max(360, (containerWidth * 0.42).rounded()))
        let gap: CGFloat = max(16, min(24, posture?.creaseRect?.width.rounded() ?? 20))
        let rightWidth = max(300, containerWidth - leftWidth - gap)
        let totalWidth = leftWidth + gap + rightWidth
        let overflows = totalWidth > containerWidth
        
        return (isWide, isTabletop, leftWidth, gap, rightWidth, overflows)
    }
}

print("======================================================================")
print("  CHALLENGER 2: DuoPosture & HerdrTerminalSurface Empirical Stress Test")
print("======================================================================")

var passedCount = 0
var totalCount = 0
var anomalies: [String] = []

func testCase(_ name: String, _ condition: Bool, anomalyNote: String? = nil) {
    totalCount += 1
    if condition {
        passedCount += 1
        print("  ✓ [PASS] \(name)")
    } else {
        print("  ✗ [FAIL] \(name)")
        if let note = anomalyNote {
            anomalies.append("\(name): \(note)")
        }
    }
}

print("\n--- Part 1: Width Boundary Transitions (<700 vs >=700) ---")
let dp = DuoPosture()

dp.updateGeometry(width: 699.0, height: 800, crease: nil, angle: 90)
testCase("Width 699.0pt, Angle 90° -> .outerSingle & !isWide", dp.posture == .outerSingle && !dp.isWide)

dp.updateGeometry(width: 699.999, height: 800, crease: nil, angle: 90)
testCase("Width 699.999pt, Angle 90° -> .outerSingle & !isWide", dp.posture == .outerSingle && !dp.isWide)

dp.updateGeometry(width: 700.0, height: 800, crease: nil, angle: 90)
testCase("Width 700.0pt, Angle 90° -> .innerTabletop & isWide", dp.posture == .innerTabletop && dp.isWide)

dp.updateGeometry(width: 700.001, height: 800, crease: nil, angle: 90)
testCase("Width 700.001pt, Angle 90° -> .innerTabletop & isWide", dp.posture == .innerTabletop && dp.isWide)

dp.updateGeometry(width: 0, height: 800, crease: nil, angle: 90)
testCase("Width 0pt -> .outerSingle", dp.posture == .outerSingle && !dp.isWide)

dp.updateGeometry(width: -100, height: 800, crease: nil, angle: 90)
testCase("Negative width -100pt -> .outerSingle", dp.posture == .outerSingle && !dp.isWide)

print("\n--- Part 2: Angle Threshold Transitions at Width 800pt ---")

// 74° vs 75°
dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 74.0)
testCase("Angle 74.0° (width 800) -> .innerFlatDual(false)", dp.posture == .innerFlatDual(bookCurvature: false),
     anomalyNote: "Angle 74° (<75°) falls back to innerFlatDual(false) instead of outerSingle or tent")

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 74.999)
testCase("Angle 74.999° -> .innerFlatDual(false)", dp.posture == .innerFlatDual(bookCurvature: false))

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 75.0)
testCase("Angle 75.0° -> .innerTabletop", dp.posture == .innerTabletop)

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 75.001)
testCase("Angle 75.001° -> .innerTabletop", dp.posture == .innerTabletop)

// 115° vs 116°
dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 114.999)
testCase("Angle 114.999° -> .innerTabletop", dp.posture == .innerTabletop)

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 115.0)
testCase("Angle 115.0° -> .innerTabletop", dp.posture == .innerTabletop)

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 115.001)
testCase("Angle 115.001° -> .innerFlatDual(bookCurvature: true)", dp.posture == .innerFlatDual(bookCurvature: true))

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 116.0)
testCase("Angle 116.0° -> .innerFlatDual(bookCurvature: true)", dp.posture == .innerFlatDual(bookCurvature: true))

// 170° vs 171°
dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 169.999)
testCase("Angle 169.999° -> .innerFlatDual(bookCurvature: true)", dp.posture == .innerFlatDual(bookCurvature: true))

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 170.0)
testCase("Angle 170.0° -> .innerFlatDual(bookCurvature: false)", dp.posture == .innerFlatDual(bookCurvature: false))

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 170.001)
testCase("Angle 170.001° -> .innerFlatDual(bookCurvature: false)", dp.posture == .innerFlatDual(bookCurvature: false))

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 171.0)
testCase("Angle 171.0° -> .innerFlatDual(bookCurvature: false)", dp.posture == .innerFlatDual(bookCurvature: false))

print("\n--- Part 3: Extreme & Negative Angles ---")
dp.updateGeometry(width: 800, height: 800, crease: nil, angle: -90.0)
testCase("Angle -90.0° -> .innerFlatDual(false) (safe fallback)", dp.posture == .innerFlatDual(bookCurvature: false))

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 0.0)
testCase("Angle 0.0° -> .innerFlatDual(false)", dp.posture == .innerFlatDual(bookCurvature: false))

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 300.0) // Tent range
testCase("Angle 300.0° -> .innerFlatDual(false)", dp.posture == .innerFlatDual(bookCurvature: false),
     anomalyNote: "Angle 300° falls into .innerFlatDual(false) because .innerTent is unhandled in updateGeometry")

dp.updateGeometry(width: 800, height: 800, crease: nil, angle: 1000.0)
testCase("Angle 1000.0° -> .innerFlatDual(false)", dp.posture == .innerFlatDual(bookCurvature: false))

print("\n--- Part 4: HerdrTerminalSurface Layout Assertions ---")

// Scenario 4.1: Standard iPad / Fold wide screen (800pt) without physical crease
dp.updateGeometry(width: 800, height: 600, crease: nil, angle: 180)
let s41 = SurfaceLayoutEvaluator.evaluate(containerWidth: 800, posture: dp)
testCase("Surface layout (800pt, flat): isWide=true, !isTabletop, no overflow",
     s41.isWide && !s41.isTabletop && !s41.overflows && s41.leftWidth == 360 && s41.gap == 20 && s41.rightWidth == 420)
print("    -> leftWidth: \(s41.leftWidth), gap: \(s41.gap), rightWidth: \(s41.rightWidth), total: \(s41.leftWidth + s41.gap + s41.rightWidth) / 800")

// Scenario 4.2: Fold wide screen (800pt) with centered physical crease (minX=390, width=20)
dp.updateGeometry(width: 800, height: 600, crease: CGRect(x: 390, y: 0, width: 20, height: 600), angle: 180)
let s42 = SurfaceLayoutEvaluator.evaluate(containerWidth: 800, posture: dp)
testCase("Surface layout (800pt, crease at 390): leftWidth aligns to crease.minX (390), no overflow",
     s42.leftWidth == 390 && s42.gap == 20 && s42.rightWidth == 390 && !s42.overflows)
print("    -> leftWidth: \(s42.leftWidth), gap: \(s42.gap), rightWidth: \(s42.rightWidth), total: \(s42.leftWidth + s42.gap + s42.rightWidth) / 800")

// Scenario 4.3: Tabletop mode at 90°
dp.updateGeometry(width: 800, height: 600, crease: nil, angle: 90)
let s43 = SurfaceLayoutEvaluator.evaluate(containerWidth: 800, posture: dp)
testCase("Surface layout (Tabletop 90°): isTabletop=true", s43.isTabletop)

// Scenario 4.4: Boundary container width 700pt
dp.updateGeometry(width: 700, height: 600, crease: nil, angle: 180)
let s44 = SurfaceLayoutEvaluator.evaluate(containerWidth: 700, posture: dp)
testCase("Surface layout (700pt min wide): no overflow", !s44.overflows && s44.leftWidth == 360 && s44.rightWidth == 320)
print("    -> leftWidth: \(s44.leftWidth), gap: \(s44.gap), rightWidth: \(s44.rightWidth), total: \(s44.leftWidth + s44.gap + s44.rightWidth) / 700")

// Scenario 4.5: Adversarial Crease offset (e.g. crease at minX=500 on 700pt width)
dp.updateGeometry(width: 700, height: 600, crease: CGRect(x: 500, y: 0, width: 24, height: 600), angle: 180)
let s45 = SurfaceLayoutEvaluator.evaluate(containerWidth: 700, posture: dp)
print("    -> Adversarial Crease (minX=500 on 700pt container): leftWidth=\(s45.leftWidth), gap=\(s45.gap), rightWidth=\(s45.rightWidth), total=\(s45.leftWidth + s45.gap + s45.rightWidth) / 700. Overflows: \(s45.overflows)")
testCase("Surface layout handles asymmetric crease without crashing", s45.leftWidth == 500 && s45.gap == 24 && s45.rightWidth == 300)

print("\n======================================================================")
print("  SUMMARY: \(passedCount)/\(totalCount) Assertions Passed")
print("  Anomalies / Edge Observations: \(anomalies.count)")
for a in anomalies {
    print("  - \(a)")
}
print("======================================================================")
