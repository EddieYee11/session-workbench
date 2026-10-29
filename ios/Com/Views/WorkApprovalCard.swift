import SwiftUI
import ComCore

struct WorkApprovalCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    let approval: JSON
    let onComplete: @MainActor () async -> Void
    @State private var answers: [String: String] = [:]
    @State private var submitting = false
    /// 批准/拒绝失败时卡上留句，别只靠顶栏 banner。
    @State private var failNote = ""
    @State private var land = false
    private var questions: [JSON] { approval["params"]["questions"].array }
    private var headline: String {
        let params = approval["params"]
        let reason = params["reason"].string
        if !reason.isEmpty { return reason }
        let tool = params["tool"].string
        if !tool.isEmpty { return "要动真格跑「\(tool)」" }
        let command = params["command"].string
        if !command.isEmpty {
            let short = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
            return "要执行：" + (short.count > 36 ? String(short.prefix(35)) + "…" : short)
        }
        return "动手前要你点头"
    }
    var body: some View {
        Card(.highlighted(.warning)) {
            VStack(alignment: .leading, spacing: Space.md) {
                StatusPill(text: "等你拍板", tone: .warning)
                Text(headline)
                    .font(TypeScale.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("我还没执行。批准才会动真格；拒绝就停在这一步，已经做的不会撤回。")
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                // 卡片提交失败 + 语音路径失败（关窗后）共用开口，双路径留页可再试。
                let shownFail = !failNote.isEmpty
                    ? failNote
                    : (model.approvalFailID == approval.id ? model.approvalFailNote : "")
                if !shownFail.isEmpty {
                    InlineNotice(text: shownFail, tone: .danger)
                        .accessibilityIdentifier("work-approval-fail")
                }
                let params = approval["params"]
                if !params["command"].string.isEmpty { CodeBlock(text: params["command"].string) }
                if !questions.isEmpty {
                    ForEach(questions.map(RemoteRow.init)) { row in
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text(row.value["question"].string).font(TypeScale.headline)
                            ForEach(Array(row.value["options"].array.enumerated()), id: \.offset) { _, option in
                                let picked = answers[row.id] == option["label"].string
                                Button {
                                    guard !submitting else { return }
                                    answers[row.id] = option["label"].string
                                    Haptics.selection()
                                } label: {
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
                                }
                                .buttonStyle(SoftPressStyle(scale: 0.985))
                                .disabled(submitting)
                            }
                            TextField("你的回答", text: Binding(get: { answers[row.id] ?? "" }, set: { answers[row.id] = $0 }), axis: .vertical)
                                .insetField()
                                .disabled(submitting)
                        }
                    }
                    Button(submitting ? "提交中…" : "提交回答，继续") {
                        submit(["answers": .object(answers.mapValues(JSON.string))])
                    }
                    .buttonStyle(.primaryFull)
                    .disabled(questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || submitting)
                } else {
                    let decisions = params["availableDecisions"].array.isEmpty ? [JSON.string("accept"), .string("decline"), .string("cancel")] : params["availableDecisions"].array
                    if VoiceCommands.canAnswer(params) {
                        Button("用语音说「批准」或「拒绝」") {
                            guard !submitting else { return }
                            model.pendingApproval = approval
                            // 保留卡上失败提示作上下文；开麦错误由语音窗自己开口。
                            model.openVoice(quick: true)
                        }
                        .buttonStyle(.quiet)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(submitting)
                        .accessibilityIdentifier("work-approval-voice")
                    }
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(Array(decisions.enumerated()), id: \.offset) { _, choice in
                            let label = decisionLabel(choice)
                            if choice.string == "accept" || choice.string == "acceptForSession" {
                                Button(submitting ? "提交中…" : label) { submit(["decision": choice]) }
                                    .buttonStyle(.primaryFull).disabled(submitting)
                            } else {
                                Button(label) { submit(["decision": choice]) }
                                    .buttonStyle(.quiet).frame(maxWidth: .infinity).padding(.vertical, Space.xs).disabled(submitting)
                            }
                        }
                    }
                }
                ApprovalScopeView(action: params)
                RawDetails(title: "操作范围与完整参数", value: params)
            }
        }
        .modifier(EnterRise(on: land, delay: 0.02, y: 12, blur: 5, animation: ComMotion.pop))
        .onAppear {
            if reduce { land = true }
            else { withAnimation(ComMotion.lift) { land = true } }
        }
    }
    private func decisionLabel(_ choice: JSON) -> String {
        switch choice.string {
        case "accept": "批准，去做"
        case "decline": "先别做"
        case "cancel": "取消这次"
        case "acceptForSession": "同类操作这会话都批"
        default: choice.string.isEmpty ? choice.pretty : choice.string
        }
    }
    private func submit(_ fields: [String: JSON]) {
        guard !submitting else { return }
        submitting = true
        failNote = ""
        Task {
            defer { submitting = false }
            guard model.client != nil else {
                let msg = "还没连上 mini——审批没发出去。可再点，或用语音再说。不会假装已批/已拒。"
                failNote = msg
                model.approvalFailID = approval.id
                model.approvalFailNote = msg
                return
            }
            do {
                _ = try await model.mutate("/approvals/" + approval.id.pathEncoded, fields: fields)
                model.clearApprovalFail()
                failNote = ""
                await onComplete()
            } catch {
                // 卡还在；同步写共享 note，语音路径失败回卡也能看见。
                let msg = "没送出去：" + error.localizedDescription + "——还可以再点一次，或用语音说。不会假装已批/已拒。"
                failNote = msg
                model.approvalFailID = approval.id
                model.approvalFailNote = msg
            }
        }
    }
}

/// The actual recipients/objects/amounts remain visible before any decision.
struct ApprovalScopeView: View {
    let action: JSON
    private var fields: [(String, String)] {
        let args = action["args"].isNull ? action : action["args"]
        let labels = [("to", "收件人"), ("recipient", "接收方"), ("recipients", "接收方"),
                      ("cc", "抄送"), ("bcc", "密送"), ("amount", "金额"), ("currency", "币种"),
                      ("path", "路径"), ("paths", "路径"), ("id", "对象编号"), ("ids", "对象编号"),
                      ("target", "操作对象"), ("subject", "主题"), ("summary", "事项"),
                      ("body", "正文"), ("content", "内容"), ("command", "具体命令")]
        return labels.compactMap { key, label in
            guard !args[key].isNull else { return nil }
            let value = args[key].string.isEmpty ? args[key].pretty : args[key].string
            return value.isEmpty ? nil : (label, value)
        }
    }
    var body: some View {
        if !action.isNull && !action.object.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(field.0).font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                        Text(field.1).font(TypeScale.callout).textSelection(.enabled)
                    }
                }
                RawDetails(title: "查看全部操作参数", value: action)
            }
        }
    }
}
