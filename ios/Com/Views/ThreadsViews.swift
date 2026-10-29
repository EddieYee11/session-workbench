import SwiftUI
import ComCore

// 线索 + 统一「等你」（2026-10-18）。
// 线索：每张卡片都能看到上下游（对话 → 下一步 → 待办 → 航程 → 执行会话 → 项目页），点哪一环就跳到哪。后端 backend/threads.py（/personal/thread）。
// 等你：审批卡（App 里已有的 pendingItems）+ 等你批准的航程 + 微信在等回话 + 过期待办，一个角标一个收件箱。后端 /personal/waiting。

extension AppModel {
    var waitingData: JSON { datasets["/personal/waiting"] ?? .null }

    /// 打开线索里的一环。先收起正在看的航程 sheet，再跳过去。
    func openThreadNode(_ node: JSON) {
        let ident = node["id"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        switch node["kind"].string {
        case "case":
            guard !ident.isEmpty else {
                // 空 case id 以前仍弹空航程 sheet，像打开了。
                banner = "这条航程对不上——编号空了。可回「等你」或动态再点。不会假装已打开。"
                return
            }
            presentedCase = nil
            showWaiting = false
            Task { try? await Task.sleep(for: .milliseconds(350)); presentedCase = ident }
        case "next":
            presentedCase = nil; showCases = false; showWaiting = false; tab = .next
        case "msg":
            guard !ident.isEmpty else {
                locateNote = "消息编号空了，没法对准。"
                return
            }
            // 对准成功再收 sheet；失败留页 + locateNote，别先关再只弹 banner。
            Task {
                if await locateMessage(ident) {
                    presentedCase = nil
                    showCases = false
                    showWaiting = false
                }
            }
        case "session":
            guard !ident.isEmpty else {
                banner = "这条工作会话对不上——编号空了。可回侧栏再点。不会假装已打开。"
                return
            }
            presentedCase = nil; showCases = false; showWaiting = false
            selectedSession = .object(["id": .string(ident), "agent": node["agent"].isNull ? .string("pi") : node["agent"]])
        default:
            if let url = URL(string: node["url"].string), !node["url"].string.isEmpty { UIApplication.shared.open(url) }
            else if node["kind"].string == "todo" {
                banner = "待办链接空了——打不开 Obsidian。可到今天页再试。不会假装已打开。"
            }
        }
    }

    /// 微信在等回话：让 Com 起草回复（发到主对话，草稿给他确认，不替他发）。
    /// 返回是否送达；失败时收件箱应留页并提示可重试。
    @discardableResult
    func draftWechatReply(_ item: JSON) async -> Bool {
        let ok = await send(textOverride: "帮我起草一条回复给「" + item["title"].string + "」的微信，对方最后说：" + item["why"].string + "。先给我看草稿，不要替我发。")
        // 先送达再关等你/跳聊天；失败留在收件箱，别丢上下文。
        guard ok else { return false }
        showWaiting = false
        tab = .chat
        return true
    }
    @discardableResult
    func waitingTodo(_ path: String, _ action: String) async -> Bool {
        do {
            _ = try await mutate("/personal/today/todos/" + action, fields: ["path": .string(path)])
            Haptics.success()
            // 已改期/完成；等你/今天没刷齐则开口，别假装角标与日程已齐（调用方已乐观藏卡）。
            let head = action == "postpone" ? "已改到明天" : action == "done" ? "已标完成" : "已处理"
            if await load("/personal/waiting") == nil {
                let err = errors["/personal/waiting"] ?? ""
                waitingOpenNote = err.isEmpty
                    ? head + "，等你列表没刷齐——可再拉开等你。不会假装角标已更新。"
                    : head + "，等你列表没刷齐：" + err + "——可再拉开等你。不会假装角标已更新。"
            }
            if await load("/personal/today") == nil {
                let err = errors["/personal/today"] ?? ""
                doingOpenNote = err.isEmpty
                    ? head + "，今天页没刷上——可到「今天」下拉。不会假装待办已离开。"
                    : head + "，今天页没刷上：" + err + "——可到「今天」下拉。不会假装待办已离开。"
            }
            return true
        } catch { banner = error.localizedDescription; return false }
    }
    /// 微信「已经回了」：按末条 at 确认；对方再发新消息会重新进等你。失败返回 false，调用方应把本地藏卡撤掉。
    @discardableResult
    func waitingAck(_ item: JSON) async -> Bool {
        do {
            _ = try await mutate("/personal/waiting/ack", fields: ["id": .string(item.id), "at": item["at"]])
            Haptics.success()
            // 已确认回过；列表没刷齐则乐观收卡 + 开口，别假装角标已更新。
            if await load("/personal/waiting") == nil {
                var value = waitingData
                let kept = value["items"].array.filter { $0.id != item.id }
                value["items"] = .array(kept)
                if !value["count"].isNull { value["count"] = .number(Double(kept.count)) }
                datasets["/personal/waiting"] = value
                recomputeFlow()
                let err = errors["/personal/waiting"] ?? ""
                waitingOpenNote = err.isEmpty
                    ? "已记下「回过了」，等你列表没刷齐——可再拉开等你。不会假装角标已更新。"
                    : "已记下「回过了」，等你列表没刷齐：" + err + "——可再拉开等你。不会假装角标已更新。"
            } else {
                waitingOpenNote = ""
            }
            return true
        } catch {
            banner = error.localizedDescription
            return false
        }
    }
    /// 下一步「复制草稿去微信」后：同一聊天若还在等你，按当前末条确认掉，角标别继续催回。
    func ackWaitingWechat(named chat: String) async {
        let name = chat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        _ = await load("/personal/waiting")
        let items = waitingData["items"].array.filter { $0["kind"].string == "wechat" }
        let match = items.first {
            $0.id == "wechat:" + name
                || $0["title"].string == name
                || $0["title"].string.hasPrefix(name + "（")
        }
        guard let match else { return }
        _ = await waitingAck(match)
    }
}

private func threadSymbol(_ kind: String) -> String {
    ["msg": "bubble.left", "next": "shoeprints.fill", "todo": "checklist", "case": "rectangle.stack", "session": "terminal", "project": "folder"][kind] ?? "circle"
}

// MARK: - 线索条

/// 一行可横滑的线索：来自哪里 → 现在这张 → 去了哪里。只有自己一环时不显示。
struct ThreadStrip: View {
    let key: String
    @Environment(AppModel.self) private var model
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    private var path: String { "/personal/thread?key=" + (key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? key) }
    var body: some View {
        let nodes = model.datasets[path]?["nodes"].array ?? []
        Group {
            if nodes.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: Space.sm) {
                        Text("线索").font(TypeScale.caption).foregroundStyle(Palette.textTertiary)
                        if loading {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("正在拉齐线索")
                        }
                    }
                    if !failNote.isEmpty {
                        InlineNotice(text: failNote, tone: .danger)
                        Button(loading ? "重试中…" : "再试一次") {
                            guard !loading else { return }
                            Task { await refreshThread() }
                        }
                        .buttonStyle(.secondaryCompact)
                        .disabled(loading)
                        .accessibilityIdentifier("thread-strip-retry")
                    }
                    if !model.locateNote.isEmpty {
                        InlineNotice(text: model.locateNote, tone: .danger)
                            .accessibilityIdentifier("thread-locate-fail")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textTertiary) }
                                chip(node)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .accessibilityIdentifier("thread-strip")
            } else if loadedOnce && !failNote.isEmpty {
                // 拉齐失败且没有可用线索：别静默成「没有上下游」。
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("线索").font(TypeScale.caption).foregroundStyle(Palette.textTertiary)
                    InlineNotice(text: failNote, tone: .danger)
                    Button(loading ? "重试中…" : "再试一次") {
                        guard !loading else { return }
                        Task { await refreshThread() }
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(loading)
                    .accessibilityIdentifier("thread-strip-retry")
                }
                .accessibilityIdentifier("thread-strip-fail")
            } else if loading && !loadedOnce {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在拉齐线索…").font(TypeScale.caption).foregroundStyle(Palette.textTertiary)
                }
                .accessibilityLabel("正在拉齐线索")
                .accessibilityIdentifier("thread-strip-loading")
            }
        }
        .task(id: key) {
            failNote = ""
            loadedOnce = false
            await refreshThread()
        }
    }
    private func refreshThread() async {
        guard !loading else { return }
        loading = true
        failNote = ""
        defer {
            loading = false
            loadedOnce = true
        }
        if await model.load(path) != nil { return }
        let err = model.errors[path] ?? ""
        let hadNodes = (model.datasets[path]?["nodes"].array.count ?? 0) > 1
        failNote = err.isEmpty
            ? (hadNodes ? "线索没刷新上——下面仍是上一版，可再试" : "线索没拉齐——可再试")
            : (hadNodes ? "线索没刷新上：" + err + "——下面仍是上一版" : "线索没拉齐：" + err + "——可再试")
    }
    private func chip(_ node: JSON) -> some View {
        let current = node["current"].bool
        return Button { if !current { Haptics.selection(); model.openThreadNode(node) } } label: {
            HStack(spacing: 5) {
                Image(systemName: threadSymbol(node["kind"].string)).font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(node["label"].string.isEmpty ? node["kind"].string : node["label"].string).font(.system(size: 9, weight: .semibold)).foregroundStyle(current ? Palette.onInkSecondary : Palette.textTertiary)
                    Text(node["title"].string).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                if !node["state"].string.isEmpty && !current {
                    Text(node["state"].string).font(.system(size: 10)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
            .foregroundStyle(current ? Palette.onInk : Palette.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: 220, alignment: .leading)
            .background(current ? Palette.ink : Palette.surface, in: .rect(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(current)
        .accessibilityLabel((node["label"].string) + "：" + node["title"].string)
    }
}

// MARK: - 统一「等你」

struct WaitingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var hidden: Set<String> = []
    @State private var shown = false
    @State private var handoffNote = ""
    /// 正在起草回复的微信卡 id；非空时防连点。
    @State private var draftingID: String?
    /// 起草送达失败时页内提示（成功会关 sheet，用不到）。
    @State private var draftFailNote = ""
    /// 过期待办改期/完成/交给我办进行中；防连点。
    @State private var todoBusyID: String?
    /// 「交给我办」失败页内提示（成功会关等你或跳走）。
    @State private var todoFailNote = ""
    @State private var loading = false
    @State private var failNote = ""
    @State private var loadedOnce = false
    private let waitingPath = "/personal/waiting"
    private var items: [JSON] { model.waitingData["items"].array.filter { !hidden.contains($0.id) } }
    private var pulling: Bool { model.waitingOpening || loading || (!loadedOnce && items.isEmpty && model.pendingItems.filter { !$0.stale }.isEmpty) }
    private var leadIntro: String {
        if let tip = ChatAttentionHint.topWaitingTitle(model) {
            return "先看这件：「\(tip)」——一卡一个动作，办完再说下一件。"
        }
        return "我先把要你点头的放最上面——一卡看一件，办完再说下一件。"
    }
    var body: some View {
        NavigationStack {
            ScrollPage(spacing: Layout.sectionSpacing) {
                let decisions = model.pendingItems.filter { !$0.stale }
                if pulling {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("正在拉齐等你清单…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    }
                    .accessibilityLabel("正在拉齐等你")
                    .accessibilityIdentifier("waiting-pulling")
                }
                if !failNote.isEmpty {
                    InlineNotice(text: failNote, tone: .danger)
                    Button(pulling ? "重试中…" : "再试一次") {
                        guard !pulling else { return }
                        Task { await pullWaiting(force: true) }
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(pulling)
                    .accessibilityIdentifier("waiting-retry")
                }
                if !model.approvalDeepLinkNote.isEmpty {
                    InlineNotice(text: model.approvalDeepLinkNote, tone: .warning)
                        .accessibilityIdentifier("waiting-approval-deeplink-note")
                }
                if !model.locateNote.isEmpty {
                    InlineNotice(text: model.locateNote, tone: .danger)
                        .accessibilityIdentifier("waiting-locate-fail")
                }
                if !pulling && decisions.isEmpty && items.isEmpty {
                    EmptyState(
                        title: failNote.isEmpty ? "眼下没有要你拍板的" : "等你清单还没读上",
                        description: failNote.isEmpty
                            ? "审批、航程停顿、微信待回、过期待办会汇到这里。有事我会先整理好再找你。"
                            : "先重试拉齐；通了我再开口列要你拍板的事。别把失败当成「没有要拍板的」。",
                        symbol: failNote.isEmpty ? "checkmark.circle" : "exclamationmark.circle"
                    )
                    .enterRise(on: shown, delay: 0.02, y: 16, blur: 8)
                    .accessibilityIdentifier(failNote.isEmpty ? "waiting-empty" : "waiting-empty-fail")
                } else if !(decisions.isEmpty && items.isEmpty) {
                    Text(leadIntro)
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .contentTransition(.opacity)
                        .enterRise(on: shown, delay: 0.01, y: 10, blur: 4)
                    if !handoffNote.isEmpty {
                        // 划卡/批准失败别用成功勾；人话开口可再试。
                        let failed = handoffNote.contains("没成") || handoffNote.contains("还可以") || handoffNote.contains("没接进") || handoffNote.contains("卡还在")
                        if failed {
                            InlineNotice(text: handoffNote, tone: .danger)
                                .accessibilityIdentifier("waiting-handoff-fail")
                        } else {
                            Label(handoffNote, systemImage: "checkmark.circle")
                                .font(TypeScale.footnote.weight(.medium))
                                .foregroundStyle(Palette.accentText)
                                .accessibilityIdentifier("waiting-handoff-note")
                        }
                    }
                    if !draftFailNote.isEmpty {
                        InlineNotice(text: draftFailNote, tone: .danger)
                            .accessibilityIdentifier("waiting-draft-fail")
                    }
                    if !todoFailNote.isEmpty {
                        InlineNotice(text: todoFailNote, tone: .danger)
                            .accessibilityIdentifier("waiting-todo-fail")
                    }
                }
                if !decisions.isEmpty {
                    GroupSection("要你拍板 · \(decisions.count)") {
                        ForEach(Array(decisions.enumerated()), id: \.element.id) { index, item in
                            PendingNote(item: item, lead: index == 0) { handoffNote = $0 }
                                .transition(reduce ? .opacity : .asymmetric(
                                    insertion: .modifier(active: BlurShift(y: 10, blur: 4, opacity: 0), identity: BlurShift()),
                                    removal: .opacity.combined(with: .move(edge: .trailing))))
                        }
                    }
                    .enterRise(on: shown, delay: 0.04, y: 14, blur: 6)
                    .animation(ComMotion.reduced(reduce, ComMotion.settle), value: decisions.map(\.id))
                }
                section("航程停下来等你", kind: "case") { item in
                    row(item, symbol: "rectangle.stack", tone: .warning) { model.openThreadNode(.object(["kind": .string("case"), "id": item["case_id"]])) }
                }
                .enterRise(on: shown, delay: 0.08, y: 14, blur: 6)
                section("微信在等你回", kind: "wechat") { item in
                    VStack(alignment: .leading, spacing: Space.sm) {
                        row(item, symbol: "bubble.left.and.bubble.right", tone: .info) {}
                        HStack(spacing: Space.sm) {
                            Button(draftingID == item.id ? "起草中…" : "让 Com 起草回复") {
                                guard draftingID == nil else { return }
                                draftingID = item.id
                                draftFailNote = ""
                                Task {
                                    let ok = await model.draftWechatReply(item)
                                    draftingID = nil
                                    if !ok {
                                        draftFailNote = "没送出去，微信卡还在——可再点一次起草"
                                    }
                                }
                            }
                            .buttonStyle(.secondaryCompact)
                            .disabled(draftingID != nil)
                            Button("已经回了") {
                                withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { _ = hidden.insert(item.id) }
                                Task {
                                    if !(await model.waitingAck(item)) {
                                        withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { _ = hidden.remove(item.id) }
                                    }
                                }
                            }.buttonStyle(.quiet)
                        }.padding(.leading, 44)
                    }
                    .transition(reduce ? .opacity : .asymmetric(
                        insertion: .opacity,
                        removal: .opacity.combined(with: .move(edge: .trailing))))
                }
                .enterRise(on: shown, delay: 0.12, y: 12, blur: 5)
                .animation(ComMotion.reduced(reduce, ComMotion.settle), value: hidden)
                section("过期的待办", kind: "todo") { item in
                    let path = item["path"].string
                    let todoBusy = todoBusyID == item.id
                    row(item, symbol: "checklist", tone: .warning) { model.openThreadNode(.object(["kind": .string("todo"), "url": item["url"]])) }
                        .opacity(todoBusy ? 0.55 : 1)
                        .contextMenu {
                            Button(todoBusy ? "改期中…" : "改到明天", systemImage: "arrow.uturn.forward") {
                                guard todoBusyID == nil else { return }
                                todoBusyID = item.id
                                todoFailNote = ""
                                withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { _ = hidden.insert(item.id) }
                                Task {
                                    let ok = await model.waitingTodo(path, "postpone")
                                    todoBusyID = nil
                                    if !ok {
                                        withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { _ = hidden.remove(item.id) }
                                        todoFailNote = "改期没成，待办还在——可再试"
                                    }
                                }
                            }
                            .disabled(todoBusyID != nil)
                            Button(todoBusy ? "完成中…" : "完成", systemImage: "checkmark.circle") {
                                guard todoBusyID == nil else { return }
                                todoBusyID = item.id
                                todoFailNote = ""
                                withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { _ = hidden.insert(item.id) }
                                Task {
                                    let ok = await model.waitingTodo(path, "done")
                                    todoBusyID = nil
                                    if !ok {
                                        withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) { _ = hidden.remove(item.id) }
                                        todoFailNote = "没标完成，待办还在——可再试"
                                    }
                                }
                            }
                            .disabled(todoBusyID != nil)
                            Button(todoBusy ? "交接中…" : "交给我办", systemImage: "paperplane") {
                                guard todoBusyID == nil else { return }
                                todoBusyID = item.id
                                todoFailNote = ""
                                handoffNote = ""
                                Task {
                                    // "" = 进主对话；非空 = 航程；nil = 失败（别假报已接进）。
                                    let id = await model.delegateTodo(path)
                                    todoBusyID = nil
                                    guard let id else {
                                        todoFailNote = "没接上，待办还在——可再试「交给我办」"
                                        return
                                    }
                                    model.showWaiting = false
                                    if id.isEmpty {
                                        handoffNote = "已接进主对话——去 Com 页继续"
                                    } else {
                                        handoffNote = "已接进航程"
                                        model.openThreadNode(.object(["kind": .string("case"), "id": .string(id)]))
                                    }
                                }
                            }
                            .disabled(todoBusyID != nil)
                        }
                }
                .enterRise(on: shown, delay: 0.16, y: 12, blur: 5)
            }
            .navigationTitle("等你").navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Palette.background, for: .navigationBar)
            .toolbar {
                if pulling {
                    ToolbarItem(placement: .topBarLeading) {
                        ProgressView().controlSize(.small).accessibilityLabel("正在拉齐等你")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .refreshable { await pullWaiting(force: true) }
            .task { await pullWaiting(force: false) }
            .onAppear {
                if reduce { shown = true }
                else { withAnimation(ComMotion.rise) { shown = true } }
            }
        }
    }
    private func pullWaiting(force: Bool) async {
        // 入口 openWaitingInbox 可能已在拉——等它结束，避免叠刷；再根据 errors 开口。
        if model.waitingOpening && !force {
            while model.waitingOpening && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
            }
            loadedOnce = true
            let hadCache = !model.waitingData["items"].array.isEmpty || !model.pendingItems.filter { !$0.stale }.isEmpty
            applyWaitingFail(ok: model.errors[waitingPath] == nil && (model.datasets[waitingPath] != nil || !model.waitingData.isNull),
                             hadCache: hadCache)
            return
        }
        guard !loading else { return }
        loading = true
        if force { failNote = "" }
        defer {
            loading = false
            loadedOnce = true
        }
        let hadCache = !model.waitingData["items"].array.isEmpty || !model.pendingItems.filter { !$0.stale }.isEmpty
        let ok = await model.load(waitingPath) != nil
        await model.refreshFlow()
        applyWaitingFail(ok: ok, hadCache: hadCache)
    }
    private func applyWaitingFail(ok: Bool, hadCache: Bool) {
        guard !ok else {
            failNote = ""
            model.waitingOpenNote = ""
            return
        }
        let err = model.errors[waitingPath] ?? ""
        failNote = err.isEmpty
            ? (hadCache ? "等你清单没刷新上——下面仍是上一版，可再试" : "等你清单没拉齐——检查配对或网络后再试")
            : (hadCache ? "等你清单没刷新上：" + err + "——下面仍是上一版" : "等你清单没拉齐：" + err + "——可再试")
    }
    @ViewBuilder private func section<Row: View>(_ title: String, kind: String, @ViewBuilder row: @escaping (JSON) -> Row) -> some View {
        let rows = items.filter { $0["kind"].string == kind }
        if !rows.isEmpty {
            GroupSection(title + " · \(rows.count)", footer: kind == "todo" ? "长按改到明天、完成或交给 Com；点开在 Obsidian 里看。" : "") {
                GroupedCard { ForEach(rows.map(RemoteRow.init)) { r in row(r.value).rowPadding() } }
            }
        }
    }
    private func row(_ item: JSON, symbol: String, tone: Tone, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            ListRow(symbol: symbol, tone: tone, title: item["title"].string, titleLines: 1, subtitle: item["why"].string, subtitleLines: 2) {}
                .contentShape(.rect)
        }
        .buttonStyle(SoftPressStyle(scale: 0.985))
        .accessibilityIdentifier("waiting-" + item.id)
    }
}

#if DEBUG
extension AppModel {
    /// `--ui-cases` 附带：等你收件箱和线索条的验收数据。
    func seedThreadsPreview() {
        datasets["/personal/waiting"] = .object(["count": .number(3), "items": .array([
            .object(["id": .string("case:task_demo_wait"), "kind": .string("case"), "title": .string("清理旧素材草稿"), "why": .string("等你批准：删掉 3 份已过期的旧草稿？"), "case_id": .string("task_demo_wait")]),
            .object(["id": .string("wechat:梦雨"), "kind": .string("wechat"), "title": .string("梦雨"), "why": .string("梦雨：周报今天能发吗？")]),
            .object(["id": .string("todo:任务/待处理/大有可攀场地对接.md"), "kind": .string("todo"), "title": .string("大有可攀场地对接"), "why": .string("过期 5 天（计划 10-13）"), "path": .string("任务/待处理/大有可攀场地对接.md")])])])
        let thread: JSON = .object(["nodes": .array([
            .object(["key": .string("next:next-reply"), "kind": .string("next"), "id": .string("next-reply"), "label": .string("下一步"), "title": .string("回复王总的排期邮件"), "state": .string("已交给 Com"), "current": .bool(false)]),
            .object(["key": .string("case:task_demo_running"), "kind": .string("case"), "id": .string("task_demo_running"), "label": .string("航程"), "title": .string("起草王总排期回复"), "state": .string("进行中"), "current": .bool(true)]),
            .object(["key": .string("session:pi:com-demo"), "kind": .string("session"), "id": .string("pi:com-demo"), "label": .string("工作会话"), "title": .string("Pi 执行会话"), "state": .string("deepseek-v4.1-flash"), "current": .bool(false)]),
            .object(["key": .string("project:合同与劳务结算"), "kind": .string("project"), "id": .string("合同与劳务结算"), "label": .string("项目页"), "title": .string("合同与劳务结算"), "state": .string("项目"), "current": .bool(false)])])])
        datasets["/personal/thread?key=case:task_demo_running"] = thread
        if ProcessInfo.processInfo.environment["COM_PREVIEW_SHEET"] == "waiting" { showWaiting = true }
    }
}
#endif
