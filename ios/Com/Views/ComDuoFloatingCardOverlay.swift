// File: ios/Com/Views/ComDuoFloatingCardOverlay.swift
import SwiftUI
import ComCore

struct ComDuoFloatingCardOverlay: View {
    @Bindable var coordinator: ComDuoHingeCoordinator

    init(coordinator: ComDuoHingeCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        if let card = coordinator.ghostCard {
            BoardSlimCard(
                card: card,
                pending: false,
                showProgress: card["column"].string == "doing",
                isDoneColumn: false,
                newlyDone: false,
                isFloating: true,
                shadowRadius: coordinator.shadowRadius,
                shadowY: coordinator.shadowY,
                shadowOpacity: coordinator.shadowOpacity
            )
            .frame(width: coordinator.cardSize.width)
            .scaleEffect(coordinator.liftScale)
            .rotationEffect(.degrees(coordinator.tilt))
            .opacity(coordinator.floatingOpacity)
            .offset(x: coordinator.floatingPosition.x, y: coordinator.floatingPosition.y)
            .allowsHitTesting(false)
        }
    }
}
