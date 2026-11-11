import SwiftUI
import ComCore

// MARK: - 动作类型与草稿契约

public enum MicroActionType: String, Sendable, CaseIterable {
    case bookkeep
    case calendar
    case replyMail = "reply_mail"
    case replyWechat = "reply_wechat"
    case reminder
}

public struct MicroSheetPayload: Equatable, Identifiable, Sendable {
    public let id: String              // matter_id 或 item.id
    public let title: String           // 卡片标题
    public let sourceWhy: String       // 依据说明
    public let actionType: MicroActionType
    public var rawPayload: JSON        // 预填参数

    public init(id: String, title: String, sourceWhy: String, actionType: MicroActionType, rawPayload: JSON) {
        self.id = id
        self.title = title
        self.sourceWhy = sourceWhy
        self.actionType = actionType
        self.rawPayload = rawPayload
    }

    /// 便利构造器：支持 (matterId:action:) 及可选 title/why 补齐
    public init(matterId: String, action: JSON, title: String = "", why: String = "") {
        let typeStr = action["type"].string
        let mType = MicroActionType(rawValue: typeStr) ?? .bookkeep
        let resolvedTitle = !title.isEmpty ? title : action["title"].string
        let resolvedWhy = !why.isEmpty ? why : action["why"].string
        self.init(
            id: matterId,
            title: resolvedTitle,
            sourceWhy: resolvedWhy,
            actionType: mType,
            rawPayload: action
        )
    }
}

// MARK: - 本地草稿隔离模型 (防止后台 SSE 推流冲刷正在编辑的内容)

@Observable
public final class MicroDraftStore {
    public var isDirty: Bool = false
    public var isSubmitting: Bool = false
    public var errorMessage: String = ""
    public var isSettled: Bool = false
    public var settledNote: String = ""

    // 记账字段
    public var amountText: String = ""
    public var category: String = "餐饮美食"
    public var account: String = "招商银行储蓄卡"
    public var note: String = ""

    // 日程字段
    public var calendarTitle: String = ""
    public var startDate: Date = Date()
    public var endDate: Date = Date().addingTimeInterval(3600)
    public var calendarLocation: String = ""

    // 邮件草稿字段
    public var mailTo: String = ""
    public var mailSubject: String = ""
    public var mailDraft: String = ""

    public init(payload: MicroSheetPayload) {
        let p = payload.rawPayload
        switch payload.actionType {
        case .bookkeep:
            let amt = p["amount"].double
            self.amountText = amt > 0 ? String(format: "%.2f", amt) : (p["amount"].string.isEmpty ? "0.00" : p["amount"].string)
            self.category = p["category"].string.isEmpty ? "餐饮美食" : p["category"].string
            self.account = p["account"].string.isEmpty ? "招商银行储蓄卡" : p["account"].string
            self.note = p["note"].string.isEmpty ? p["comment"].string : p["note"].string
        case .calendar:
            self.calendarTitle = p["title"].string.isEmpty ? payload.title : p["title"].string
            self.calendarLocation = p["location"].string
            if let startSec = ISO8601DateFormatter().date(from: p["start"].string) {
                self.startDate = startSec
            }
            if let endSec = ISO8601DateFormatter().date(from: p["end"].string) {
                self.endDate = endSec
            }
        case .replyMail:
            self.mailTo = p["to"].string
            self.mailSubject = p["subject"].string
            self.mailDraft = p["draft"].string
        default:
            break
        }
    }
}

// MARK: - 就地轻确认微卡视图 (MicroSheetView)

