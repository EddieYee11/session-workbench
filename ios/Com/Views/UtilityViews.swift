import SwiftUI
import WebKit
import ComCore
import QuickLook

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("appearance") private var appearance = "light"
    @AppStorage("appLockEnabled") private var appLock = false
    @AppStorage("voice.pauseToSend") private var voicePause = 0.9
    @State private var showPairCode = false
    @State private var disconnecting = false
    @State private var notificationNote = ""
    @State private var shown = false
    /// 发送记录「查回执」门控：失败留页提示，防连点。
    @State private var receiptBusyID: String?
    @State private var receiptNote = ""
    /// 刷新连接 / 服务器状态 / 全量同步 / 解除配对：防连点。
    @State private var linkBusy = false
    @State private var statusBusy = false
    @State private var statusFail = ""
    @State private var statusLoadedOnce = false
    @State private var syncBusy = false
    @State private var unpairing = false
    /// 解除配对 / 推送注销失败开口（别只靠关掉设置假装没事）。
    @State private var unpairNote = ""
    /// 正在请求系统授权的 domain；非空时防连点叠弹系统框。
    @State private var authBusyDomain: String?
    /// 权限授权失败开口（别只靠连接区 devices.note）。
    @State private var authNote = ""
    @State private var authFailed = false
    @State private var notifyBusy = false
    private var statusPulling: Bool { model.settingsOpening || statusBusy || !statusLoadedOnce }
    /// 权限已开但远程推送未 ready：可再点上报。
    private var pushRegisterNeedsRetry: Bool {
        UserDefaults.standard.bool(forKey: ComNotifications.enabledKey)
            && !UserDefaults.standard.bool(forKey: ComPush.readyKey)
            && model.isPaired
    }
    var body: some View {
        @Bindable var devices = model.devices!
        let unresolved = SecureVault.operationRecords().filter { $0["status"].string == "unknown" }
        NavigationStack {
            ScrollPage(spacing: Space.xxl) {
                if statusPulling {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("正在拉齐服务器状态…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    }
                    .accessibilityLabel("正在拉齐设置")
                    .accessibilityIdentifier("settings-status-pulling")
                }
                if !statusFail.isEmpty {
                    InlineNotice(text: statusFail, tone: .danger)
                    Button(statusBusy || model.settingsOpening ? "重试中…" : "再试一次") {
                        guard !statusBusy, !model.settingsOpening else { return }
                        Task { await refreshStatus(force: true) }
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(statusBusy || model.settingsOpening)
                    .accessibilityIdentifier("settings-status-retry")
                }
                Text(model.isPaired ? "配对着 Mac mini。通知、语音和外观在下面调；动效跟随系统「减少动态效果」。" : "还没配对。先连上 mini，再来管通知和权限。")
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .modifier(EnterRise(on: shown, delay: 0, y: 12, blur: 5, animation: ComMotion.rise))
                NavigationLink { AgencySettings() } label: { NavigationRowLabel(title: "主动性与晨晚报", symbol: "sun.max") }.buttonStyle(.row)
                    .modifier(EnterRise(on: shown, delay: 0.04, y: 10, blur: 4, animation: ComMotion.pop))
                settingsGroup(title: "主动消息通知", footer: "晨报与主动消息写入主聊天。后台读取由 iOS 安排，可能延迟；08:00–23:00 通知，锁屏不显示对话正文。权限开了不等于远程推送已通——上报失败会在这里说明。") {
                    Button(notifyBusy ? "请求中…" : "开启新消息通知", systemImage: "bell.badge") {
                        guard !notifyBusy else { return }
                        notifyBusy = true
                        Task {
                            let result = await ComNotifications.enable()
                            notificationNote = result.note
                            notifyBusy = false
                        }
                    }
                    .buttonStyle(.quiet).rowPadding()
                    .disabled(notifyBusy)
                    .accessibilityIdentifier("settings-notify-enable")
                    if pushRegisterNeedsRetry {
                        Button(notifyBusy ? "上报中…" : "再试一次上报") {
                            guard !notifyBusy else { return }
                            notifyBusy = true
                            Task {
                                ComPush.register()
                                if SecureVault.secret("apns-token") != nil {
                                    _ = await ComPush.registerToken()
                                }
                                notificationNote = UserDefaults.standard.string(forKey: ComPush.statusKey)
                                    ?? (UserDefaults.standard.bool(forKey: ComPush.readyKey)
                                        ? "系统推送已接通"
                                        : "还在等系统推送 token——稍后再试。不会假装推送已通。")
                                notifyBusy = false
                            }
                        }
                        .buttonStyle(.secondaryCompact)
                        .disabled(notifyBusy)
                        .padding(.horizontal, Space.lg)
                        .accessibilityIdentifier("settings-push-retry")
                    }
                    if !notificationNote.isEmpty {
                        InlineNotice(
                            text: notificationNote,
                            tone: notificationNoteLooksFailed(notificationNote) ? .danger : .neutral
                        )
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.sm)
                        .accessibilityIdentifier("settings-notify-note")
                    }
                }
                settingsGroup(title: "快捷语音", footer: "设置 → 操作按钮 → 快捷指令 → Com 语音。打开即录音；停顿达到设定时长自动转写并发送。说「停 / 取消 / 不用了」只会结束这次录音，不发送。") {
                    Button { dismiss(); model.openVoice(quick: true) } label: { NavigationRowLabel(title: "打开光效语音小窗", symbol: "waveform") }.buttonStyle(.row)
                    HStack {
                        Text("停顿多久自动发送").font(TypeScale.callout)
                        Spacer()
                        Picker("停顿多久自动发送", selection: $voicePause) {
                            Text("0.6 秒").tag(0.6); Text("0.9 秒").tag(0.9); Text("1.2 秒").tag(1.2); Text("1.8 秒").tag(1.8)
                        }.pickerStyle(.menu).tint(Palette.textSecondary)
                    }.padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                }
                settingsGroup(title: "外观", footer: "大字体、VoiceOver、减少动态效果和降低透明度跟随系统设置。") {
                    HStack {
                        Text("主题").font(TypeScale.callout)
                        Spacer()
                        Picker("主题", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                            .pickerStyle(.menu).tint(Palette.textSecondary)
                    }.padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                }
                settingsGroup(title: "隐私", footer: "开启后，离开 Com 超过 30 秒回来要先解锁；切到后台时先盖上，任务切换器里不会露出对话。只保护本机界面，不改变服务端权限。") {
                    Toggle("应用锁（Face ID / 设备密码）", isOn: $appLock)
                        .font(TypeScale.callout).tint(Palette.accentText)
                        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                        .disabled(!AppLock.shared.available)
                    if appLock {
                        Button("立即上锁") { AppLock.shared.lockNow(); dismiss() }
                            .buttonStyle(.quiet).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                    }
                    if !AppLock.shared.available {
                        Text("这台手机还没设锁屏密码，系统不让我开应用锁。先到系统设置里设一个。")
                            .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).rowPadding()
                    }
                }
                settingsGroup(title: "连接", footer: "手机退到后台后，任务继续在 mini 上执行。重新打开时会补取最新状态。") {
                    settingsRow(label: "服务", value: model.base)
                    settingsRow(label: "实时对话", value: model.streaming ? "已连接" : (model.streamNote.isEmpty ? "缓存模式" : "重连中（缓存）"))
                    settingsRow(label: "手机能力", value: devices.connected ? "已连接" : "未连接")
                    if !devices.note.isEmpty { Text(devices.note).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary).frame(maxWidth: .infinity, alignment: .leading).rowPadding() }
                    Button(linkBusy ? "刷新中…" : "刷新连接") {
                        guard !linkBusy else { return }
                        linkBusy = true
                        Task {
                            await model.setActive(true)
                            linkBusy = false
                        }
                    }
                    .buttonStyle(.quiet).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                    .disabled(linkBusy || unpairing)
                    .accessibilityIdentifier("settings-refresh-link")
                    Button { showPairCode = true } label: { NavigationRowLabel(title: "配对另一台设备", symbol: "qrcode") }.buttonStyle(.row)
                        .disabled(unpairing)
                }
                settingsGroup(title: "服务器", footer: "只读诊断，不会重启或改动 mini。审批数、运行中会话和可用 Agent 来自 /status；磁盘是 mini 用户目录所在卷。") {
                    let status = model.datasets["/status"] ?? .null
                    let blank = status.isNull || (status["host"].string.isEmpty && status["index"].isNull && !statusFail.isEmpty)
                    settingsRow(label: "主机", value: statusPulling && status["host"].string.isEmpty ? "拉齐中…" : (status["host"].string.isEmpty ? (statusFail.isEmpty ? "Mac mini" : "未读上") : status["host"].string))
                    settingsRow(label: "已索引会话", value: statusPulling && status.isNull ? "拉齐中…" : (blank ? "—" : "\(status["index"].int) · 运行中 \(status["running"].int)"))
                    settingsRow(label: "等你审批", value: statusPulling && status.isNull ? "拉齐中…" : (blank ? "—" : "\(status["approvals"].int)"))
                    settingsRow(label: "可用 Agent", value: blank && !statusPulling ? "—" : [status["agents"]["pi"].bool ? "Pi" : "", status["agents"]["codex"].bool ? "Codex" : ""].filter { !$0.isEmpty }.joined(separator: " / "))
                    settingsRow(label: "磁盘余量", value: statusPulling && status.isNull ? "拉齐中…" : (blank ? "—" : String(format: "%.1f GB", status["disk_free_gb"].double)))
                    settingsRow(label: "通知通道", value: blank && !statusPulling ? "—" : (status["push"].string.isEmpty ? "后台刷新" : status["push"].string))
                    settingsRow(label: "已运行", value: statusPulling && status.isNull ? "拉齐中…" : (blank ? "—" : "\(status["uptime"].int / 3600) 小时"))
                    Button(statusBusy || model.settingsOpening ? "刷新中…" : "刷新服务器状态") {
                        guard !statusBusy, !model.settingsOpening else { return }
                        Task { await refreshStatus(force: true) }
                    }
                    .buttonStyle(.quiet).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                    .disabled(statusBusy || model.settingsOpening || unpairing)
                    .accessibilityIdentifier("settings-refresh-status")
                }
                settingsGroup(title: "数据来源") {
                    NavigationLink { ConnectionsView() } label: { NavigationRowLabel(title: "管理数据连接", symbol: "link") }.buttonStyle(.row)
                }
                GroupSection("本机健康数据", footer: "读取留在本机；同步到 mini 在下面单独开启。") { HealthCard() }
                settingsGroup(title: "首次使用时授权") {
                    if !authNote.isEmpty {
                        InlineNotice(text: authNote, tone: authFailed ? .danger : .neutral)
                            .padding(.horizontal, Space.lg)
                            .padding(.vertical, Space.sm)
                            .accessibilityIdentifier("settings-auth-note")
                    }
                    permission("健康 · 只读", "heart", "health")
                    permission("日历", "calendar", "calendar")
                    permission("提醒事项", "checklist", "reminders")
                    permission("联系人", "person.crop.circle", "contacts")
                    permission("使用期间的位置", "location", "location")
                    Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: {
                        NavigationRowLabel(title: "打开系统权限设置", symbol: "gear")
                    }.buttonStyle(.row)
                }
                settingsGroup(title: "设备结果同步", footer: "开启后，已授权范围内的数据可供 mini 处理你的交办。健康包括步数、活动能量、心率、静息心率、睡眠和运动；联系人查询仅返回符合交办条件的结果。关闭会停止后续设备读取；已交办的结果可能已保存在服务端。开关亮了不等于服务器已按新范围同步。") {
                    Toggle("向 mini 提供健康摘要", isOn: $devices.healthSync).font(TypeScale.callout).tint(Palette.accentText).padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                    Toggle("向 mini 提供联系人查询结果", isOn: $devices.contactsSync).font(TypeScale.callout).tint(Palette.accentText).padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                    if !devices.syncNote.isEmpty {
                        InlineNotice(text: devices.syncNote, tone: .warning)
                            .padding(.horizontal, Space.lg)
                            .padding(.vertical, Space.sm)
                            .accessibilityIdentifier("settings-sync-note")
                    }
                }
                .onChange(of: devices.healthSync) { _, _ in Task { await devices.updateSync() } }
                .onChange(of: devices.contactsSync) { _, _ in Task { await devices.updateSync() } }
                GroupedCard {
                    Button { dismiss(); model.openShareInbox() } label: { NavigationRowLabel(title: "分享收件箱", symbol: "tray.and.arrow.down") }.buttonStyle(.row)
                }
                settingsGroup(title: "发送记录") {
                    if model.pending.isEmpty {
                        Text("还没有本机发送记录。发出去但回执不确定的，会出现在这里，方便你查回执。").font(TypeScale.callout).foregroundStyle(Palette.textSecondary).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                    } else {
                        if !receiptNote.isEmpty {
                            InlineNotice(text: receiptNote, tone: .danger)
                                .padding(.horizontal, Space.lg)
                                .padding(.vertical, Space.sm)
                                .accessibilityIdentifier("settings-receipt-fail")
                        }
                        ForEach(Array(model.pending.reversed().enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(entry.text.isEmpty ? "恢复工作会话" : entry.text).font(TypeScale.callout).lineLimit(3)
                                Text(entry.note + " · " + entry.createdAt.formatted(date: .abbreviated, time: .shortened)).font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                                if entry.state == .uncertain || entry.state == .checking {
                                    Button(receiptBusyID == entry.id ? "查询中…" : "查询原请求回执") {
                                        guard receiptBusyID == nil else { return }
                                        receiptBusyID = entry.id
                                        receiptNote = ""
                                        Task {
                                            let id = entry.id
                                            if entry.path.hasPrefix("/sessions") {
                                                _ = await model.deliverWork(id)
                                            } else {
                                                _ = await model.deliver(id)
                                            }
                                            let after = model.pending.first(where: { $0.id == id })
                                            let state = after?.state
                                            let detail = after?.note ?? ""
                                            if state == .delivered {
                                                receiptNote = ""
                                            } else if state == .rejected {
                                                receiptNote = detail.isEmpty
                                                    ? "没送出去——可用「恢复文字到聊天草稿」再试。不会假装已核实。"
                                                    : "没送出去：" + detail + "——可恢复草稿再试。不会假装已核实。"
                                            } else {
                                                receiptNote = detail.isEmpty
                                                    ? "回执仍待核实——还可以再查（不会重复提交）。别当成已发出。"
                                                    : "回执仍待核实：" + detail + "——可再查（不会重复提交）。别当成已发出。"
                                            }
                                            receiptBusyID = nil
                                        }
                                    }
                                    .buttonStyle(.quiet).padding(.top, Space.xs)
                                    .disabled(receiptBusyID != nil)
                                    .accessibilityIdentifier("settings-check-receipt")
                                }
                                if entry.state == .rejected {
                                    Button("恢复文字到聊天草稿") { model.draft = entry.text; model.tab = .chat; dismiss(); model.persistNow() }.buttonStyle(.quiet).padding(.top, Space.xs)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                        }
                    }
                }
                if !unresolved.isEmpty {
                    settingsGroup(title: "送达待核实的操作", footer: "先更新任务、记忆或日程结果，核对后再决定下一步。这里不会自动重发操作。") {
                        ForEach(Array(unresolved.enumerated()), id: \.offset) { _, record in RawDetails(title: "查看原请求与操作内容", value: record).rowPadding() }
                        Button(syncBusy ? "更新中…" : "更新服务端状态") {
                            guard !syncBusy else { return }
                            syncBusy = true
                            Task {
                                await model.refreshAll()
                                syncBusy = false
                            }
                        }
                        .buttonStyle(.quiet).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                        .disabled(syncBusy || unpairing)
                        .accessibilityIdentifier("settings-refresh-all")
                    }
                }
                settingsGroup(title: "平台能力", footer: "iOS 不支持读取其他 App 的全部通知、列出所有应用或任意操作其他 App。免费账号签名需要定期重新安装，首版没有锁屏实时远程推送。") {
                    if !model.liveActivityNote.isEmpty {
                        InlineNotice(text: model.liveActivityNote, tone: .warning)
                            .accessibilityIdentifier("settings-live-activity-fail")
                            .rowPadding()
                    }
                    if !model.widgetUpdateNote.isEmpty {
                        InlineNotice(text: model.widgetUpdateNote, tone: .warning)
                            .accessibilityIdentifier("settings-widget-update-fail")
                            .rowPadding()
                    }
                    DisclosureGroup("能力与授权明细") {
                        VStack(spacing: 0) {
                            ForEach(Array(devices.capabilities.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top) {
                                    Text(item["tool"].string).font(TypeScale.subheadline)
                                    Spacer()
                                    Text(!item["available"].bool ? "不支持" : item["permission"].bool ? "可用" : "未授权 / 同步关闭").font(TypeScale.subheadline).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.trailing)
                                }.padding(.vertical, Space.xs + 2)
                            }
                        }.padding(.top, Space.sm)
                    }.font(TypeScale.callout).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary).rowPadding()
                    NavigationLink { DeviceReceiptsView() } label: { NavigationRowLabel(title: "设备操作回执与撤销") }.buttonStyle(.row)
                }
                if !unpairNote.isEmpty {
                    InlineNotice(text: unpairNote, tone: .danger)
                        .accessibilityIdentifier("settings-unpair-fail")
                }
                GroupedCard {
                    Button(role: .destructive) { disconnecting = true; unpairNote = "" } label: {
                        Text(unpairing ? "正在解除…" : "解除本机配对")
                            .font(TypeScale.callout.weight(.medium))
                            .foregroundStyle(Palette.danger)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .rowPadding()
                    }
                    .buttonStyle(.row)
                    .disabled(unpairing)
                    .accessibilityIdentifier("settings-unpair")
                }
            }.navigationTitle("设置").navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Palette.background, for: .navigationBar)
                .toolbar {
                    if statusPulling {
                        ToolbarItem(placement: .topBarLeading) {
                            ProgressView().controlSize(.small).accessibilityLabel("正在拉齐设置")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.disabled(unpairing) }
                }
                .confirmationDialog("解除配对后本机保留草稿与缓存", isPresented: $disconnecting, titleVisibility: .visible) {
                    Button(unpairing ? "正在解除…" : "解除配对", role: .destructive) {
                        guard !unpairing else { return }
                        unpairing = true
                        unpairNote = ""
                        Task {
                            let r = await model.disconnect()
                            unpairing = false
                            if r.unpaired {
                                if r.pushCleared {
                                    dismiss()
                                } else {
                                    // 本机已断；推送注销失败留页开口，别假装服务器也清干净了。
                                    unpairNote = "本机已解除配对；服务器推送注销没成——可关掉设置，稍后重连再核对。不会假装还连着 mini。"
                                }
                            } else {
                                unpairNote = "解除没成——还可以再试。不会假装已断对。"
                            }
                        }
                    }
                    .disabled(unpairing)
                }
                .sheet(isPresented: $showPairCode) { PairCodeSheet() }
                // 打开即刷 /status（与 openSettings 同路）；审批数 / 运行中别停在旧快照。
                .task { await refreshStatus(force: false) }
                .onAppear {
                    if reduce { shown = true }
                    else { withAnimation(ComMotion.rise) { shown = true } }
                    refreshPushNoteFromDefaults()
                }
        }
    }
    private func notificationNoteLooksFailed(_ text: String) -> Bool {
        ["未开启", "没成", "没报", "没给", "没存", "没有远程", "未接通", "不会假装"].contains { text.contains($0) }
            && !text.contains("系统推送已接通")
    }
    /// 进设置时带上上次 token 上报结果——别让人只看见「通知已开启」却不知推送没通。
    private func refreshPushNoteFromDefaults() {
        guard model.isPaired, notificationNote.isEmpty else { return }
        if UserDefaults.standard.bool(forKey: ComPush.readyKey) { return }
        guard UserDefaults.standard.bool(forKey: ComNotifications.enabledKey),
              let status = UserDefaults.standard.string(forKey: ComPush.statusKey), !status.isEmpty else { return }
        notificationNote = status
    }
    private func refreshStatus(force: Bool) async {
        guard !statusBusy else { return }
        statusBusy = true
        if force { statusFail = "" }
        defer {
            statusBusy = false
            statusLoadedOnce = true
        }
        let path = "/status"
        let ok: Bool
        // 与 openSettings 同路：入口已在拉则等它结束，避免叠刷。
        if model.settingsOpening && !force {
            while model.settingsOpening && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
            }
            ok = model.errors[path] == nil && model.datasets[path] != nil
        } else {
            ok = await model.load(path) != nil
        }
        if ok {
            statusFail = ""
            model.settingsOpenNote = ""
            return
        }
        let err = model.errors[path] ?? ""
        let hadCache = model.datasets[path] != nil
        statusFail = err.isEmpty
            ? (hadCache ? "服务器状态没刷新上——下面仍是上一版，可再试" : "服务器状态没拉齐——检查配对或网络后再试")
            : (hadCache ? "状态没刷新上：" + err + "——下面仍是上一版" : "状态没拉齐：" + err + "——可再试")
    }
    @ViewBuilder private func settingsGroup(title: String, footer: String = "", @ViewBuilder content: () -> some View) -> some View {
        GroupSection(title, footer: footer) { GroupedCard { content() } }
    }
    private func settingsRow(label: String, value: String) -> some View {
        KeyValueRow(label: label, value: value)
    }
    private func permission(_ title: String, _ symbol: String, _ domain: String) -> some View {
        let busy = authBusyDomain == domain
        return Button {
            guard authBusyDomain == nil else { return }
            authBusyDomain = domain
            authNote = ""
            authFailed = false
            Task {
                let ok = await model.devices.authorize(domain)
                authNote = model.devices.note
                authFailed = !ok || authNote.contains("没成") || authNote.contains("拒绝")
                authBusyDomain = nil
            }
        } label: {
            NavigationRowLabel(title: busy ? "\(title) · 请求中…" : title, symbol: symbol)
        }
        .buttonStyle(.row)
        .disabled(authBusyDomain != nil || unpairing)
        .accessibilityIdentifier("settings-auth-" + domain)
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var query = ""
    @State private var results: [JSON] = []
    @State private var note = ""
    @State private var shown = false
    /// 正在打开某条命中：防连点叠定位。
    @State private var openingID: String?
    /// 定位失败后可再试的那条命中。
    @State private var retryHit: JSON?
    @State private var artifactsLoading = false
    @State private var artifactsFail = ""
    @State private var artifactsLoadedOnce = false
    private var artifactsPulling: Bool { model.searchOpening || artifactsLoading || !artifactsLoadedOnce }
    var body: some View {
        NavigationStack {
            ScrollPage {
                SearchField(text: $query, prompt: "聊天、任务或成果名称")
                    .modifier(EnterRise(on: shown, delay: 0, y: 10, blur: 4, animation: ComMotion.pop))
                if artifactsPulling {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("正在拉齐成果…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    }
                    .accessibilityLabel("正在拉齐搜索")
                    .accessibilityIdentifier("search-pulling")
                }
                if !artifactsFail.isEmpty && query.isEmpty {
                    InlineNotice(text: artifactsFail, tone: .danger)
                    Button(artifactsLoading || model.searchOpening ? "重试中…" : "再试一次") {
                        guard !artifactsLoading, !model.searchOpening else { return }
                        Task { await refreshArtifacts(force: true) }
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(artifactsLoading || model.searchOpening)
                    .accessibilityIdentifier("search-artifacts-retry")
                }
                if !note.isEmpty {
                    InlineNotice(text: note, tone: (note.contains("没对上") || note.contains("没搜到") || note.contains("失败") || note.contains("没读上") || note.contains("没拉上") || note.contains("对准")) ? .danger : .neutral)
                        .accessibilityIdentifier("search-locate-fail")
                    if retryHit != nil {
                        Button(openingID != nil ? "对准中…" : "再试对准") {
                            guard openingID == nil, let hit = retryHit else { return }
                            openingID = hit.id
                            note = ""
                            Task {
                                await openSearchHit(hit)
                                openingID = nil
                            }
                        }
                        .buttonStyle(.secondaryCompact)
                        .disabled(openingID != nil)
                        .accessibilityIdentifier("search-locate-retry")
                    }
                }
                if openingID != nil {
                    Label("正在打开…", systemImage: "hourglass")
                        .font(TypeScale.footnote.weight(.medium))
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityIdentifier("search-opening")
                }
                if query.isEmpty {
                    let artifacts = model.datasets["/personal/artifacts"]?["items"].array ?? []
                    GroupSection("成果") {
                        if artifactsPulling && artifacts.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, Space.lg)
                                .accessibilityLabel("正在拉齐成果")
                        } else if artifacts.isEmpty {
                            EmptyState(title: artifactsFail.isEmpty ? "还没收过成果" : "成果还没读上",
                                       description: artifactsFail.isEmpty
                                        ? "Agent 交来的文件、图片和报告会落在这里。也可以直接搜聊天或任务——我说得出名字就行。"
                                        : "先重试拉齐；通了会出现在这里。也可以先搜聊天或任务。",
                                       symbol: "tray")
                        } else { ArtifactList(artifacts: artifacts) }
                    }
                    .modifier(EnterRise(on: shown, delay: 0.06, y: 12, blur: 5, animation: ComMotion.rise))
                } else {
                    VStack(spacing: Space.md) {
                        ForEach(Array(results.map(RemoteRow.init).enumerated()), id: \.element.id) { index, row in
                            if row.value["kind"].string == "artifact" { ArtifactList(artifacts: [row.value]) }
                            else {
                                Button {
                                    let item = row.value
                                    guard openingID == nil else { return }
                                    openingID = item.id
                                    note = ""
                                    Task { await openSearchHit(item); openingID = nil }
                                } label: {
                                    ListRow(symbol: row.value["kind"].string == "task" ? "checkmark.square" : "bubble.left",
                                            title: openingID == row.value.id ? "打开中… · " + row.value["text"].string : row.value["text"].string,
                                            titleLines: 4,
                                            meta: row.value["source"].string + " · " + Date(timeIntervalSince1970: row.value["created_at"].double).formatted(date: .abbreviated, time: .shortened))
                                        .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous)).elevation(.raised)
                                        .opacity(openingID != nil && openingID != row.value.id ? 0.55 : 1)
                                }
                                .buttonStyle(MessagePressStyle())
                                .disabled(openingID != nil)
                                .modifier(EnterRise(on: shown, delay: 0.04 + Double(min(index, 6)) * ComMotion.stagger, y: 8, blur: 3, animation: ComMotion.pop))
                            }
                        }
                    }
                    .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: results.map(\.id))
                }
            }.navigationTitle("搜索与成果").navigationBarTitleDisplayMode(.large)
                .task { await refreshArtifacts(force: false) }
                .task(id: query) {
                    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { results = []; return }
                    do {
                        try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation()
                        guard let api = model.client else {
                            note = "还没配对——连上 mini 后再搜。"
                            results = []
                            return
                        }
                        let result = try await api.request("/personal/search?q=" + query.queryEncoded)
                        try Task.checkCancellation(); results = result["items"].array; note = results.isEmpty ? "没搜到。换个词试试，或去对话里直接问我。" : ""
                    } catch { if !Task.isCancelled { note = error.localizedDescription } }
                }
                .toolbar {
                    if artifactsPulling {
                        ToolbarItem(placement: .topBarLeading) {
                            ProgressView().controlSize(.small).accessibilityLabel("正在拉齐搜索")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.disabled(openingID != nil) }
                }
                .onAppear {
                    if reduce { shown = true }
                    else { withAnimation(ComMotion.rise) { shown = true } }
                }
        }
    }
    private func refreshArtifacts(force: Bool) async {
        guard !artifactsLoading else { return }
        artifactsLoading = true
        if force { artifactsFail = "" }
        defer {
            artifactsLoading = false
            artifactsLoadedOnce = true
        }
        let path = "/personal/artifacts"
        let ok: Bool
        // 与 openSearch 同路：入口已在拉则等它结束，避免叠刷。
        if model.searchOpening && !force {
            while model.searchOpening && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
            }
            ok = model.errors[path] == nil && model.datasets[path] != nil
        } else {
            ok = await model.load(path) != nil
        }
        let hadCache = !(model.datasets[path]?["items"].array ?? []).isEmpty
        if ok {
            artifactsFail = ""
            model.searchOpenNote = ""
            return
        }
        let err = model.errors[path] ?? ""
        artifactsFail = err.isEmpty
            ? (hadCache ? "成果没刷新上——下面仍是上一版，可再试" : "成果列表没拉齐——检查配对或网络后再试")
            : (hadCache ? "成果没刷新上：" + err + "——下面仍是上一版" : "成果没拉齐：" + err + "——可再试")
    }
    /// 先定位成功再收起搜索；找不到留在列表可换一条 / 再试对准。
    private func openSearchHit(_ item: JSON) async {
        note = ""
        retryHit = nil
        model.locateNote = ""
        if item["kind"].string == "task" {
            await model.refresh(.doing)
            if let task = model.datasets["/personal/tasks"]?["items"].array.first(where: { $0.id == item.id }) {
                model.selectedTask = task
                dismiss()
            } else {
                note = "任务没对上，换一条或下拉刷新后再试。"
                retryHit = item
            }
            return
        }
        if await model.locateMessage(item.id) {
            dismiss()
        } else {
            note = model.locateNote.isEmpty
                ? "消息没对上，换一条或直接去对话里找。"
                : model.locateNote
            retryHit = item
        }
    }
}

