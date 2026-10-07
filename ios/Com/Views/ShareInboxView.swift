import SwiftUI
import ComCore

struct ShareInboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var drafts = ShareInbox.all()
    @State private var loading = false
    @State private var note = ""
    var body: some View {
        NavigationStack {
            ScrollPage(spacing: Space.md) {
                InlineNotice(text: "检查后放入聊天草稿。此处不会自动交办。", tone: .neutral).padding(.bottom, Space.xs)
                ForEach(drafts) { draft in
                    Card {
                        VStack(alignment: .leading, spacing: Space.md) {
                            if !draft.text.isEmpty { Text(draft.text).font(TypeScale.callout).textSelection(.enabled) }
                            ForEach(draft.attachments) { attachment in
                                Label(attachment.name, systemImage: "paperclip").font(TypeScale.footnote).foregroundStyle(Palette.textSecondary)
                            }
                            HStack(spacing: Space.lg) {
                                Button("加入聊天草稿") { Task { await importDraft(draft) } }.buttonStyle(.primaryCompact).disabled(loading || !model.isPaired)
                                Button("丢弃这次分享", role: .destructive) { ShareInbox.remove(draft); drafts = ShareInbox.all() }.buttonStyle(.quiet).disabled(loading)
                            }.padding(.top, Space.xs)
                        }
                    }
                }
                if !note.isEmpty { InlineNotice(text: note) }
            }.navigationTitle("分享收件箱").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
    private func importDraft(_ draft: SharedDraft) async {
        guard let api = model.client else { return }
        guard model.attachments.count + draft.attachments.count <= 8 else { note = "草稿最多八个附件，请先整理已有附件"; return }
        loading = true; defer { loading = false }
        do {
            var files: [JSON] = []
            for item in draft.attachments {
                guard let url = ShareInbox.file(draft, attachment: item) else { throw CocoaError(.fileReadUnknown) }
                files.append(try await api.uploadAttachment(Data(contentsOf: url), name: item.name, mime: item.mime, id: item.id))
            }
            let text = model.draft + (model.draft.isEmpty || draft.text.isEmpty ? "" : "\n") + draft.text
            let attachments = model.attachments + files
            try SecureVault.save(text, name: "draft"); try SecureVault.save(attachments, name: "draft-attachments")
            model.draft = text; model.attachments = attachments; model.tab = .chat
            ShareInbox.remove(draft); drafts = ShareInbox.all()
            if drafts.isEmpty { dismiss() }
        } catch { note = error.localizedDescription + "，原分享仍保留，可重试。" }
    }
}
