import SwiftUI

public enum DevicePosture: Equatable, Sendable {
    case outerSingle          // width < 700pt, 0°~30°
    case innerFlatDual(bookCurvature: Bool) // width >= 700pt, 115°~180° (115°~169° = book curvature)
    case innerTabletop        // width >= 700pt, 75°~115°, horizontal orientation
    case innerTent            // 260°~350°
}

@Observable @MainActor
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
