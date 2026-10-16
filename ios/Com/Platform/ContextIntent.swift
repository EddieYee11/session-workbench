import AppIntents
import Foundation
import ComCore

/// 快捷指令 · 自动化用：「到达公司 / 离开家 / 打开专注」时告诉 Com 此刻的状态，「下一步」拿它当上下文
/// （在公司推工作、到家推生活、专注时只提真正急的）。后台跑，不打开 App；用 App 里已配对的地址和令牌。
enum ComContextKind: String, AppEnum {
    case place, focus
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "状态类型"
    static let caseDisplayRepresentations: [ComContextKind: DisplayRepresentation] = [.place: "地点", .focus: "专注模式"]
}

struct UpdateComContext: AppIntent {
    static let title: LocalizedStringResource = "告诉 Com 我现在的状态"
    static let description = IntentDescription("把此刻在哪、开了什么专注告诉 Com，「下一步」会据此调整建议。适合放进快捷指令的「到达 / 离开 / 专注模式」自动化。")
    static let openAppWhenRun = false

    @Parameter(title: "类型", default: .place) var kind: ComContextKind
    @Parameter(title: "内容", description: "例如：公司、家、岩馆、工作、睡眠") var value: String

    static var parameterSummary: some ParameterSummary { Summary("告诉 Com：\(\.$kind) 是 \(\.$value)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let key = SecureVault.secret("token"), let token = String(data: key, encoding: .utf8), !token.isEmpty else {
            throw APIError(status: 401, detail: "Com 还没配对 Mac mini")
        }
        let base = UserDefaults.standard.string(forKey: "base") ?? "https://pi.eddiegao.work:8443/sessions"
        let api = try APIClient(base: base, token: token)
        _ = try await api.request("/personal/context", body: .object(["kind": .string(kind.rawValue), "value": .string(value)]))
        return .result(dialog: "已告诉 Com：\(value)")
    }
}
