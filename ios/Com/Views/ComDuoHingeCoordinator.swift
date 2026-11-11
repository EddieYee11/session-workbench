// File: ios/Com/Views/ComDuoHingeCoordinator.swift
import SwiftUI
import ComCore
import UIKit

enum DuoDropTarget: Hashable {
    case none
    case boardColumn(BoardColumn)
    case inputBar
    case presenceCapsule
}

@Observable @MainActor
final class ComDuoHingeCoordinator {
    // MARK: - Posture & Hinge State
    var duoPosture = DuoPosture()

    var posture: DevicePosture {
        get { duoPosture.posture }
        set { duoPosture.posture = newValue }
    }
    var screenWidth: CGFloat {
        get { duoPosture.screenWidth }
        set { duoPosture.screenWidth = newValue }
    }
    var screenHeight: CGFloat {
        get { duoPosture.screenHeight }
        set { duoPosture.screenHeight = newValue }
    }
    var creaseRect: CGRect? {
        get { duoPosture.creaseRect }
        set { duoPosture.creaseRect = newValue }
    }
    var hingeAngle: Double {
        get { duoPosture.hingeAngle }
        set { duoPosture.hingeAngle = newValue }
    }
    var isWide: Bool { duoPosture.isWide }

    // MARK: - Drag State
    var isDragging: Bool = false
    var settling: Bool = false
    var ghostCard: JSON?
    var originColumn: BoardColumn = .suggest
    var originGroup: BoardGroup = .suggest
    var originIndex: Int = 0
    var originFrameInDuoRoot: CGRect = .zero
    var grabOffset: CGSize = .zero
    var cardSize: CGSize = CGSize(width: 280, height: 68)
    var floatingPosition: CGPoint = .zero
    var floatingOpacity: Double = 1.0
    var liftScale: CGFloat = 1.0
    var tilt: Double = 0.0
    var shadowRadius: CGFloat = 12
    var shadowY: CGFloat = 3
    var shadowOpacity: Double = 0.05

    // MARK: - Drop Targets & Geometry Snapshots
    var hoverDropTarget: DuoDropTarget = .none
    var frozenDropRect: CGRect = .zero
    var frozenLeftWidth: CGFloat = 400
    var registeredDropRects: [DuoDropTarget: CGRect] = [:]

    // MARK: - Performance Tracking
    @ObservationIgnored private var lastPoint: CGPoint = .zero
    @ObservationIgnored private var lastTime: TimeInterval = 0

    // MARK: - Spring Token (PRD & Dispatch aligned)
    static let snapbackSpring = Animation.spring(response: 0.35, dampingFraction: 0.75)

    init() {}

    // MARK: - Geometry Updates
    func updateGeometry(width: CGFloat, height: CGFloat, crease: CGRect?, angle: Double = 180) {
        duoPosture.updateGeometry(width: width, height: height, crease: crease, angle: angle)
    }

    // MARK: - Drag Lifecycle
    func beginDrag(
        card: JSON,
        group: BoardGroup,
        column: BoardColumn,
        index: Int,
        frameInDuoRoot: CGRect,
        touchPointInDuoRoot: CGPoint,
        appModel: AppModel
    ) {
        guard !isDragging else { return }
        self.ghostCard = card
        self.originGroup = group
        self.originColumn = column
        self.originIndex = index
        self.originFrameInDuoRoot = frameInDuoRoot
        self.cardSize = frameInDuoRoot.size.width > 0 ? frameInDuoRoot.size : CGSize(width: 280, height: 68)
        self.grabOffset = CGSize(
            width: touchPointInDuoRoot.x - frameInDuoRoot.minX,
            height: touchPointInDuoRoot.y - frameInDuoRoot.minY
        )
        self.floatingPosition = CGPoint(x: frameInDuoRoot.minX, y: frameInDuoRoot.minY - 4)
        self.floatingOpacity = 1.0
        self.hoverDropTarget = .boardColumn(column)

        // Layout Freeze
        self.isDragging = true
        self.settling = false
        self.frozenLeftWidth = min(420, max(360, (screenWidth * 0.42).rounded()))
        if let composerRect = registeredDropRects[.inputBar] {
            self.frozenDropRect = composerRect
        }
        appModel.boardDragFreeze = true

        self.lastPoint = touchPointInDuoRoot
        self.lastTime = CACurrentMediaTime()

        withAnimation(ComMotion.press) {
            self.liftScale = 1.04
            self.shadowRadius = 28
            self.shadowY = 16
            self.shadowOpacity = 0.18
        }
        Haptics.impact(.medium, intensity: 0.8)
    }

