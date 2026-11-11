import SwiftUI
import ComCore

public struct MatterArchiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selectedStatus: String = "all" // "all", "done", "cancelled"
    @State private var items: [JSON] = []
    @State private var loading: Bool = false
    @State private var errorMessage: String = ""
    @State private var restoringId: String? = nil

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索输入栏
                HStack(spacing: Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Palette.textSecondary)
                    TextField("搜索事项标题、原因、标签…", text: $query)
                        .font(TypeScale.callout)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("archive-search-input")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
                .padding(Space.md)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.md))
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)

                // 筛选标签
                HStack(spacing: Space.sm) {
                    filterChip(label: "全部", status: "all")
                    filterChip(label: "已完成", status: "done")
                    filterChip(label: "已取消", status: "cancelled")
                    Spacer()
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)

                Divider().opacity(0.4)

                // 列表区域
                if loading && items.isEmpty {
                    Spacer()
                    ProgressView("正在检索本地归档…")
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                } else if !errorMessage.isEmpty && items.isEmpty {
                    Spacer()
                    InlineNotice(text: errorMessage, tone: .warning)
                        .padding(.horizontal, Space.xl)
                    Spacer()
                } else if items.isEmpty {
                    Spacer()
                    VStack(spacing: Space.sm) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 36))
                            .foregroundStyle(Palette.textTertiary)
                        Text(query.isEmpty ? "暂无历史归档事项" : "未找到匹配归档事项")
                            .font(TypeScale.callout)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(items, id: \.["matter_id"].string) { item in
                            archiveItemRow(item)
                                .listRowInsets(EdgeInsets(top: Space.sm, leading: Space.lg, bottom: Space.sm, trailing: Space.lg))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollDismissesKeyboard(.immediately)
                }
            }
            .background(Palette.background)
            .navigationTitle("事项归档与搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("archive-sheet-close")
                }
            }
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(300))
                await fetchArchive()
            }
            .task(id: selectedStatus) {
                await fetchArchive()
            }
        }
    }

    private func filterChip(label: String, status: String) -> some View {
        let isSelected = selectedStatus == status
        return Button {
            selectedStatus = status
        } label: {
            Text(label)
                .font(TypeScale.footnote.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                .background(isSelected ? Palette.accent : Palette.fill, in: Capsule())
                .foregroundStyle(isSelected ? Palette.onAccent : Palette.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("archive-filter-\(status)")
    }

    private func archiveItemRow(_ item: JSON) -> some View {
        let matterId = item["matter_id"].string
        let title = item["title"].string
        let why = item["why"].string
        let status = item["status"].string
        let isArchived = item["is_archived"].bool ?? true
        let obsidianUrl = item["obsidian_url"].string
        let isRestoring = restoringId == matterId

        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(TypeScale.body.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                    if !why.isEmpty {
                        Text(why)
                            .font(TypeScale.footnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer()
                // 恢复 / 激活按钮
                Button {
                    Task { await restore(matterId: matterId) }
                } label: {
                    if isRestoring {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("激活")
                        }
                        .font(TypeScale.caption.weight(.medium))
                        .foregroundStyle(Palette.accentText)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 4)
                        .background(Palette.accent.opacity(0.15), in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRestoring)
                .accessibilityIdentifier("archive-restore-\(matterId)")
            }

            HStack(spacing: Space.sm) {
                Text(status == "done" ? "已完成" : (status == "cancelled" ? "已取消" : status))
                    .font(TypeScale.caption.weight(.medium))
                    .foregroundStyle(status == "done" ? Palette.success : Palette.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(status == "done" ? Palette.success.opacity(0.12) : Palette.fill, in: RoundedRectangle(cornerRadius: 4))

                if isArchived {
                    Text("冷归档")
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.textTertiary)
                }

                if !obsidianUrl.isEmpty, let url = URL(string: obsidianUrl) {
                    Link(destination: url) {
                        HStack(spacing: 2) {
                            Image(systemName: "link")
                            Text("Obsidian")
                        }
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.info)
                    }
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(Space.md)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .stroke(Palette.fill, lineWidth: 1)
        )
    }

    private func fetchArchive() async {
        loading = true
        errorMessage = ""
        let statusParam = selectedStatus == "all" ? "" : "&status=\(selectedStatus)"
        let encodedQ = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let path = "/personal/matters/archive?q=\(encodedQ)\(statusParam)"

        if let res = await model.load(path) {
            items = res["items"].array
            loading = false
        } else {
            loading = false
            errorMessage = model.errors[path] ?? "加载归档失败"
        }
    }

    private func restore(matterId: String) async {
        restoringId = matterId
        let ok = await model.action("/personal/matters/\(matterId)/restore", fields: ["target_status": .string("todo")], refresh: .next)
        if ok {
            Haptics.success()
            items.removeAll(where: { $0["matter_id"].string == matterId })
            _ = await model.load("/personal/board")
        }
        restoringId = nil
    }
}
