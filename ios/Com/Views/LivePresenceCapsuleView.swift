// File: ios/Com/Views/LivePresenceCapsuleView.swift
import SwiftUI
import ComCore
import WebKit

enum CapsuleStatus: String, Sendable, Equatable, CaseIterable {
    case queued
    case executing
    case waitingInput = "waiting_input"
    case errorRetrying = "error_retrying"
    case errorBlocked = "error_blocked"
    case done
    case cancelled
}

struct CapsuleTask: Identifiable, Equatable, Sendable {
    let id: String
    let matterID: String?
    var title: String
    var status: CapsuleStatus
    var stepCurrent: Int
    var stepTotal: Int
    var stateText: String
    var waitingQuestion: String?
    var artifactPath: String?
    var updatedAt: Double

    init(
        id: String,
        matterID: String? = nil,
        title: String,
        status: CapsuleStatus = .executing,
        stepCurrent: Int = 1,
        stepTotal: Int = 1,
        stateText: String = "",
        waitingQuestion: String? = nil,
        artifactPath: String? = nil,
        updatedAt: Double = CACurrentMediaTime()
    ) {
        self.id = id
        self.matterID = matterID
        self.title = title
        self.status = status
        self.stepCurrent = stepCurrent
        self.stepTotal = stepTotal
        self.stateText = stateText
        self.waitingQuestion = waitingQuestion
        self.artifactPath = artifactPath
        self.updatedAt = updatedAt
    }
}

struct LivePresenceCapsuleView: View {
    @Bindable var model: AppModel
    @State private var isDrawerPresented = false
    @State private var activeIndex = 0
    @State private var pulse = false

    init(model: AppModel) {
        self.model = model
    }

    private var activeTasks: [CapsuleTask] {
        model.capsuleTasks.filter { $0.status != .cancelled }
    }

    private var currentTask: CapsuleTask? {
        guard !activeTasks.isEmpty else { return nil }
        let idx = min(activeIndex, activeTasks.count - 1)
        return activeTasks[max(0, idx)]
    }

