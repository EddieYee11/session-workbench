import SwiftUI
import ComCore

struct WorkApprovalCard: View {
    @Environment(AppModel.self) private var model
    let approval: JSON
    let onComplete: @MainActor () async -> Void
    @State private var answers: [String: String] = [:]
    @State private var submitting = false
    private var questions: [JSON] { approval["params"]["questions"].array }
    var body: some View {
        Card(.highlighted(.warning)) {
            VStack(alignment: .leading, spacing: Space.md) {
                StatusPill(text: "等待你的决定", tone: .warning)
                let params = approval["params"]
                if !params["reason"].string.isEmpty { Text(params["reason"].string).font(TypeScale.callout) }
                if !params["command"].string.isEmpty { CodeBlock(text: params["command"].string) }
                if !questions.isEmpty {
                    ForEach(questions.map(RemoteRow.init)) { row in
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text(row.value["question"].string).font(TypeScale.headline)
                            ForEach(Array(row.value["options"].array.enumerated()), id: \.offset) { _, option in
                                let picked = answers[row.id] == option["label"].string
                                Button { answers[row.id] = option["label"].string } label: {
                                    HStack(alignment: .top, spacing: Space.sm) {
                                        Image(systemName: picked ? "checkmark.circle.fill" : "circle").foregroundStyle(picked ? Palette.accentText : Palette.textTertiary)
                                        VStack(alignment: .leading, spacing: Space.xxs) {
                                            Text(option["label"].string).font(TypeScale.callout).foregroundStyle(Palette.textPrimary)
                                            if !option["description"].string.isEmpty { Text(option["description"].string).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary) }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(Space.md)
                                    .background(picked ? Palette.accent.opacity(0.18) : Palette.fill, in: .rect(cornerRadius: Radius.sm, style: .continuous))
                                }.buttonStyle(.plain)
                            }
                            TextField("你的回答", text: Binding(get: { answers[row.id] ?? "" }, set: { answers[row.id] = $0 }), axis: .vertical).insetField()
                        }
                    }
                    Button("提交这些回答") { submit(["answers": .object(answers.mapValues(JSON.string))]) }.buttonStyle(.primaryFull).disabled(questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || submitting)
                } else {
                    let decisions = params["availableDecisions"].array.isEmpty ? [JSON.string("accept"), .string("decline"), .string("cancel")] : params["availableDecisions"].array
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(Array(decisions.enumerated()), id: \.offset) { _, choice in
                            let label = decisionLabel(choice)
                            if choice.string == "accept" || choice.string == "acceptForSession" {
                                Button(label) { submit(["decision": choice]) }.buttonStyle(.primaryFull).disabled(submitting)
                            } else {
                                Button(label) { submit(["decision": choice]) }.buttonStyle(.quiet).frame(maxWidth: .infinity).padding(.vertical, Space.xs).disabled(submitting)
                            }
                        }
                    }
                }
                RawDetails(title: "操作范围与完整参数", value: params)
            }
        }
    }
    private func decisionLabel(_ choice: JSON) -> String {
        switch choice.string { case "accept": "批准此操作"; case "decline": "拒绝此操作"; case "cancel": "取消"; case "acceptForSession": "批准此会话的同类操作"; default: choice.string.isEmpty ? choice.pretty : choice.string }
    }
    private func submit(_ fields: [String: JSON]) {
        submitting = true
        Task {
            defer { submitting = false }
            do { _ = try await model.mutate("/approvals/" + approval.id.pathEncoded, fields: fields); await onComplete() }
            catch { model.banner = error.localizedDescription }
        }
    }
}
