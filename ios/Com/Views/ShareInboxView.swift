import SwiftUI
import ComCore

struct ShareInboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var drafts: [SharedDraft] = []
    @State private var loading = false
    @State private var listLoading = false
    @State private var listFail = ""
    @State private var listLoadedOnce = false
    @State private var note = ""
    @State private var noteFailed = false
    @State private var shown = false
    var body: some View {
        NavigationStack {
            ScrollPage(spacing: Space.md) {
                InlineNotice(text: "检查后放入聊天草稿。这里不会自动交办——你点头我才动手。", tone: .neutral)
                    .padding(.bottom, Space.xs)
                    .modifier(EnterRise(on: shown, delay: 0, y: 10, blur: 4, animation: ComMotion.rise))
                if listLoading || !listLoadedOnce {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("正在拉齐分享…").font(TypeScale.footnote).foregroundStyle(Palette.textTertiary)
                    }
                    .accessibilityLabel("正在拉齐分享收件箱")
                    .accessibilityIdentifier("share-inbox-pulling")
                }
                if !listFail.isEmpty {
                    InlineNotice(text: listFail, tone: .danger)
                    Button(listLoading ? "重试中…" : "再试一次") {
                        guard !listLoading else { return }
                        reloadList()
                    }
                    .buttonStyle(.secondaryCompact)
                    .disabled(listLoading)
                    .accessibilityIdentifier("share-inbox-retry")
                }
                if drafts.isEmpty && listLoadedOnce && !listLoading {
                    EmptyState(title: listFail.isEmpty ? "还没收过分享" : "分享还没读上",
                               description: listFail.isEmpty
                                ? "在别的 App 里点「分享 → Com」，文字、链接和文件会先停在这里，你确认后再进聊天草稿。"
                                : "先重试拉齐收件箱；通了再「加入聊天草稿」。",
                               symbol: "tray.and.arrow.down")
                    .modifier(EnterRise(on: shown, delay: 0.05, y: 12, blur: 5, animation: ComMotion.pop))
                }
                ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                    Card {
                        VStack(alignment: .leading, spacing: Space.md) {
                            if !draft.text.isEmpty { Text(draft.text).font(TypeScale.callout).textSelection(.enabled) }
                            ForEach(draft.attachments) { attachment in
                                Label(attachment.name, systemImage: "paperclip").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                            }
                            HStack(spacing: Space.lg) {
                                Button(loading ? "加入中…" : "加入聊天草稿") { Task { await importDraft(draft) } }
                                    .buttonStyle(.primaryCompact)
                                    .disabled(loading || !model.isPaired || listLoading)
                                    .accessibilityIdentifier("share-import")
                                Button("丢弃这次分享", role: .destructive) {
                                    withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) {
                                        ShareInbox.remove(draft); reloadList()
                                    }
                                }.buttonStyle(.quiet).disabled(loading || listLoading)
                            }.padding(.top, Space.xs)
                        }
                    }
                    .modifier(EnterRise(on: shown, delay: 0.06 + Double(min(index, 5)) * ComMotion.stagger, y: 10, blur: 4, animation: ComMotion.pop))
                }
                if !note.isEmpty { InlineNotice(text: note, tone: noteFailed ? .danger : .neutral) }
            }.navigationTitle("分享收件箱").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .refreshable { reloadList() }
                .onAppear {
                    reloadList()
                    if reduce { shown = true }
                    else { withAnimation(ComMotion.rise) { shown = true } }
                }
        }
    }
    private func reloadList() {
        guard !listLoading else { return }
        listLoading = true
        listFail = ""
        defer {
            listLoading = false
            listLoadedOnce = true
        }
        let batch = ShareInbox.loadAll()
        if let err = batch.error, !err.isEmpty {
            listFail = "分享收件箱没拉齐：" + err + "——可再试"
            // 与前台角标同口径：目录失败时别让主聊假装没事。
            model.shareInboxNote = "分享收件箱没读上：\(err)——可能有待处理分享。可再试。不会假装没有。"
            // 目录瞬断保留已有列表，别假空。
            if !drafts.isEmpty { return }
            drafts = []
            return
        }
        drafts = batch.items
        if batch.decodeFailures > 0 {
            listFail = "有 \(batch.decodeFailures) 条分享解不开——下面是能读的；可再试"
            model.shareInboxNote = "有 \(batch.decodeFailures) 条分享解不开——能读的在收件箱里。可核对。"
        } else {
            // 拉齐成功：清掉前台「没读上」开口。
            model.shareInboxNote = ""
        }
    }
    private func importDraft(_ draft: SharedDraft) async {
        guard !loading else { return }
        note = ""
        noteFailed = false
        guard model.isPaired, let client = model.client else {
            noteFailed = true
            note = "还没连上 mini，先配对再加入草稿——分享仍保留。不会假装已加入。"
            return
        }
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty else {
            noteFailed = true
            note = "这条分享是空的——没有文字也没有附件。不会假装已加入草稿。"
            return
        }
        guard model.attachments.count + draft.attachments.count <= 8 else {
            noteFailed = true
            note = "草稿最多八个附件，请先整理已有附件——分享仍保留。不会假装已加入。"
            return
        }
        loading = true
        defer { loading = false }
        do {
            var files: [JSON] = []
            for item in draft.attachments {
                guard let url = ShareInbox.file(draft, attachment: item) else {
                    throw APIError(status: 0, detail: "附件「\(item.name)」在收件箱里找不到")
                }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw APIError(status: 0, detail: "附件「\(item.name)」文件已丢失")
                }
                let data = try Data(contentsOf: url)
                guard !data.isEmpty else {
                    throw APIError(status: 0, detail: "附件「\(item.name)」是空文件")
                }
                let uploaded = try await client.uploadAttachment(data, name: item.name, mime: item.mime, id: item.id)
                let aid = uploaded.id.isEmpty ? uploaded["id"].string : uploaded.id
                guard !aid.isEmpty else {
                    throw APIError(status: 0, detail: "附件「\(item.name)」上传没回编号")
                }
                files.append(uploaded)
            }
            let text = model.draft + (model.draft.isEmpty || draft.text.isEmpty ? "" : "\n") + draft.text
            let attachments = model.attachments + files
            try SecureVault.save(text, name: "draft")
            try SecureVault.save(attachments, name: "draft-attachments")
            model.draft = text
            model.attachments = attachments
            model.persistNow()
            // 落盘后再核对：内存草稿对不上就别 dismiss 假成功。
            let textOK = model.draft == text
            let attachOK = model.attachments.count == attachments.count
            guard textOK && attachOK else {
                noteFailed = true
                note = "草稿没写稳——分享仍保留，可再试。不会假装已加入。"
                return
            }
            let cleared = ShareInbox.remove(draft)
            reloadList()
            model.tab = .chat
            if !cleared {
                // 草稿已进聊天，但收件箱没删干净——开口说明，仍进聊天核对。
                model.chatComposerNote = "分享已进草稿；收件箱那条没删掉——可在聊天核对，回头再丢弃。不会假装收件箱已清空。"
            } else {
                model.chatComposerNote = ""
            }
            dismiss()
        } catch {
            noteFailed = true
            note = "没加进去：" + error.localizedDescription + "——原分享仍保留，可重试。不会假装已加入。"
        }
    }
}
