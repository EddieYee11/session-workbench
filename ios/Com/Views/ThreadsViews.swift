import SwiftUI
import ComCore

// 线索 + 统一「等你」（2026-10-18）。
// 线索：每张卡片都能看到上下游（对话 → 下一步 → 待办 → 航程 → 执行会话 → 项目页），点哪一环就跳到哪。后端 backend/threads.py（/personal/thread）。
// 等你：审批卡（App 里已有的 pendingItems）+ 等你批准的航程 + 微信在等回话 + 过期待办，一个角标一个收件箱。后端 /personal/waiting。

extension AppModel {
    var waitingData: JSON { datasets["/personal/waiting"] ?? .null }
    /// 全局「等你」数：审批卡 + 后端汇总的三类。Dock 徽标、顶栏、灵动岛都读它。
    var waitingCount: Int { decisionCount + waitingData["count"].int }

    /// 打开线索里的一环。先收起正在看的航程 sheet，再跳过去。
    func openThreadNode(_ node: JSON) {
        let ident = node["id"].string
        switch node["kind"].string {
        case "case":
            presentedCase = nil
            showWaiting = false
            Task { try? await Task.sleep(for: .milliseconds(350)); presentedCase = ident }
        case "next":
            presentedCase = nil; showCases = false; showWaiting = false; tab = .next
        case "msg":
            presentedCase = nil; showCases = false; showWaiting = false
            Task { await locateMessage(ident) }
        case "session":
            presentedCase = nil; showCases = false; showWaiting = false
            selectedSession = .object(["id": .string(ident), "agent": node["agent"].isNull ? .string("pi") : node["agent"]])
        default:
            if let url = URL(string: node["url"].string), !node["url"].string.isEmpty { UIApplication.shared.open(url) }
        }
    }

    /// 微信在等回话：让 Com 起草回复（发到主对话，草稿给他确认，不替他发）。
    func draftWechatReply(_ item: JSON) async {
        showWaiting = false
        tab = .chat
        await send(textOverride: "帮我起草一条回复给「" + item["title"].string + "」的微信，对方最后说：" + item["why"].string + "。先给我看草稿，不要替我发。")
    }
    func waitingTodo(_ path: String, _ action: String) async {
        do {
            _ = try await mutate("/personal/today/todos/" + action, fields: ["path": .string(path)])
            Haptics.success()
            _ = await load("/personal/waiting"); _ = await load("/personal/today")
        } catch { banner = error.localizedDescription }
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
    private var path: String { "/personal/thread?key=" + (key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? key) }
    var body: some View {
        let nodes = model.datasets[path]?["nodes"].array ?? []
        Group {
            if nodes.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("线索").font(TypeScale.caption).foregroundStyle(Palette.textTertiary)
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
            }
        }
        .task(id: key) { _ = await model.load(path) }
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
    @State private var hidden: Set<String> = []
    private var items: [JSON] { model.waitingData["items"].array.filter { !hidden.contains($0.id) } }
    var body: some View {
        NavigationStack {
            ScrollPage(spacing: Layout.sectionSpacing) {
                let decisions = model.pendingItems.filter { !$0.stale }
                if decisions.isEmpty && items.isEmpty {
                    EmptyState(title: "没有在等你的事", description: "要你拍板的审批、停下来等你批准的航程、微信里有人在等回话、过期的待办，都会汇到这里。", symbol: "checkmark.circle")
                }
                if !decisions.isEmpty {
                    GroupSection("要你拍板 · \(decisions.count)") { ForEach(decisions) { item in PendingNote(item: item) } }
                }
                section("航程停下来等你", kind: "case") { item in
                    row(item, symbol: "rectangle.stack", tone: .warning) { model.openThreadNode(.object(["kind": .string("case"), "id": item["case_id"]])) }
                }
                section("微信在等你回", kind: "wechat") { item in
                    VStack(alignment: .leading, spacing: Space.sm) {
                        row(item, symbol: "bubble.left.and.bubble.right", tone: .info) {}
                        HStack(spacing: Space.sm) {
                            Button("让 Com 起草回复") { Task { await model.draftWechatReply(item) } }.buttonStyle(.secondaryCompact)
                            Button("已经回了") { withAnimation(.smooth(duration: 0.25)) { _ = hidden.insert(item.id) } }.buttonStyle(.quiet)
                        }.padding(.leading, 44)
                    }
                }
                section("过期的待办", kind: "todo") { item in
                    let path = item["path"].string
                    row(item, symbol: "checklist", tone: .warning) { model.openThreadNode(.object(["kind": .string("todo"), "url": item["url"]])) }
                        .contextMenu {
                            Button("改到明天", systemImage: "arrow.uturn.forward") { Task { await model.waitingTodo(path, "postpone") } }
                            Button("完成", systemImage: "checkmark.circle") { Task { await model.waitingTodo(path, "done") } }
                            Button("交给 Com", systemImage: "paperplane") { Task { if let id = await model.delegateTodo(path) { model.showWaiting = false; model.openThreadNode(.object(["kind": .string("case"), "id": .string(id)])) } } }
                        }
                }
            }
            .navigationTitle("等你").navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Palette.background, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .refreshable { _ = await model.load("/personal/waiting"); await model.refreshFlow() }
            .task { _ = await model.load("/personal/waiting") }
        }
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
        .buttonStyle(.plain)
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