struct ArtifactList: View {
    @Environment(AppModel.self) private var model
    let artifacts: [JSON]
    /// 10-25 附件片（参考 Mailio 邮件底部的 Brief.pdf 片）：两列小卡，类型色块 + 名字 + 类型 · 大小 + 下载记号。
    var chips = false
    @State private var preview: PreviewFile?
    @State private var page: PreviewFile?
    @State private var loading: String?
    @State private var error = ""
    /// 下载/打开失败后可「再试一次」的那条成果。
    @State private var retryItem: JSON?
    /// HTML 勾选/输入态写回失败时提示（原先 try? 静默吞掉）。
    @State private var saveNote = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if chips && !artifacts.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible(), spacing: Space.sm)], spacing: Space.sm) {
                    ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                        Button { Task { await open(artifact) } } label: { AttachmentChip(artifact: artifact, loading: loading == artifact.id) }
                            .buttonStyle(.plain).disabled(loading != nil)
                    }
                }
            } else if !artifacts.isEmpty {
                GroupedCard(dividerInset: Layout.rowInset) {
                    ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                        Button {
                            Task { await open(artifact) }
                        } label: {
                            ListRow(symbol: artifact["mime"].string.hasPrefix("image") ? "photo" : artifact["name"].string.hasSuffix(".html") ? "rectangle.on.rectangle.angled" : "doc.richtext", tone: .info,
                                    title: artifact["name"].string.isEmpty ? URL(fileURLWithPath: artifact["path"].string).lastPathComponent : artifact["name"].string,
                                    subtitle: artifact["availability"].string == "available" ? (artifact["name"].string.hasSuffix(".html") ? "点开直接看" : "预览与分享") : artifact["availability"].string == "missing" ? "文件已移动或不存在" : "核对登记后预览", subtitleLines: 1) {
                                if loading == artifact.id { ProgressView() } else { Image(systemName: "arrow.up.right").font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary) }
                            }
                        }.buttonStyle(.row).disabled(loading != nil)
                    }
                }
            }
            if !error.isEmpty {
                InlineNotice(text: error, tone: .danger)
                    .accessibilityIdentifier("artifact-open-fail")
                if let retryItem {
                    Button(loading != nil ? "打开中…" : "再试一次") {
                        guard loading == nil else { return }
                        Task { await open(retryItem) }
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(loading != nil)
                    .accessibilityIdentifier("artifact-open-retry")
                }
            }
        }
        .fullScreenCover(item: $page) { file in
            NavigationStack {
                HTMLPreview(url: file.url, initialState: file.state, save: saveState(file.url))
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(file.url.deletingPathExtension().lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("完成") { saveNote = ""; page = nil }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !saveNote.isEmpty {
                            InlineNotice(text: saveNote, tone: .danger)
                                .padding(.horizontal, Space.lg)
                                .padding(.vertical, Space.sm)
                                .background(Palette.surface.opacity(0.96))
                                .accessibilityIdentifier("artifact-save-fail")
                        }
                    }
            }
            .onDisappear { saveNote = "" }
        }
        .sheet(item: $preview) { file in NavigationStack { FilePreview(url: file.url).navigationTitle(file.url.lastPathComponent).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { preview = nil } }; ToolbarItem(placement: .topBarTrailing) { ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") } } } } }
    }
    private func open(_ item: JSON) async {
        guard loading == nil else { return }
        error = ""
        retryItem = nil
        // 登记状态已知不可读：别发起下载假装能开。
        switch item["availability"].string {
        case "missing":
            error = "文件已移动或不存在，没法打开。不会假装能下。"
            return
        case "available", "":
            break
        default:
            error = "还没核对登记好，稍后再开或让我重新登记。不会假装能下。"
            return
        }
        guard let api = model.client else {
            error = "还没连上 mini，连上后再打开成果。不会假装已下载。"
            retryItem = item
            return
        }
        loading = item.id
        defer { loading = nil }
        do {
            var record = item
            if !item.id.hasPrefix("art_") {
                let catalog = try await api.request("/personal/artifacts")
                guard let found = catalog["items"].array.first(where: { $0["path"] == item["path"] || $0["reference"] == item["path"] }) else {
                    throw APIError(status: 404, detail: "成果尚未登记，不能直接读取任意路径")
                }
                record = found
                if record["availability"].string == "missing" {
                    error = "文件已移动或不存在，没法打开。不会假装能下。"
                    return
                }
            }
            let file = try await api.download(record.id, name: record["name"].string, into: SecureVault.directory.appendingPathComponent("Previews"))
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            error = ""
            retryItem = nil
            if file.pathExtension.lowercased() == "html" {
                let saved = try? await api.request("/personal/artifact-state/" + file.lastPathComponent.pathEncoded)
                let state = (saved?["state"]).flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                page = PreviewFile(url: file, state: state)
            } else { preview = PreviewFile(url: file) }
        } catch {
            self.error = "下载没成：" + error.localizedDescription + "——可再试。不会假装已打开。"
            self.retryItem = item
        }
    }
    private func saveState(_ file: URL) -> (String) -> Void {
        let client = model.client
        let name = file.lastPathComponent.pathEncoded
        return { text in
            guard let client else {
                Task { @MainActor in saveNote = "没连上 mini，勾选改动可能存不上" }
                return
            }
            guard let data = text.data(using: .utf8), let state = try? JSONDecoder().decode(JSON.self, from: data) else {
                Task { @MainActor in saveNote = "预览状态格式不对，改动可能丢——关掉再开试试" }
                return
            }
            Task { @MainActor in
                do {
                    _ = try await client.request("/personal/artifact-state/" + name, body: .object(["state": state]))
                    if !saveNote.isEmpty { saveNote = "" }
                } catch {
                    saveNote = "预览状态没存上：" + error.localizedDescription + "——改动可能丢，可再勾一次"
                }
            }
        }
    }
}
private struct AttachmentChip: View {
    let artifact: JSON
    let loading: Bool
    var body: some View {
        let name = artifact["name"].string.isEmpty ? URL(fileURLWithPath: artifact["path"].string).lastPathComponent : artifact["name"].string
        let ext = (URL(fileURLWithPath: name).pathExtension.uppercased()).prefix(4)
        let tint: Color = switch ext { case "PDF": Palette.danger; case "PNG", "JPG", "JPEG", "WEBP", "GIF": Palette.info; case "HTML": Palette.success; case "XLSX", "CSV": Color(red: 0.2, green: 0.6, blue: 0.35); default: Palette.textSecondary }
        let size = artifact["size"].double > 0 ? ByteCountFormatter.string(fromByteCount: Int64(artifact["size"].double), countStyle: .file) : ""
        HStack(spacing: Space.sm) {
            Text(ext.isEmpty ? "FILE" : String(ext)).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 30, height: 36).background(tint, in: .rect(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(TypeScale.footnote.weight(.semibold)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Text(artifact["availability"].string == "missing" ? "已移动或不存在" : [String(ext), size].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(Palette.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.down.to.line").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textTertiary) }
        }
        .padding(Space.sm)
        .background(Palette.fill, in: .rect(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
    }
}
private struct PreviewFile: Identifiable { let url: URL; var state = "{}"; var id: String { url.path } }
/// 航程产出的 HTML：自包含单文件，直接在 App 里交互；只读本文件所在目录，外部链接一律不跳转。
/// 勾选、展开、输入按元素顺序存到后端（和网页共用），下次打开照原样恢复。
struct HTMLPreview: UIViewRepresentable {
    let url: URL
    var initialState: String = "{}"
    var save: (String) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(save) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let script = """
        (function(){var S=\(initialState);var els=[].slice.call(document.querySelectorAll('input,textarea,details')).filter(function(e){return e.type!=='file'&&e.type!=='password'});
        function box(e){return e.type==='checkbox'||e.type==='radio'}
        function k(e,i){return e.id||i}
        els.forEach(function(e,i){var v=S[k(e,i)];if(v===undefined)return;if(e.tagName==='DETAILS')e.open=!!v;else if(box(e))e.checked=!!v;else e.value=v});
        function snap(){var o={};els.forEach(function(e,i){o[k(e,i)]=e.tagName==='DETAILS'?e.open:box(e)?e.checked:e.value});window.webkit.messageHandlers.comState.postMessage(JSON.stringify(o))}
        document.addEventListener('change',snap,true);document.addEventListener('input',snap,true);
        els.forEach(function(e){if(e.tagName==='DETAILS')e.addEventListener('toggle',snap)})})();
        """
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "comState")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "comState")
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let save: (String) -> Void
        init(_ save: @escaping (String) -> Void) { self.save = save }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let text = message.body as? String { save(text) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true || action.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
struct FilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}


struct ConnectionList: View {
    @Environment(AppModel.self) private var model
    var emptyTitle: String = "还没有信源"
    var emptyDescription: String = "接上邮件、日历或健康后会出现在这里。"
    private var sources: [JSON] { model.datasets["/personal/connectors"]?["sources"].array ?? model.datasets["/personal/briefing"]?["source_status"]["sources"].array ?? [] }
    var body: some View {
        if sources.isEmpty {
            EmptyState(title: emptyTitle, description: emptyDescription, symbol: "link")
        } else {
            GroupedCard {
                ForEach(sources.map { RemoteRow(.object(["id": $0["name"], "source": $0])) }) { row in
                    let source = row.value["source"]
                    NavigationLink { ConnectionDetail(source: source) } label: {
                        ListRow(symbol: connectionSymbol(source["name"].string), tone: source["status"].string == "connected" ? .success : .neutral,
                                title: sourceName(source["name"].string), status: connectionStatus(source["status"].string), statusTone: source["status"].string == "connected" ? .success : .neutral,
                                subtitle: source["status"].string == "connected" ? "已接通 · 看同步情况" : "还没接上 · 点这里配置", subtitleLines: 1) { Chevron() }
                    }.buttonStyle(.row)
                }
            }
        }
    }
}
struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var land = false
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    private var pulling: Bool { model.connectorsOpening || loading || !loadedOnce }
    private var hasSources: Bool {
        !(model.datasets["/personal/connectors"]?["sources"].array ?? []).isEmpty
            || !(model.datasets["/personal/briefing"]?["source_status"]["sources"].array ?? []).isEmpty
    }
    var body: some View {
        ScrollPage {
            if pulling {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在拉齐信源现况…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                }
                .accessibilityLabel("正在拉齐连接器")
                .accessibilityIdentifier("connectors-pulling")
            }
            Text("邮件、日历、健康这些接上后，我才能替你看一眼真实世界——凭据只进 mini，不进聊天。")
                .font(TypeScale.callout).foregroundStyle(Palette.textSecondary)
                .modifier(EnterRise(on: land, delay: 0, y: 10, blur: 4, animation: ComMotion.rise))
            if !failNote.isEmpty {
                InlineNotice(text: failNote, tone: .danger)
                Button(loading || model.connectorsOpening ? "重试中…" : "再试一次") {
                    guard !loading, !model.connectorsOpening else { return }
                    Task { await refreshConnectors(force: true) }
                }
                .buttonStyle(.secondaryCompact)
                .disabled(loading || model.connectorsOpening)
                .accessibilityIdentifier("connectors-retry")
            }
            ConnectionList(
                emptyTitle: failNote.isEmpty ? "还没有信源" : "信源还没读上",
                emptyDescription: failNote.isEmpty
                    ? "接上邮件、日历或健康后会出现在这里。"
                    : "先重试拉齐；通了会列出可接的信源。"
            )
                .modifier(EnterRise(on: land, delay: 0.06, y: 12, blur: 5, animation: ComMotion.pop))
        }.navigationTitle("数据连接").navigationBarTitleDisplayMode(.large)
            .onAppear {
                if reduce { land = true }
                else { withAnimation(ComMotion.lift) { land = true } }
            }
            .task { await refreshConnectors(force: false) }
            .refreshable { await refreshConnectors(force: true) }
    }
    private func refreshConnectors(force: Bool) async {
        guard !loading else { return }
        loading = true
        if force { failNote = "" }
        defer {
            loading = false
            loadedOnce = true
        }
        let path = "/personal/connectors"
        let ok: Bool
        // 与 openConnectors 同路：入口已在拉则等它结束，避免叠刷。
        if model.connectorsOpening && !force {
            while model.connectorsOpening && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
            }
            ok = model.errors[path] == nil && model.datasets[path] != nil
        } else {
            ok = await model.load(path) != nil
        }
        if ok {
            failNote = ""
            model.connectorsOpenNote = ""
            return
        }
        let err = model.errors[path] ?? ""
        failNote = err.isEmpty
            ? (hasSources ? "信源现况没刷新上——下面仍是上一版，可再试" : "信源现况没拉齐——检查配对或网络后再试")
            : (hasSources ? "信源没刷新上：" + err + "——下面仍是上一版" : "信源没拉齐：" + err + "——可再试")
    }
}
struct ConnectionDetail: View {
    @Environment(AppModel.self) private var model
    let source: JSON
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var region = "garmin.cn"
    @State private var protocolKind = "ews"
    @State private var email = ""
    @State private var busy = false
    @State private var note = ""
    @State private var noteFailed = false
    private var name: String { source["name"].string }
    private var current: JSON { model.datasets["/personal/connectors"]?["sources"].array.first { $0["name"].string == name } ?? source }
    private var connected: Bool { current["status"].string == "connected" }
    var body: some View {
        ScrollPage {
            Card { HStack { IconBadge(symbol: connectionSymbol(name), tone: connected ? .success : .neutral); Text(sourceName(name)).font(TypeScale.title); Spacer(); StatusPill(text: connectionStatus(current["status"].string), tone: connected ? .success : .neutral) } }
            if !note.isEmpty { InlineNotice(text: note, tone: noteFailed ? .danger : .neutral) }
            if !connected && ["work_mail", "garmin"].contains(name) && current["status"].string != "disconnected" {
                GroupSection("账号") {
                    GroupedCard {
                        if name == "work_mail" {
                            Picker("邮箱类型", selection: $protocolKind) { Text("Exchange（OWA）").tag("ews"); Text("IMAP").tag("imap") }.pickerStyle(.segmented).rowPadding()
                            TextField(protocolKind == "ews" ? "服务器，如 mail.sohu-inc.com" : "IMAP 服务器", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).rowPadding()
                            if protocolKind == "ews" { TextField("邮箱地址，如 name@sohu-inc.com", text: $email).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress).rowPadding() }
                        }
                        else { Picker("地区", selection: $region) { Text("中国区").tag("garmin.cn"); Text("国际区").tag("garmin.com") }.rowPadding() }
                        TextField(name == "work_mail" && protocolKind == "ews" ? "域账号（登录 OWA 用的那个）" : "账号", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().rowPadding()
                        SecureField(name == "work_mail" ? (protocolKind == "ews" ? "邮箱密码" : "邮箱专用密码") : "密码", text: $password).rowPadding()
                    }
                    if name == "work_mail" && protocolKind == "ews" {
                        Text("搜狐邮箱不开 IMAP，走 Exchange 的 EWS 接口读收件箱邮件头，不改已读状态。密码直接发给 mini 保存，不进聊天记录。").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    }
                    Button("连接") { update(credentials: true) }.buttonStyle(.primaryFull).disabled(busy || username.isEmpty || password.isEmpty || (name == "work_mail" && (host.isEmpty || (protocolKind == "ews" && !email.contains("@")))))
                }
            } else if !connected {
                if name == "gmail" || name == "google_calendar" { Text("第一次接 Google 要在 Mac mini 上完成授权；这边点「检查连接」我再确认一次。").font(TypeScale.callout).foregroundStyle(Palette.textSecondary) }
                Button(current["status"].string == "disconnected" ? "重新连接" : "检查连接") { update(credentials: false) }.buttonStyle(.primaryFull).disabled(busy)
            }
            if connected {
                Button("断开同步", role: .destructive) { update(enabled: false, credentials: false) }.buttonStyle(.secondaryAction).disabled(busy)
                Text("停止 Com 后续读取；保留既有资料及其他 App 的授权。").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
            }
            if busy { ProgressView("正在核验连接") }
            if !current["error"].string.isEmpty { DisclosureGroup("诊断详情") { Text(current["error"].string).font(TypeScale.footnote).textSelection(.enabled) } }
        }.navigationTitle(sourceName(name)).navigationBarTitleDisplayMode(.inline)
            .onAppear { if name == "work_mail" && host.isEmpty { host = "mail.sohu-inc.com" } }
    }
    private func update(enabled: Bool = true, credentials: Bool) {
        guard !busy else { return }
        busy = true
        note = ""
        noteFailed = false
        Task {
            defer { busy = false }
            do {
                var fields: [String: JSON] = ["enabled": .bool(enabled)]
                if credentials {
                    fields["username"] = .string(username); fields["password"] = .string(password)
                    if name == "work_mail" { fields["host"] = .string(host); fields["protocol"] = .string(protocolKind); if protocolKind == "ews" { fields["email"] = .string(email) } }
                    else { fields["domain"] = .string(region) }
                }
                guard let api = model.client else { throw APIError(status: 0, detail: "请先连接服务") }
                // Account secrets go directly over authenticated TLS, never into the local operation ledger.
                _ = try await api.request("/personal/connectors/" + name.pathEncoded, body: .object(fields))
                // 只有请求成功才清密码；失败保留便于改完重试。
                password = ""
                if enabled {
                    // sync 回包已含 sources 状态；load 失败时可用它判断成败，但不得仅凭陈旧 connected 报「已核验」。
                    let syncResult = try await model.mutate("/personal/sync", fields: ["group": .string(name)])
                    let syncRow = syncResult["sources"].array.first { $0["name"].string == name } ?? .null
                    let connectors = await model.load("/personal/connectors")
                    _ = await model.load("/personal/briefing")
                    applyCheckVerdict(connectors: connectors, syncRow: syncRow)
                } else {
                    let connectors = await model.load("/personal/connectors")
                    _ = await model.load("/personal/briefing")
                    applyDisconnectVerdict(connectors: connectors)
                }
            } catch {
                noteFailed = true
                note = "操作未完成：" + error.localizedDescription + "——可再试。不会假装已核验。"
            }
        }
    }
    /// 「检查连接 / 连接」：只有 connectors 拉齐且 status=connected 才报已核验；load 失败绝不用成功口吻。
    private func applyCheckVerdict(connectors: JSON?, syncRow: JSON) {
        if let connectors {
            let row = connectors["sources"].array.first { $0["name"].string == name } ?? syncRow
            let status = row["status"].string
            let err = row["error"].string
            if status == "connected" {
                noteFailed = false
                note = "连接已核验"
            } else {
                noteFailed = true
                note = err.isEmpty
                    ? "尚未连接，请检查授权或账号。不会假装已核验。"
                    : "尚未连接：" + err + "——可再点检查。不会假装已核验。"
            }
            return
        }
        // 列表没刷上：即便 sync 回报 connected，也不说「连接已核验」。
        noteFailed = true
        if syncRow.isNull {
            note = "核验已提交，但连接器列表没刷上——可再点检查或返回下拉刷新。不会假装已核验。"
            return
        }
        let status = syncRow["status"].string
        let err = syncRow["error"].string
        if status == "connected" {
            note = "同步回报已连上，但列表没刷上——请返回下拉刷新再确认。不会假装这边已核验。"
        } else if err.isEmpty {
            note = "还没连上（现为「" + connectionStatus(status) + "」）；列表也没刷上——可再点检查。不会假装已核验。"
        } else {
            note = "还没连上：" + err + "——可再点检查。不会假装已核验。"
        }
    }
    /// 断开：load 失败或状态未变 disconnected 都开口，别空口报已停止。
    private func applyDisconnectVerdict(connectors: JSON?) {
        guard let connectors else {
            noteFailed = true
            note = "已请求停止同步，但状态没刷上——可再开此页核对。不会假装已确认断开。"
            return
        }
        let row = connectors["sources"].array.first { $0["name"].string == name } ?? .null
        let status = row["status"].string
        if status == "disconnected" || row["enabled"].bool == false {
            noteFailed = false
            note = "已停止此来源同步"
        } else {
            noteFailed = true
            note = "停止已请求，状态仍是「" + connectionStatus(status) + "」——可再试。不会假装已断开。"
        }
    }
}
private func connectionStatus(_ raw: String) -> String {
    ["connected": "已连接", "disconnected": "已断开", "needs_connection": "未连接", "not_synced": "未检查", "unavailable": "暂不可用"][raw] ?? "待核实"
}
private func connectionSymbol(_ name: String) -> String {
    switch name {
    case "gmail", "work_mail": "envelope"
    case "github": "desktopcomputer"
    case "apple_calendar", "phone_calendar", "google_calendar": "calendar"
    case "accounting": "creditcard"
    case "garmin", "phone_health": "heart"
    case "phone_reminders": "bell"
    case "sms": "message"
    case "plaud": "waveform"
    case "weather": "cloud.sun"
    default: "link"
    }
}


/// 10-25 活动日志（借鉴 Muse）：它替你做过的每个写操作。审批只拦删除之后，这里是事后那道闸：
/// 能看到做了什么、凭哪句话做的，结果不确定的可以说一句做成了没有。微信通道发过的提醒也列在最后。