public struct MicroSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let payload: MicroSheetPayload
    let onSettled: @MainActor (String) -> Void

    @State private var draft: MicroDraftStore
    @FocusState private var focusedField: Field?

    private enum Field {
        case amount, note, calTitle, calLocation, mailDraft
    }

    public init(payload: MicroSheetPayload, onSettled: @escaping @MainActor (String) -> Void) {
        self.payload = payload
        self.onSettled = onSettled
        self._draft = State(initialValue: MicroDraftStore(payload: payload))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)
                .padding(.bottom, Space.sm)

            Divider().background(Palette.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if !payload.sourceWhy.isEmpty {
                        sourceHintView
                    }

                    if !draft.errorMessage.isEmpty {
                        Text(draft.errorMessage)
                            .font(TypeScale.footnote)
                            .foregroundStyle(Palette.danger)
                            .padding(.vertical, 4)
                    }

                    if draft.isSettled {
                        settledBannerView
                    } else {
                        formContentView
                    }
                }
                .padding(Space.lg)
            }

            Divider().background(Palette.separator)

            footerActionsView
                .padding(Space.md)
                .background(Palette.surface)
        }
        .background(Palette.background)
        .presentationDetents([.fraction(0.58), .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 子视图

    private var headerView: some View {
        HStack {
            Image(systemName: iconName(for: payload.actionType))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.accentText)
            Text(titleText(for: payload.actionType))
                .font(TypeScale.headline)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .disabled(draft.isSubmitting)
        }
    }

    private var sourceHintView: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textTertiary)
            Text(payload.sourceWhy)
                .font(TypeScale.footnote)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    @ViewBuilder
    private var formContentView: some View {
        switch payload.actionType {
        case .bookkeep:
            bookkeepForm
        case .calendar:
            calendarForm
        case .replyMail:
            mailForm
        default:
            Text("支持原地轻确认闭环")
                .font(TypeScale.subheadline)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var bookkeepForm: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // 金额输入区
            VStack(alignment: .leading, spacing: 4) {
                Text("金额 (元)").font(TypeScale.caption.weight(.medium)).foregroundStyle(Palette.textSecondary)
                HStack(spacing: 4) {
                    Text("¥").font(.system(size: 26, weight: .bold)).foregroundStyle(Palette.textPrimary)
                    TextField("0.00", text: $draft.amountText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .amount)
                        .onChange(of: draft.amountText) { _, _ in draft.isDirty = true }
                }
                .padding(.bottom, 4)
            }

            // 分类选择
            VStack(alignment: .leading, spacing: 4) {
                Text("分类").font(TypeScale.caption.weight(.medium)).foregroundStyle(Palette.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["餐饮美食", "出行交通", "购物消费", "娱乐休闲", "居住房租", "其他支出"], id: \.self) { cat in
                            Button {
                                draft.category = cat
                                draft.isDirty = true
                                Haptics.selection()
                            } label: {
                                Text(cat)
                                    .font(TypeScale.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(draft.category == cat ? Palette.accent.opacity(0.18) : Palette.fill, in: Capsule())
                                    .overlay(Capsule().strokeBorder(draft.category == cat ? Palette.accent : Color.clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // 账户选择
            VStack(alignment: .leading, spacing: 4) {
                Text("支出账户").font(TypeScale.caption.weight(.medium)).foregroundStyle(Palette.textSecondary)
                Picker("账户", selection: $draft.account) {
                    Text("招商银行").tag("招商银行储蓄卡")
                    Text("微信零钱").tag("微信零钱")
                    Text("支付宝").tag("支付宝")
                    Text("现金").tag("现金")
                }
                .pickerStyle(.segmented)
            }

            // 备注信息
            VStack(alignment: .leading, spacing: 4) {
                Text("备注").font(TypeScale.caption.weight(.medium)).foregroundStyle(Palette.textSecondary)
                TextField("填写消费说明", text: $draft.note)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .note)
                    .onChange(of: draft.note) { _, _ in draft.isDirty = true }
            }
        }
    }

    private var calendarForm: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("日程标题").font(TypeScale.caption.weight(.medium)).foregroundStyle(Palette.textSecondary)
                TextField("日程名称", text: $draft.calendarTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .calTitle)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("地点（可选）").font(TypeScale.caption.weight(.medium)).foregroundStyle(Palette.textSecondary)
                TextField("地点", text: $draft.calendarLocation)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .calLocation)
            }

            DatePicker("开始时间", selection: $draft.startDate, displayedComponents: [.date, .hourAndMinute])
                .font(TypeScale.subheadline)
            DatePicker("结束时间", selection: $draft.endDate, displayedComponents: [.date, .hourAndMinute])
                .font(TypeScale.subheadline)
        }
    }

    private var mailForm: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("收件人:").font(TypeScale.caption.weight(.medium)).foregroundStyle(Palette.textSecondary)
                Text(draft.mailTo).font(TypeScale.subheadline.weight(.semibold))
            }
            Text("主题: " + draft.mailSubject).font(TypeScale.subheadline)

            VStack(alignment: .leading, spacing: 4) {
                Text("邮件正文草稿").font(TypeScale.caption.weight(.medium)).foregroundStyle(Palette.textSecondary)
                TextEditor(text: $draft.mailDraft)
                    .frame(minHeight: 120)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Palette.separator, lineWidth: 1))
            }
        }
    }

    private var settledBannerView: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Palette.success)
            Text(draft.settledNote)
                .font(TypeScale.headline)
                .foregroundStyle(Palette.textPrimary)
            Text("已就地闭环，未向主聊天插入冗余发言")
                .font(TypeScale.footnote)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
    }

    private var footerActionsView: some View {
        HStack(spacing: Space.md) {
            if !draft.isSettled {
                Button {
                    submitAction()
                } label: {
                    HStack {
                        if draft.isSubmitting {
                            ProgressView().tint(.white).padding(.trailing, 4)
                        }
                        Text(confirmButtonTitle(for: payload.actionType))
                            .font(TypeScale.headline)
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: Radius.md))
                }
                .buttonStyle(.plain)
                .disabled(draft.isSubmitting)
            } else {
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.md))
            }
        }
    }

    // MARK: - 提交闭环逻辑 (直调领域 API，零切 Tab，零发假消息)

    private func submitAction() {
        guard !draft.isSubmitting else { return }
        draft.isSubmitting = true
        draft.errorMessage = ""

        Task {
            do {
                switch payload.actionType {
                case .bookkeep:
                    guard let amt = Double(draft.amountText), amt > 0 else {
                        draft.errorMessage = "请输入有效且大于 0 的金额"
                        draft.isSubmitting = false
                        return
                    }
                    let fields: [String: JSON] = [
                        "action": .string("done"),
                        "action_type": .string("bookkeep"),
                        "amount": .number(amt),
                        "category": .string(draft.category),
                        "account": .string(draft.account),
                        "comment": .string(draft.note)
                    ]
                    _ = try await model.mutate("/personal/matter/" + payload.id.pathEncoded + "/action", fields: fields)

                    withAnimation {
                        draft.isSettled = true
                        draft.settledNote = "已记入账本 ¥\(String(format: "%.2f", amt)) · \(draft.category)"
                    }
                    Haptics.success()
                    onSettled(draft.settledNote)
                    try? await Task.sleep(for: .milliseconds(1100))
                    dismiss()

                case .calendar:
                    let formatter = ISO8601DateFormatter()
                    let fields: [String: JSON] = [
                        "action": .string("done"),
                        "action_type": .string("calendar"),
                        "title": .string(draft.calendarTitle),
                        "start": .string(formatter.string(from: draft.startDate)),
                        "end": .string(formatter.string(from: draft.endDate)),
                        "location": .string(draft.calendarLocation)
                    ]
                    _ = try await model.mutate("/personal/matter/" + payload.id.pathEncoded + "/action", fields: fields)

                    withAnimation {
                        draft.isSettled = true
                        draft.settledNote = "已添加日程「\(draft.calendarTitle)」"
                    }
                    Haptics.success()
                    onSettled(draft.settledNote)
                    try? await Task.sleep(for: .milliseconds(1100))
                    dismiss()

                case .replyMail:
                    var parts = URLComponents()
                    parts.scheme = "mailto"
                    parts.path = draft.mailTo
                    parts.queryItems = [
                        URLQueryItem(name: "subject", value: draft.mailSubject),
                        URLQueryItem(name: "body", value: draft.mailDraft)
                    ]
                    if let url = parts.url { openURL(url) }

                    _ = try await model.mutate("/personal/matter/" + payload.id.pathEncoded + "/action", fields: ["action": .string("drafted")])
                    withAnimation {
                        draft.isSettled = true
                        draft.settledNote = "已调起邮件草稿"
                    }
                    Haptics.success()
                    onSettled(draft.settledNote)
                    try? await Task.sleep(for: .milliseconds(1000))
                    dismiss()

                default:
                    dismiss()
                }
            } catch {
                draft.isSubmitting = false
                draft.errorMessage = "操作失败：" + error.localizedDescription
                Haptics.error()
            }
        }
    }

    // MARK: - 辅助方法

    private func iconName(for type: MicroActionType) -> String {
        switch type {
        case .bookkeep: return "creditcard.fill"
        case .calendar: return "calendar.badge.clock"
        case .replyMail: return "envelope.fill"
        case .replyWechat: return "bubble.left.fill"
        case .reminder: return "bell.fill"
        }
    }

    private func titleText(for type: MicroActionType) -> String {
        switch type {
        case .bookkeep: return "确认记入账本"
        case .calendar: return "确认添加日程"
        case .replyMail: return "确认邮件草稿"
        case .replyWechat: return "确认微信回复"
        case .reminder: return "确认添加提醒"
        }
    }

    private func confirmButtonTitle(for type: MicroActionType) -> String {
        switch type {
        case .bookkeep: return "确认记账"
        case .calendar: return "确认添加"
        case .replyMail: return "调起邮件发送"
        default: return "确认执行"
        }
    }
}
