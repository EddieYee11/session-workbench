import SwiftUI
import ComCore

struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var category = "全部"
    @State private var search = ""
    private var items: [JSON] { model.datasets["/personal/memory"]?["items"].array ?? [] }
    private var categories: [String] { model.datasets["/personal/memory"]?["categories"].array.map(\.string) ?? [] }
    var body: some View {
        PageCanvas {
            PageHeading(title: "记忆", subtitle: "关于你的了解，都在这里。")
            InlineSearch(text: $search, prompt: "搜索记忆")
            Freshness(path: "/personal/memory")
            if !items.isEmpty {
                let sharedCount = items.filter { $0["kind"].string == "knowledge" }.count
                Text("\(items.count) 条记忆 · \(sharedCount) 份共享知识")
                    .font(TypeScale.footnote).foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: Space.sm) {
                    ForEach(["全部"] + categories.filter { $0 != "全部" }, id: \.self) { name in
                        Button { category = name; Haptics.selection() } label: {
                            Text(name).font(TypeScale.chat).padding(.horizontal, 17).padding(.vertical, 10)
                                .foregroundStyle(category == name ? Palette.onAccent : Color.primary).background(category == name ? Palette.accent : Palette.surface, in: .capsule)
                        }.buttonStyle(.plain)
                    }
                }
            }.scrollIndicators(.hidden)
            if category != "全部" { Button("显示全部记忆") { category = "全部" }.font(TypeScale.footnote) }
            let filtered = items.filter { (category == "全部" || $0["category"].string == category) && (search.isEmpty || $0["content"].string.localizedCaseInsensitiveContains(search)) }
            if filtered.isEmpty { EmptyState(title: "这里还留着空白", description: "没有符合筛选条件的记忆。", symbol: "sparkles.rectangle.stack") }
            ForEach(filtered.map(RemoteRow.init)) { row in
                Button { model.selectedMemory = row.value } label: {
                    RowCard {
                        HStack(alignment: .top, spacing: Space.lg) {
                            IconBadge(symbol: categorySymbol(row.value["category"].string))
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Text(row.value["title"].string.isEmpty ? row.value["category"].string : row.value["title"].string).font(TypeScale.chat.weight(.semibold))
                                Text(row.value["summary"].string.isEmpty ? row.value["content"].string : row.value["summary"].string).font(TypeScale.footnote).foregroundStyle(.secondary).lineLimit(3)
                                if row.value["read_only"].bool {
                                    Text(row.value["category"].string + " · 共享知识").font(TypeScale.footnote).foregroundStyle(.tertiary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.buttonStyle(.plain).detailSource("memory-" + row.id)
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
            Pill(text: memory["category"].string)
            if !memory["title"].string.isEmpty { Text(memory["title"].string).font(TypeScale.sectionTitle) }
            if editing {
                TextEditor(text: $text).frame(minHeight: 240).padding(Space.md).background(Palette.surface, in: .rect(cornerRadius: Radius.small))
                Button("保存纠正") {
                    saving = true
                    Task {
                        do {
                            _ = try await model.mutate("/personal/memory/" + memory.id.pathEncoded, fields: ["content": .string(text), "expected_version": memory["version"]])
                            await model.refresh(.memory); dismiss()
                        } catch { note = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(.limeProminent).disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !note.isEmpty { Text(note).font(TypeScale.footnote).foregroundStyle(Palette.coral) }
            } else {
                RichText(text: memory["content"].string)
                if !memory["read_only"].bool {
                    Button("纠正这条记忆", systemImage: "pencil") { text = memory["content"].string; editing = true }.buttonStyle(.quiet)
                }
            }
            Text(memory["read_only"].bool ? "来自共享知识库，来源文件更新后会自动同步。" : "保存时核对版本，旧内容与来源会保留。")
                .font(TypeScale.footnote).foregroundStyle(.tertiary)
            if !memory["source"]["path"].string.isEmpty {
                DisclosureGroup("原始来源") { Text(memory["source"]["path"].string).font(TypeScale.footnote).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, Space.sm) }.font(TypeScale.chat).tint(.primary)
            } else { RawDetails(title: "原始来源", value: memory["source"]) }
            if !memory["history"].array.isEmpty {
                DisclosureGroup("历史版本") {
                    ForEach(Array(memory["history"].array.enumerated()), id: \.offset) { _, old in
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text("历史版本 \(old["version"].int)").font(TypeScale.footnote).foregroundStyle(.tertiary)
                            RichText(text: old["content"].string)
                        }.padding(.top, Space.sm)
                    }
                }.font(TypeScale.chat).tint(.primary)
            }
        }
    }
}

func categorySymbol(_ category: String) -> String {
    ["关于我": "person.crop.circle", "工作": "briefcase", "项目": "square.stack.3d.up", "生活": "leaf", "兴趣": "sparkles", "健康": "heart", "财务": "chart.bar"][category] ?? "bookmark"
}
