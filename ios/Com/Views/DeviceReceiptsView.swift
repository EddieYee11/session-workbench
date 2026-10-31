import SwiftUI
import ComCore

struct DeviceReceiptsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var records: [JSON] = []
    @State private var working = false
    @State private var note = ""
    @State private var noteFailed = false
    @State private var land = false
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    @State private var report: [JSON] = []
    @State private var reportLoaded = false
    @State private var reportLoading = false
    @State private var reportFail = ""
    private static let domains: [(String, String)] = [
        ("calendar", "日历"), ("reminders", "提醒事项"), ("contacts", "联系人"),
        ("health", "健康"), ("location", "位置"), ("", "设备")]
    private static let actionNames: [String: String] = [
        "calendar.list": "读日历", "calendar.create": "写日历", "calendar.update": "改日历", "calendar.delete": "删日历事件",
        "reminders.list": "读提醒", "reminders.create": "加提醒", "reminders.update": "改提醒", "reminders.delete": "删提醒",
        "contacts.search": "查联系人", "contacts.create": "新建联系人", "contacts.update": "改联系人", "contacts.delete": "删联系人",
        "health.summary": "读健康摘要", "location.last": "读最近位置",
        "apps.list": "读应用列表", "apps.usage": "读应用使用时长", "apps.launch": "打开应用",
        "notifications.list": "读通知", "notifications.dismiss": "清除通知",
        "alarm.set": "设闹钟", "alarm.show": "看闹钟", "media.list": "读相册",
        "device.status": "读设备状态", "device.vibrate": "震动", "device.torch": "开关手电筒", "device.volume": "调音量"]
    private func toolName(_ tool: String) -> String { Self.actionNames[tool] ?? tool }
    private func domainKey(_ tool: String) -> String {
        let head = String(tool.split(separator: ".").first ?? "")
        return Self.domains.contains { $0.0 == head } ? head : ""
    }
    private func reportRows(_ key: String) -> [JSON] { report.filter { domainKey($0["tool"].string) == key } }

    var body: some View {
        ScrollPage(spacing: Space.xl) {
            GroupSection("Com 能做什么", footer: "这些数据由手机发到你自己的 Mac mini，不经过别的服务器。") {
                capabilityBody
            }
            .modifier(EnterRise(on: land, delay: 0, y: 10, blur: 4, animation: ComMotion.rise))
            GroupSection("最近的操作", footer: "在这台手机上动过设备的事都留底；能撤销的会给你按钮，不确定的先查回执，别连点两次。") {
                receiptsBody
            }
        }
        .navigationTitle("这台手机").navigationBarTitleDisplayMode(.inline)
        .refreshable {
            reloadReceipts()
            await loadReport()
        }
        .onAppear {
            reloadReceipts()
            if reduce { land = true }
            else { withAnimation(ComMotion.lift) { land = true } }
        }
        .task { await loadReport() }
    }

    @ViewBuilder private var capabilityBody: some View {
        if !reportFail.isEmpty {
            InlineNotice(text: reportFail, tone: .danger)
            Button(reportLoading ? "重试中…" : "再试一次") { Task { await loadReport() } }
                .buttonStyle(.secondaryCompact).disabled(reportLoading)
                .accessibilityIdentifier("capability-report-retry")
        }
        if reportLoading && !reportLoaded {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("正在读取能力清单…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            }
        }
        if reportLoaded && report.isEmpty && reportFail.isEmpty {
            EmptyState(title: "还没登记任何能力", description: "手机连上 mini 并授权后，这里会列出 Com 能做的事。", symbol: "iphone")
        }
        ForEach(Self.domains, id: \.0) { key, title in
            let rows = reportRows(key)
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(title).font(TypeScale.callout).foregroundStyle(Palette.textSecondary).padding(.horizontal, Space.xs)
                    GroupedCard {
                        ForEach(rows, id: \.["tool"].string) { capabilityRow($0) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                }
            }
        }
    }

    private func capabilityRow(_ item: JSON) -> some View {
        let granted = item["permission"].bool
        let available = item["available"].bool || item["available"].isNull
        let success = item["last_success_at"].double
        let failedAt = item["last_failed_at"].double
        let deniedAt = item["last_denied_at"].double
        let reason = item["last_failed_reason"].string
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(toolName(item["tool"].string)).font(TypeScale.headline)
                Spacer(minLength: Space.sm)
                StatusPill(text: !available ? "不支持" : granted ? "已授权" : "未授权",
                           tone: !available ? .neutral : granted ? .success : .warning)
            }
            if success > 0 {
                Text("最近成功 " + relativeTime(success) + "，" + (item["via_sync"].bool ? "后台同步" : "聊天里用的")
                     + (item["recent_7d"].int > 0 ? "；近 7 天 \(item["recent_7d"].int) 次" : ""))
                    .font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            } else if granted && available {
                Text("还没用过").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            }
            if deniedAt > 0 && deniedAt >= success {
                Text("被拒绝于 " + relativeTime(deniedAt) + "：手机上没给这项权限")
                    .font(TypeScale.footnote).foregroundStyle(Palette.warning)
            }
            if failedAt > 0 && failedAt >= success && !reason.isEmpty {
                Text("失败于 " + relativeTime(failedAt) + "：" + reason)
                    .font(TypeScale.footnote).foregroundStyle(Palette.danger)
            }
            if !granted && available {
                Button("去设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.secondaryCompact)
                .accessibilityIdentifier("capability-settings-" + item["tool"].string)
            }
        }
        .rowPadding()
    }

    @ViewBuilder private var receiptsBody: some View {
        if loading || !loadedOnce {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("正在拉齐设备回执…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            }
            .accessibilityLabel("正在拉齐设备回执")
            .accessibilityIdentifier("device-receipts-pulling")
        }
        if !failNote.isEmpty {
            InlineNotice(text: failNote, tone: .danger)
            Button(loading ? "重试中…" : "再试一次") {
                guard !loading else { return }
                reloadReceipts()
            }
            .buttonStyle(.secondaryCompact)
            .disabled(loading)
            .accessibilityIdentifier("device-receipts-retry")
        }
        if records.isEmpty && loadedOnce && !loading {
            EmptyState(title: failNote.isEmpty ? "还没有设备操作回执" : "回执还没读上",
                       description: failNote.isEmpty
                        ? "用语音或聊天让我操作本机时，结果会记在这里——方便你核对，也能撤销。"
                        : "先重试拉齐本机回执；撤销前请先确认列表能读到。",
                       symbol: "checkmark.seal")
        }
        if !note.isEmpty { InlineNotice(text: note, tone: noteFailed ? .danger : .neutral) }
        ForEach(Array(records.map(RemoteRow.init).enumerated()), id: \.element.id) { index, row in
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(toolName(row.value["tool"].string)).font(TypeScale.headline)
                            let when = relativeTime(row.value["finished_at"].double)
                            if !when.isEmpty { Text(when).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary) }
                        }
                        Spacer()
                        StatusPill(text: displayStatus(row.value["status"].string), tone: row.value["status"].string == "succeeded" ? .success : statusTone(row.value["status"].string))
                    }
                    RawDetails(title: "技术细节", value: row.value["result"])
                    if row.value["status"].string == "succeeded" && row.value["result"]["verified"].bool && !row.value["result"]["undo"].isNull {
                        Button(role: .destructive) { Task { await undo(row.value) } } label: {
                            Text(working ? "撤销中…" : (row.value["undo_requested"].bool ? "已申请撤销，请核对回执" : "撤销此操作"))
                        }
                        .buttonStyle(.quiet)
                        .disabled(working || row.value["undo_requested"].bool)
                        .opacity(working || row.value["undo_requested"].bool ? 0.5 : 1)
                        .accessibilityIdentifier("device-undo-" + row.id)
                    }
                }
            }
            .modifier(EnterRise(on: land, delay: 0.06 + Double(min(index, 6)) * ComMotion.stagger, y: 10, blur: 4, animation: ComMotion.pop))
        }
    }

    private func loadReport() async {
        guard !reportLoading else { return }
        reportLoading = true
        defer { reportLoading = false; reportLoaded = true }
        let path = "/personal/devices/" + model.devices.nodeID.pathEncoded + "/capability-report"
        if let data = await model.load(path) {
            report = data["items"].array
            reportFail = ""
        } else {
            let err = model.errors[path] ?? ""
            reportFail = "能力清单没读上" + (err.isEmpty ? "" : "：" + err) + "——可再试"
        }
    }
    private func reloadReceipts() {
        guard !loading else { return }
        loading = true
        failNote = ""
        defer {
            loading = false
            loadedOnce = true
        }
        let batch = SecureVault.loadRecords(prefix: "invocation-")
        if let err = batch.directoryError, !err.isEmpty {
            failNote = "本机回执目录没读上：" + err + "——可再试"
            // 保留已有列表，别因目录瞬断清空成假空。
            if !records.isEmpty { return }
            records = []
            return
        }
        records = batch.items.sorted { $0["finished_at"].double > $1["finished_at"].double }
        if batch.decodeFailures > 0 {
            failNote = "有 \(batch.decodeFailures) 条回执解不开——下面是能读的；可再试或稍后重开"
        }
    }
    private func undo(_ record: JSON) async {
        guard !working, !record["undo_requested"].bool else { return }
        working = true
        note = ""
        noteFailed = false
        defer { working = false }
        let key = "invocation-" + record.id.pathEncoded
        // 先占坑防连点叠撤销；未验证 / 没送出都回滚，别假锁成「已申请撤销」。
        var claimed = record
        claimed["undo_requested"] = .bool(true)
        do {
            try SecureVault.save(claimed, name: key)
            reloadReceipts()
            guard model.client != nil else {
                _ = clearUndoClaim(record, key: key)
                noteFailed = true
                note = "还没连上 mini——撤销没发出去，可配对后再试。不会假装已撤销。"
                return
            }
            let undo = record["result"]["undo"]
            guard !undo.isNull, !undo["tool"].string.isEmpty else {
                _ = clearUndoClaim(record, key: key)
                noteFailed = true
                note = "这条回执没有可执行的撤销步骤——不能撤销。不会假装已撤销。"
                return
            }
            let result = try await model.mutate(
                "/personal/devices/" + model.devices.nodeID.pathEncoded + "/invoke",
                fields: ["tool": undo["tool"], "args": undo["args"], "timeout": .number(60)]
            )
            let status = result["status"].string
            let verified = result["result"]["verified"].bool
            let ok = status == "succeeded" && verified
            if ok {
                noteFailed = false
                note = "撤销已回读验证"
                reloadReceipts()
                return
            }
            // 服务有回但未验证：回滚占坑，允许再点；勿保持「已申请」假成功。
            let unlocked = clearUndoClaim(record, key: key)
            noteFailed = true
            let detail = result["result"]["error"].string.isEmpty ? status : result["result"]["error"].string
            note = unlocked
                ? "撤销尚未验证：" + (detail.isEmpty ? "结果不清" : detail) + "——还可以再试。不会假装已撤销。"
                : "撤销尚未验证，且本地解锁失败——下拉刷新后再看。不会假装已撤销。"
            reloadReceipts()
        } catch {
            let unlocked = clearUndoClaim(record, key: key)
            noteFailed = true
            note = unlocked
                ? "撤销没送出去：" + error.localizedDescription + "——还可以再试。不会假装已撤销。"
                : "撤销没送出去，且本地解锁失败——下拉刷新后再试。不会假装已撤销。"
            reloadReceipts()
        }
    }
    /// 清掉 undo_requested 占坑。true = 已写回可再点。
    @discardableResult
    private func clearUndoClaim(_ record: JSON, key: String) -> Bool {
        var restored = record
        restored["undo_requested"] = .bool(false)
        do {
            try SecureVault.save(restored, name: key)
            return true
        } catch {
            return false
        }
    }
}
