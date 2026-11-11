import UIKit

@MainActor enum Haptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func sent() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func prepareDrag() { UIImpactFeedbackGenerator(style: .medium).prepare() }
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium, intensity: CGFloat = 1) {
        UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: intensity)
    }
}
