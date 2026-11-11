import Foundation
import CoreGraphics

// Simulate the exact logic in RootView.swift lines 24-42
struct RootViewHingeLogic {
    var envAngle: Double? = nil
    var launchArgAngle: Double? = nil
    var hingeAngle: Double = 180.0
    var crease: CGRect? = nil

    var effectiveHingeAngle: Double {
        if let env = envAngle {
            return env
        }
        if let val = launchArgAngle {
            return val
        }
        if hingeAngle != 180.0 {
            return hingeAngle
        }
        if let crease, crease.width > 0, crease.height > 0 {
            if crease.width > crease.height {
                return 90.0
            }
            return 135.0
        }
        return 180.0
    }
}

// Simulate ComDuoHingeCoordinator.swift posture evaluation
enum DevicePosture: Equatable {
    case outerSingle
    case innerFlatDual(bookCurvature: Bool)
    case innerTabletop
    case innerTent
}

struct PostureEvaluator {
    static func evaluate(width: CGFloat, angle: Double) -> DevicePosture {
        if width < 700 {
            return .outerSingle
        } else if angle >= 75 && angle <= 115 {
            return .innerTabletop
        } else if angle > 115 && angle < 170 {
            return .innerFlatDual(bookCurvature: true)
        } else {
            return .innerFlatDual(bookCurvature: false)
        }
    }
}

@main
struct StressHingeAngle {
    static func main() {
        print("=== Starting Hinge Angle & Posture Empirical Stress Tests ===")

        // Test 1: 0° angle on wide screen (e.g. tablet or fold closed state)
        do {
            var logic = RootViewHingeLogic(hingeAngle: 0.0)
            let angle = logic.effectiveHingeAngle
            assert(angle == 0.0, "Effective angle for 0° should be 0.0, got \(angle)")
            let postureWide = PostureEvaluator.evaluate(width: 800, angle: angle)
            print("Angle 0° on wide (800pt) -> Posture: \(postureWide)")
            if postureWide == .innerFlatDual(bookCurvature: false) {
                print("⚠️ FINDING: At 0° (fully closed), wide viewport evaluates to .innerFlatDual(bookCurvature: false) instead of .outerSingle or closed!")
            }
            let postureNarrow = PostureEvaluator.evaluate(width: 400, angle: angle)
            print("Angle 0° on narrow (400pt) -> Posture: \(postureNarrow)")
            assert(postureNarrow == .outerSingle)
        }

        // Test 2: 90° angle (Tabletop)
        do {
            var logic = RootViewHingeLogic(hingeAngle: 90.0)
            let angle = logic.effectiveHingeAngle
            assert(angle == 90.0)
            let posture = PostureEvaluator.evaluate(width: 800, angle: angle)
            assert(posture == .innerTabletop, "Expected .innerTabletop, got \(posture)")
            print("✓ Angle 90° correctly produces .innerTabletop on wide screen")

            // Test horizontal crease fallback to 90°
            var creaseLogic = RootViewHingeLogic(hingeAngle: 180.0, crease: CGRect(x: 0, y: 400, width: 800, height: 20))
            assert(creaseLogic.effectiveHingeAngle == 90.0, "Horizontal crease must infer 90.0°")
            print("✓ Horizontal crease (width 800 > height 20) correctly infers 90.0°")
        }

        // Test 3: 135° angle (Book curvature)
        do {
            var logic = RootViewHingeLogic(hingeAngle: 135.0)
            let angle = logic.effectiveHingeAngle
            assert(angle == 135.0)
            let posture = PostureEvaluator.evaluate(width: 800, angle: angle)
            assert(posture == .innerFlatDual(bookCurvature: true), "Expected .innerFlatDual(bookCurvature: true), got \(posture)")
            print("✓ Angle 135° correctly produces .innerFlatDual(bookCurvature: true)")

            // Test vertical crease fallback to 135°
            var creaseLogic = RootViewHingeLogic(hingeAngle: 180.0, crease: CGRect(x: 400, y: 0, width: 20, height: 800))
            assert(creaseLogic.effectiveHingeAngle == 135.0, "Vertical crease must infer 135.0°")
            print("✓ Vertical crease (height 800 > width 20) correctly infers 135.0°")
        }

        // Test 4: 180° angle (Flat dual) vs Crease collision
        do {
            // When no crease is present
            var logicClean = RootViewHingeLogic(hingeAngle: 180.0, crease: nil)
            assert(logicClean.effectiveHingeAngle == 180.0)
            let postureClean = PostureEvaluator.evaluate(width: 800, angle: 180.0)
            assert(postureClean == .innerFlatDual(bookCurvature: false))
            print("✓ Angle 180° without crease correctly produces .innerFlatDual(bookCurvature: false)")

            // CRITICAL TEST: Explicit notification sets hingeAngle = 180.0, BUT a crease is reported
            var logicWithCrease = RootViewHingeLogic(hingeAngle: 180.0, crease: CGRect(x: 400, y: 0, width: 24, height: 800))
            let resolvedAngle = logicWithCrease.effectiveHingeAngle
            print("Explicit hingeAngle=180.0 with vertical crease present -> resolved effective angle: \(resolvedAngle)°")
            if resolvedAngle == 135.0 {
                print("⚠️ FINDING: Setting explicit hingeAngle = 180.0 is overridden by crease detection (returns \(resolvedAngle)°) because `hingeAngle != 180.0` treats 180.0 as unset!")
            }
        }

        // Test 5: Boundary angles for Tabletop (75° to 115°)
        do {
            assert(PostureEvaluator.evaluate(width: 800, angle: 74.9) == .innerFlatDual(bookCurvature: false), "74.9° should fall out of tabletop")
            assert(PostureEvaluator.evaluate(width: 800, angle: 75.0) == .innerTabletop, "75.0° should be tabletop")
            assert(PostureEvaluator.evaluate(width: 800, angle: 115.0) == .innerTabletop, "115.0° should be tabletop")
            assert(PostureEvaluator.evaluate(width: 800, angle: 115.1) == .innerFlatDual(bookCurvature: true), "115.1° should be book curvature")
            print("✓ Boundary angles for Tabletop (75.0° - 115.0°) verified")
        }

        print("=== All Hinge Angle & Posture tests completed ===")
    }
}