    func dragMoved(to rootPoint: CGPoint, velocityX: CGFloat? = nil) {
        guard isDragging, !settling else { return }
        self.floatingPosition = CGPoint(
            x: rootPoint.x - grabOffset.width,
            y: rootPoint.y - grabOffset.height - 4
        )

        // Tilt calculation
        let now = CACurrentMediaTime()
        let dt = max(1.0 / 240.0, now - lastTime)
        let vx = velocityX ?? ((rootPoint.x - lastPoint.x) / CGFloat(dt))
        self.lastPoint = rootPoint
        self.lastTime = now
        let targetTilt = max(-4, min(4, Double(vx / 1200) * 4))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            self.tilt = targetTilt
        }

        // Hit-Testing: Left Column InputBar (+16pt glow margin tolerance)
        let hitTestToleranceRect = frozenDropRect.insetBy(dx: -16, dy: -16)
        if hitTestToleranceRect.contains(rootPoint) {
            if hoverDropTarget != .inputBar {
                hoverDropTarget = .inputBar
                Haptics.impact(.light, intensity: 0.7)
            }
            return
        }

        // Crease safe zone: If within crease, hover is none
        if let crease = creaseRect, crease.width > 0 {
            if rootPoint.x >= crease.minX && rootPoint.x <= crease.maxX {
                hoverDropTarget = .none
                return
            }
        }

        // Fallback: Check right pane columns
        for (target, rect) in registeredDropRects {
            if target != .inputBar && rect.contains(rootPoint) {
                if hoverDropTarget != target {
                    hoverDropTarget = target
                    Haptics.selection()
                }
                return
            }
        }
        hoverDropTarget = .none
    }

    func endDrag(
        appModel: AppModel,
        onDropToInputBar: @escaping (JSON) -> Void,
        onDropToBoardColumn: @escaping (JSON, BoardColumn) -> Void
    ) {
        guard isDragging, !settling, let card = ghostCard else {
            cancelImmediate(appModel: appModel)
            return
        }

        switch hoverDropTarget {
        case .inputBar:
            // Drop Succeeded onto InputBar: Card converts to Context Chip
            self.settling = true
            Haptics.sent()
            onDropToInputBar(card)

            // Fly into InputBar anchor
            let dest = CGPoint(
                x: frozenDropRect.midX - cardSize.width / 2,
                y: frozenDropRect.midY - cardSize.height / 2
            )
            withAnimation(ComMotion.flight) {
                self.floatingPosition = dest
                self.liftScale = 0.5
                self.floatingOpacity = 0.0
                self.tilt = 0
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(340))
                self.finishDrag(appModel: appModel)
            }

        case .boardColumn(let col):
            self.settling = true
            Haptics.sent()
            onDropToBoardColumn(card, col)
            let dest = registeredDropRects[.boardColumn(col)]?.origin ?? originFrameInDuoRoot.origin
            withAnimation(ComMotion.flight) {
                self.floatingPosition = dest
                self.liftScale = 1.0
                self.floatingOpacity = 0.0
                self.tilt = 0
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(340))
                self.finishDrag(appModel: appModel)
            }

        case .none, .presenceCapsule:
            // Cancelled or invalid drop target -> Trigger Spring Snapback
            snapback(appModel: appModel)
        }
    }

    func snapback(appModel: AppModel) {
        guard isDragging, !settling else {
            finishDrag(appModel: appModel)
            return
        }
        self.settling = true
        Haptics.error()

        // Exact Spring Snapback: .spring(response: 0.35, dampingFraction: 0.75)
        withAnimation(Self.snapbackSpring) {
            self.floatingPosition = self.originFrameInDuoRoot.origin
            self.liftScale = 1.0
            self.tilt = 0
            self.shadowRadius = 12
            self.shadowY = 3
            self.shadowOpacity = 0.05
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            self.finishDrag(appModel: appModel)
        }
    }

    private func finishDrag(appModel: AppModel) {
        self.isDragging = false
        self.settling = false
        self.ghostCard = nil
        self.hoverDropTarget = .none
        self.liftScale = 1.0
        self.tilt = 0
        self.floatingOpacity = 1.0
        appModel.boardDragFreeze = false
    }

    func cancelImmediate(appModel: AppModel) {
        self.isDragging = false
        self.settling = false
        self.ghostCard = nil
        self.hoverDropTarget = .none
        appModel.boardDragFreeze = false
    }

    func syncKeyboardOffset(_ deltaY: CGFloat) {
        guard isDragging else { return }
        self.frozenDropRect.origin.y += deltaY
    }
}
