import SwiftUI
import ComCore

struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var category = "全部"
    @State private var search = ""
    private var items: [JSON] { model.datasets["/personal/memory"]?["items"].array ?? [] }
    private var categories: [String] { model.datasets["/personal/memory"]?["categories"].array.map(\.string) ?? [] }
    var body: some View {
        ScreenScaffold(title: "记忆", subtitle: "关于你的了解，都在这里。", freshness: "/personal/memory") {
            VStack(alignment: .leading, spacing: Space.md) {
                SearchField(text: $search, prompt: "搜索记忆")
                FilterChips(options: ["全部"] + categories.filter { $0 != "全部" }, selection: $category, haptic: true)
                HStack {
                    if !items.isEmpty {
                        let sharedCount = items.filter { $0["kind"].string == "knowledge" }.count
                        Text("\(items.count) 条记忆 · \(sharedCount) 份共享知识")
                            .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if category != "全部" { Button("显示全部记忆") { category = "全部" }.buttonStyle(.quiet).font(TypeScale.footnote.weight(.semibold)) }
                }
            }
            let filtered = items.filter { (category == "全部" || $0["category"].string == category) && (search.isEmpty || $0["content"].string.localizedCaseInsensitiveContains(search)) }
            if filtered.isEmpty {
                EmptyState(title: "这里还留着空白", description: "没有符合筛选条件的记忆。", symbol: "sparkles.rectangle.stack")
            } else {
                GroupedCard(dividerInset: Layout.rowInset) {
                    ForEach(filtered.map(RemoteRow.init)) { row in
                        Button { model.selectedMemory = row.value } label: {
                            ListRow(symbol: categorySymbol(row.value["category"].string), tone: row.value["read_only"].bool ? .info : .accent,
                                    title: row.value["title"].string.isEmpty ? row.value["category"].string : row.value["title"].string,
                                    subtitle: row.value["summary"].string.isEmpty ? row.value["content"].string : row.value["summary"].string, subtitleLines: 3,
                                    meta: row.value["read_only"].bool ? row.value["category"].string + " · 共享知识" : "")
                        }.buttonStyle(.row).detailSource("memory-" + row.id)
                    }
                }
            }
        }.refreshable { await model.refresh(.memory) }
    }
}

struct MemoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let memory: JSON
    @State private var text = ""
    @State private var editing = false
    @State private var saving = false
    @State private var note = ""
    var body: some View {
        DetailPage(title: "记忆") {
            DetailHeader(title: memory["title"].string) {
                StatusPill(text: memory["category"].string, tone: memory["read_only"].bool ? .info : .accent)
            }
            if editing {
                VStack(alignment: .leading, spacing: Space.md) {
                    TextEditor(text: $text).font(TypeScale.body).scrollContentBackground(.hidden).frame(minHeight: 240).padding(Space.md)
                        .background(Palette.surface, in: .rect(cornerRadius: Radius.lg, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.accentText.opacity(0.5), lineWidth: 1))
                    Button("保存纠正") {
                        saving = true
                        Task {
                            do {
                                _ = try await model.mutate("/personal/memory/" + memory.id.pathEncoded, fields: ["content": .string(text), "expected_version": memory["version"]])
                                await model.refresh(.memory); dismiss()
                            } catch { note = error.localizedDescription }
                            saving = false
                        }
                    }.buttonStyle(.primaryFull).disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !note.isEmpty { InlineNotice(text: note) }
                }
            } else {
                Card(padding: Space.xl) { RichText(text: memory["content"].string) }
                if !memory["read_only"].bool {
                    Button { text = memory["content"].string; editing = true } label: { Label("纠正这条记忆", systemImage: "pencil") }.buttonStyle(.secondaryAction)
                }
            }
            Text(memory["read_only"].bool ? "来自共享知识库，来源文件更新后会自动同步。" : "保存时核对版本，旧内容与来源会保留。")
                .font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
            GroupedCard {
                if !memory["source"]["path"].string.isEmpty {
                    DisclosureGroup("原始来源") { CodeBlock(text: memory["source"]["path"].string).padding(.top, Space.sm) }
                        .font(TypeScale.callout).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary).rowPadding()
                } else { RawDetails(title: "原始来源", value: memory["source"]).rowPadding() }
                if !memory["history"].array.isEmpty {
                    DisclosureGroup("历史版本") {
                        ForEach(Array(memory["history"].array.enumerated()), id: \.offset) { _, old in
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Text("历史版本 \(old["version"].int)").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                                RichText(text: old["content"].string)
                            }.padding(.top, Space.sm)
                        }
                    }.font(TypeScale.callout).tint(Palette.textSecondary).foregroundStyle(Palette.textPrimary).rowPadding()
                }
            }
        }
    }
}

func categorySymbol(_ category: String) -> String {
    ["关于我": "person.crop.circle", "工作": "briefcase", "项目": "square.stack.3d.up", "生活": "leaf", "兴趣": "sparkles", "健康": "heart", "财务": "chart.bar"][category] ?? "bookmark"
}