    var body: some View {
        if let task = currentTask {
            HStack(spacing: Space.sm) {
                // Status Indicator Dot
                Circle()
                    .fill(dotColor(for: task.status))
                    .frame(width: 8, height: 8)
                    .shadow(color: dotColor(for: task.status).opacity(0.8), radius: pulse ? 6 : 2)
                    .scaleEffect(pulse ? 1.15 : 0.95)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)

                // Task Title
                Text(task.title)
                    .font(TypeScale.footnote.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                // Separator
                Text("·")
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.textTertiary)

                // Progress Step / Description
                Text(progressDescription(for: task))
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                // Multi-task Carousel Indicator
                if activeTasks.count > 1 {
                    HStack(spacing: 2) {
                        Text("\(min(activeIndex + 1, activeTasks.count))/\(activeTasks.count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Palette.fill, in: Capsule())
                    .onTapGesture {
                        withAnimation(ComMotion.press) {
                            activeIndex = (activeIndex + 1) % activeTasks.count
                        }
                    }
                }

                // Quick Action Buttons
                if task.status == .waitingInput {
                    HStack(spacing: Space.xs) {
                        Button("批准") {
                            approveTask(task)
                        }
                        .font(TypeScale.caption.weight(.bold))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.accent, in: Capsule())

                        Button("拒绝") {
                            cancelTask(task)
                        }
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.danger)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Palette.fill, in: Capsule())
                    }
                } else {
                    Button {
                        cancelTask(task)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Palette.surface.opacity(0.82), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(borderColor(for: task.status), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
            .contentShape(Capsule())
            .onTapGesture {
                isDrawerPresented = true
            }
            .onAppear {
                pulse = true
            }
            .sheet(isPresented: $isDrawerPresented) {
                LiveTaskDrawer(task: task, model: model) {
                    isDrawerPresented = false
                }
            }
        }
    }

    private func dotColor(for status: CapsuleStatus) -> Color {
        switch status {
        case .executing, .queued:
            return Palette.accent
        case .waitingInput:
            return Palette.warning
        case .errorRetrying, .errorBlocked:
            return Palette.danger
        case .done:
            return Palette.success
        case .cancelled:
            return Palette.textTertiary
        }
    }

    private func borderColor(for status: CapsuleStatus) -> Color {
        switch status {
        case .executing, .queued:
            return Palette.accent.opacity(0.45)
        case .waitingInput:
            return Palette.warning.opacity(0.65)
        case .errorRetrying, .errorBlocked:
            return Palette.danger.opacity(0.5)
        case .done:
            return Palette.success.opacity(0.5)
        case .cancelled:
            return Palette.separator
        }
    }

    private func progressDescription(for task: CapsuleTask) -> String {
        if task.status == .waitingInput {
            return task.waitingQuestion ?? "等待决策审批"
        }
        if task.stepTotal > 1 {
            return "\(task.stepCurrent)/\(task.stepTotal) \(task.stateText)"
        }
        return task.stateText.isEmpty ? "正在推进" : task.stateText
    }

    private func approveTask(_ task: CapsuleTask) {
        Task {
            _ = try? await model.mutate("/personal/cases/\(task.id)/send", fields: ["text": .string("同意继续")])
            Haptics.success()
        }
    }

    private func cancelTask(_ task: CapsuleTask) {
        Task {
            _ = await model.action("/personal/cases/\(task.id)/cancel")
            if let idx = model.capsuleTasks.firstIndex(where: { $0.id == task.id }) {
                model.capsuleTasks.remove(at: idx)
            }
            Haptics.sent()
        }
    }
}

struct LiveTaskDrawer: View {
    let task: CapsuleTask
    @Bindable var model: AppModel
    let onDismiss: () -> Void

    @State private var steerText: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.md) {
                // Header Card
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack {
                        Text(task.title)
                            .font(TypeScale.headline.weight(.bold))
                        Spacer()
                        Text(task.status.rawValue)
                            .font(TypeScale.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Palette.fill, in: Capsule())
                    }

                    if !task.stateText.isEmpty {
                        Text(task.stateText)
                            .font(TypeScale.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .padding()
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.md))

                // Steps Progress
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("执行步骤进度")
                        .font(TypeScale.footnote.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)

                    HStack {
                        Text("当前进度: \(task.stepCurrent) / \(task.stepTotal)")
                            .font(TypeScale.subheadline)
                        Spacer()
                        ProgressView(value: Double(task.stepCurrent), total: Double(max(1, task.stepTotal)))
                            .tint(Palette.accent)
                            .frame(width: 120)
                    }
                }
                .padding()
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.md))

                // Artifact Link
                if let artifact = task.artifactPath, !artifact.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("生成产物")
                            .font(TypeScale.footnote.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(Palette.accentText)
                            Text(artifact)
                                .font(TypeScale.footnote)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .padding()
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                }

                // Steer Input
                HStack(spacing: Space.sm) {
                    TextField("输入补充要求插话干预…", text: $steerText)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, Space.xs)
                        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.sm))

                    Button("发送") {
                        let text = steerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        Task {
                            _ = try? await model.mutate("/personal/cases/\(task.id)/send", fields: ["text": .string(text)])
                            steerText = ""
                            Haptics.sent()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .foregroundStyle(Palette.onAccent)
                }

                Spacer()

                // Bottom Terminate
                Button(role: .destructive) {
                    Task {
                        _ = await model.action("/personal/cases/\(task.id)/cancel")
                        if let idx = model.capsuleTasks.firstIndex(where: { $0.id == task.id }) {
                            model.capsuleTasks.remove(at: idx)
                        }
                        onDismiss()
                    }
                } label: {
                    Label("终止当前任务", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Palette.background)
            .navigationTitle("后台任务详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        onDismiss()
                    }
                }
            }
        }
    }
}
