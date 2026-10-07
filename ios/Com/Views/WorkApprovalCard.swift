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
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                Pill(text: "等待你的决定", color: Palette.coral)
                let params = approval["params"]
                if !params["reason"].string.isEmpty { Text(params["reason"].string) }
                if !params["command"].string.isEmpty { Text(params["command"].string).font(.caption.monospaced()).textSelection(.enabled) }
                if !questions.isEmpty {
                    ForEach(questions.map(RemoteRow.init)) { row in
                        Text(row.value["question"].string).font(.subheadline.weight(.semibold))
                        ForEach(Array(row.value["options"].array.enumerated()), id: \.offset) { _, option in
                            Button { answers[row.id] = option["label"].string } label: { Label(option["label"].string, systemImage: answers[row.id] == option["label"].string ? "checkmark.circle.fill" : "circle") }.buttonStyle(.bordered)
                            if !option["description"].string.isEmpty { Text(option["description"].string).font(.caption).foregroundStyle(.secondary) }
                        }
                        TextField("你的回答", text: Binding(get: { answers[row.id] ?? "" }, set: { answers[row.id] = $0 }), axis: .vertical).textFieldStyle(.roundedBorder)
                    }
                    Button("提交这些回答") { submit(["answers": .object(answers.mapValues(JSON.string))]) }.buttonStyle(.borderedProminent).disabled(questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || submitting)
                } else {
                    let decisions = params["availableDecisions"].array.isEmpty ? [JSON.string("accept"), .string("decline"), .string("cancel")] : params["availableDecisions"].array
                    ForEach(Array(decisions.enumerated()), id: \.offset) { _, choice in
                        Button(decisionLabel(choice)) { submit(["decision": choice]) }.buttonStyle(.bordered).disabled(submitting)
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
