import SwiftUI

struct ChatFramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
extension View {
    func chatFrame(_ id: String) -> some View {
        background(GeometryReader { geometry in Color.clear.preference(key: ChatFramePreference.self, value: [id: geometry.frame(in: .named("chat-stage"))]) })
    }
}
struct OutgoingFlight: Identifiable {
    let id: String
    let text: String
    let origin: CGRect
    var destination: CGRect?
    var layoutReady = false
}

/// A short, request-scoped flight; the real row reserves its space underneath.
/// The spring may overshoot, while the curved lift returns to zero at landing.
struct OutgoingBubbleFlight: View {
    let flight: OutgoingFlight
    let landed: () -> Void
    @State private var progress = 0.0
    var body: some View {
        if let destination = flight.destination {
            Text(flight.text).font(TypeScale.chat).padding(.horizontal, Space.lg).padding(.vertical, Space.md)
                .frame(width: destination.width, height: destination.height, alignment: .leading)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.row))
                .modifier(FlightPath(origin: flight.origin, destination: destination, progress: progress))
                .position(x: destination.midX, y: destination.midY)
                .allowsHitTesting(false).accessibilityHidden(true)
                .task(id: flight.id) {
                    withAnimation(.spring(duration: 0.38, bounce: 0.18)) { progress = 1 }
                    try? await Task.sleep(for: .milliseconds(440))
                    guard !Task.isCancelled else { return }
                    landed()
                }
        } else {
            Text(flight.text).font(TypeScale.chat).padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                .frame(width: flight.origin.width, height: flight.origin.height, alignment: .leading)
                .position(x: flight.origin.midX, y: flight.origin.midY)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

nonisolated private struct FlightPath: GeometryEffect {
    let origin: CGRect
    let destination: CGRect
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = progress
        let arc = sin(min(1, max(0, p)) * .pi)
        let startX = origin.minX + destination.width / 2
        let dx = (startX - destination.midX) * (1 - p) + 8 * arc
        let dy = (origin.midY - destination.midY) * (1 - p) - 18 * arc
        let scale = 0.97 + 0.03 * p
        let transform = CGAffineTransform(translationX: dx + size.width / 2, y: dy + size.height / 2)
            .rotated(by: -1.5 * .pi / 180 * arc).scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(transform)
    }
}

struct MessagePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduce
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(reduce ? 1 : configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduce ? nil : .spring(duration: 0.18, bounce: 0.12), value: configuration.isPressed)
    }
}
