import SwiftUI
import UIKit
import ComCore

// Grok Bot 式四类原生气泡（text / attachment / widget / secret-request）
// + Live 工具活动胶囊 + 输入框上方双胶囊（上下文吸附 & 剪贴板一键投递） + 边干边报轻播报开关。

struct SendMessagePreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    var htmlState: String = "{}"
}

// MARK: - 1. Assistant 四类气泡统一入口

struct AssistantBubbleBodyView: View {
    let message: JSON
    let bubble: SendMessageBubble

    var body: some View {
        switch bubble.type {
        case .text:
            TextWithImagesBubbleView(message: message, bubble: bubble)
        case .attachment:
            AttachmentCardBubble(messageID: message.id, bubble: bubble)
        case .widget:
            VStack(alignment: .leading, spacing: Space.sm) {
                let lead = ReplyOptions.split(bubble.content).0.trimmingCharacters(in: .whitespacesAndNewlines)
                if !lead.isEmpty && lead != bubble.widget["title"].string {
                    ReplyText(text: lead, motionID: message.id, createdAt: message["created_at"].double)
                        .foregroundStyle(Palette.textPrimary)
                        .agentBubble()
                        .accessibilityIdentifier("agent-bubble-lead-" + message.id)
                }
                WidgetBubbleView(
                    messageID: message.id,
                    spec: bubble.widget,
                    stateKey: "widget:\(message.id):bubble"
                )
            }
        case .secretRequest:
            SecretEntryBubbleView(messageID: message.id, bubble: bubble)
        }
    }
}

private struct TextWithImagesBubbleView: View {
    let message: JSON
    let bubble: SendMessageBubble

    private var cleanText: String {
        let raw = bubble.content.isEmpty ? message["text"].string : bubble.content
        return ReplyOptions.split(raw).0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if !cleanText.isEmpty || bubble.images.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if cleanText.hasPrefix("已记") {
                        Label("已记账", systemImage: "yensign.circle.fill")
                            .font(TypeScale.caption.weight(.semibold))
                            .foregroundStyle(Palette.success)
                            .accessibilityIdentifier("chat-bookkeep-receipt-" + message.id)
                            .onAppear {
                                let age = Date().timeIntervalSince1970 - message["created_at"].double
                                if age >= 0, age < 3 { Haptics.success() }
                            }
                    }
                    ClampedWhenProactive(id: message.id, proactive: ProactiveMessage.matches(message), text: cleanText) {
                        ReplyText(text: cleanText, motionID: message.id, createdAt: message["created_at"].double)
                    }
                    .foregroundStyle(Palette.textPrimary)
                }
                .agentBubble()
                .overlay(alignment: .leading) {
                    if cleanText.hasPrefix("已记") {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.success.opacity(0.85))
                            .frame(width: 3).padding(.vertical, Space.sm).padding(.leading, 4)
                    }
                }
                .accessibilityIdentifier("agent-bubble-" + message.id)
            }
            if !bubble.images.isEmpty {
                InlineBubbleImagesGrid(images: bubble.images)
            }
        }
    }
}

private struct InlineBubbleImagesGrid: View {
    let images: [BubbleImageRef]
    private var columns: [GridItem] {
        let count = min(max(images.count, 1), 3)
        return Array(repeating: GridItem(.flexible(), spacing: Space.xs), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Space.xs) {
            ForEach(images) { ref in
                InlineBubbleImageTile(imageRef: ref, single: images.count == 1)
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
    }
}

private struct InlineBubbleImageTile: View {
    @Environment(AppModel.self) private var model
    let imageRef: BubbleImageRef
    let single: Bool
    @State private var localURL: URL?
    @State private var loading = false
    @State private var previewItem: SendMessagePreviewItem?

    var body: some View {
        Button {
            Task { await openPreview() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Palette.fill)
                if let localURL, let uiImage = UIImage(contentsOfFile: localURL.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else if imageRef.scheme == "https", let remote = URL(string: imageRef.url) {
                    AsyncImage(url: remote) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "photo")
                                .font(.system(size: 20))
                                .foregroundStyle(Palette.textTertiary)
                        default:
                            ProgressView().controlSize(.small)
                        }
                    }
                } else if loading {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(Palette.textSecondary)
                        Text(imageRef.name)
                            .font(TypeScale.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                            .padding(.horizontal, Space.xs)
                    }
                }
            }
            .frame(height: single ? 176 : 96)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(SoftPressStyle(scale: 0.98))
        .task {
            if imageRef.scheme == "file" || !imageRef.artifactID.isEmpty || !imageRef.downloadPath.isEmpty {
                await ensureDownloaded(openAfter: false)
            }
        }
        .sheet(item: $previewItem) { item in
            NavigationStack {
                FilePreview(url: item.url)
                    .navigationTitle(item.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("完成") { previewItem = nil } }
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
            }
        }
    }

    private func openPreview() async {
        Haptics.selection()
        if let localURL {
            previewItem = SendMessagePreviewItem(url: localURL)
            return
        }
        if imageRef.scheme == "https", imageRef.artifactID.isEmpty, imageRef.downloadPath.isEmpty, let url = URL(string: imageRef.url) {
            _ = await UIApplication.shared.open(url)
            return
        }
        await ensureDownloaded(openAfter: true)
    }

    private func ensureDownloaded(openAfter: Bool) async {
        guard !loading, let api = model.client else { return }
        let path = !imageRef.downloadPath.isEmpty ? imageRef.downloadPath : ("/personal/artifacts/" + imageRef.artifactID.pathEncoded)
        guard !imageRef.artifactID.isEmpty || !imageRef.downloadPath.isEmpty else { return }
        loading = true
        defer { loading = false }
        if let file = try? await api.downloadArtifact(
            path: path,
            cacheKey: imageRef.artifactID.isEmpty ? imageRef.id : imageRef.artifactID,
            name: imageRef.name.isEmpty ? "image.jpg" : imageRef.name,
            into: SecureVault.directory.appendingPathComponent("Previews")
        ) {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            localURL = file
            if openAfter { previewItem = SendMessagePreviewItem(url: file) }
        }
    }
}

// MARK: - 2. AttachmentCardBubble（文件/网页/图片独立卡片气泡）

struct AttachmentCardBubble: View {
    @Environment(AppModel.self) private var model
    let messageID: String
    let bubble: SendMessageBubble

    @State private var loading = false
    @State private var localFile: URL?
    @State private var filePreview: SendMessagePreviewItem?
    @State private var htmlPreview: SendMessagePreviewItem?
    @State private var errorNote = ""

    private var ext: String {
        let fromName = URL(fileURLWithPath: bubble.name).pathExtension.lowercased()
        if !fromName.isEmpty { return fromName }
        if let parsed = URL(string: bubble.url) { return parsed.pathExtension.lowercased() }
        return ""
    }

    private var isHTML: Bool {
        ext == "html" || ext == "htm" || bubble.mime.lowercased().contains("html")
    }

    private var isImage: Bool {
        bubble.mime.lowercased().hasPrefix("image/") || ["png", "jpg", "jpeg", "webp", "gif", "heic"].contains(ext)
    }

    private var isExternalLinkOnly: Bool {
        bubble.scheme == "https" && bubble.artifactID.isEmpty && bubble.downloadPath.isEmpty
    }

    private var iconSymbol: String {
        if isHTML { return "safari" }
        if isImage { return "photo.fill" }
        if ext == "pdf" || bubble.mime.contains("pdf") { return "doc.richtext.fill" }
        if ["xlsx", "xls", "csv"].contains(ext) { return "tablecells.fill" }
        if ["zip", "tar", "gz"].contains(ext) { return "doc.zipper" }
        if isExternalLinkOnly { return "link" }
        return "doc.fill"
    }

    private var iconColor: Color {
        if isHTML { return Palette.accentText }
        if isImage { return Palette.info }
        if ext == "pdf" { return Palette.coral }
        if ["xlsx", "xls", "csv"].contains(ext) { return Palette.success }
        return Palette.textPrimary
    }

    private var metaLine: String {
        var parts: [String] = []
        if !ext.isEmpty { parts.append(ext.uppercased()) }
        else if isExternalLinkOnly { parts.append("HTTPS") }
        if bubble.size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bubble.size), countStyle: .file))
        }
        if parts.isEmpty { parts.append(isHTML ? "互动页面" : "附件") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if isImage, let localFile, let uiImg = UIImage(contentsOfFile: localFile.path) {
                Button {
                    filePreview = SendMessagePreviewItem(url: localFile)
                } label: {
                    Image(uiImage: uiImg)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 280, maxHeight: 170)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .center, spacing: Space.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(iconColor.opacity(0.14))
                        .frame(width: 42, height: 42)
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: iconSymbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(iconColor)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(bubble.name)
                        .font(TypeScale.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(metaLine)
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Space.xs)

                if let localFile {
                    ShareLink(item: localFile) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(Palette.fill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("分享文件")
                } else if isExternalLinkOnly, let remoteURL = URL(string: bubble.url) {
                    ShareLink(item: remoteURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(Palette.fill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("分享链接")
                } else {
                    Button {
                        Task { await prepareAndOpen(shareOnly: true) }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(Palette.fill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(loading)
                    .accessibilityLabel("下载以供分享")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Task { await prepareAndOpen(shareOnly: false) }
            }

            if !bubble.caption.isEmpty {
                Text(bubble.caption)
                    .font(TypeScale.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.sm) {
                Button {
                    Task { await prepareAndOpen(shareOnly: false) }
                } label: {
                    Label(
                        isExternalLinkOnly ? "打开链接" : (isHTML ? "App 内预览页面" : "预览文件"),
                        systemImage: isExternalLinkOnly ? "arrow.up.right" : "eye"
                    )
                    .font(TypeScale.footnote.weight(.semibold))
                    .foregroundStyle(Palette.accentText)
                    .padding(.horizontal, Space.md)
                    .frame(minHeight: 32)
                    .background(Palette.accent.opacity(0.18), in: Capsule())
                }
                .buttonStyle(SoftPressStyle(scale: 0.97))
                .disabled(loading)
                .accessibilityIdentifier("attachment-open-" + messageID)

                if let localFile {
                    ShareLink(item: localFile) {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .font(TypeScale.footnote.weight(.medium))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, Space.md)
                            .frame(minHeight: 32)
                            .background(Palette.fill, in: Capsule())
                    }
                    .buttonStyle(SoftPressStyle(scale: 0.97))
                }
            }

            if !errorNote.isEmpty {
                InlineNotice(text: errorNote, tone: .danger)
            }
        }
        .padding(Space.md + 2)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 0.5)
        )
        .accessibilityIdentifier("attachment-bubble-" + messageID)
        .task {
            if isImage && !isExternalLinkOnly && localFile == nil {
                await downloadOnly()
            }
        }
        .sheet(item: $filePreview) { item in
            NavigationStack {
                FilePreview(url: item.url)
                    .navigationTitle(item.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("完成") { filePreview = nil } }
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
            }
        }
        .fullScreenCover(item: $htmlPreview) { item in
            NavigationStack {
                HTMLPreview(url: item.url, initialState: item.htmlState)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(item.url.deletingPathExtension().lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("完成") { htmlPreview = nil } }
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
            }
        }
    }

    private func downloadOnly() async {
        guard !loading, let api = model.client else { return }
        guard !bubble.downloadPath.isEmpty || !bubble.artifactID.isEmpty else { return }
        loading = true
        defer { loading = false }
        let path = !bubble.downloadPath.isEmpty ? bubble.downloadPath : ("/personal/artifacts/" + bubble.artifactID.pathEncoded)
        if let url = try? await api.downloadArtifact(
            path: path,
            cacheKey: bubble.artifactID.isEmpty ? messageID : bubble.artifactID,
            name: bubble.name,
            into: SecureVault.directory.appendingPathComponent("Previews")
        ) {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            localFile = url
        }
    }

    private func prepareAndOpen(shareOnly: Bool) async {
        guard !loading else { return }
        Haptics.selection()
        errorNote = ""

        if isExternalLinkOnly {
            if let remote = URL(string: bubble.url) {
                _ = await UIApplication.shared.open(remote)
            } else {
                errorNote = "外链地址无效，无法打开。"
            }
            return
        }

        if let existing = localFile, FileManager.default.fileExists(atPath: existing.path) {
            if !shareOnly { await presentFile(existing) }
            return
        }

        guard let api = model.client else {
            errorNote = "还没连上 Mac mini，连上后再下载预览。"
            return
        }
        guard !bubble.downloadPath.isEmpty || !bubble.artifactID.isEmpty else {
            errorNote = "附件缺少受鉴权下载路径，无法读取。"
            return
        }

        loading = true
        defer { loading = false }
        do {
            let path = !bubble.downloadPath.isEmpty ? bubble.downloadPath : ("/personal/artifacts/" + bubble.artifactID.pathEncoded)
            let downloaded = try await api.downloadArtifact(
                path: path,
                cacheKey: bubble.artifactID.isEmpty ? messageID : bubble.artifactID,
                name: bubble.name,
                into: SecureVault.directory.appendingPathComponent("Previews")
            )
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: downloaded.path)
            localFile = downloaded
            if !shareOnly {
                await presentFile(downloaded)
            }
        } catch {
            errorNote = "下载没成：" + error.localizedDescription
        }
    }

    private func presentFile(_ fileURL: URL) async {
        if isHTML {
            var state = "{}"
            if let api = model.client,
               let saved = try? await api.request("/personal/artifact-state/" + fileURL.lastPathComponent.pathEncoded),
               let encoded = try? JSONEncoder().encode(saved["state"]),
               let str = String(data: encoded, encoding: .utf8) {
                state = str
            }
            htmlPreview = SendMessagePreviewItem(url: fileURL, htmlState: state)
        } else {
            filePreview = SendMessagePreviewItem(url: fileURL)
        }
    }
}

// MARK: - 3. WidgetBubbleView（confirm / picker / checklist / form / staging_review 原位收敛）

struct WidgetBubbleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce

    let messageID: String
    let spec: JSON
    let stateKey: String

    @State private var loaded = false
    @State private var busy = false
    @State private var resolvedSummary: String?
    @State private var notice = ""
    // picker / checklist / form state
    @State private var selectedPickerValues: [String] = []
    @State private var checkedMap: [String: Bool] = [:]
    @State private var formValues: [String: String] = [:]

    private var kind: String {
        let raw = spec["kind"].string.isEmpty ? spec["type"].string : spec["kind"].string
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var title: String { spec["title"].string }
    private var subtitle: String {
        for key in ["summary", "message", "subtitle", "description"] {
            let v = spec[key].string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if kind == "staging_review" {
                stagingHeader
            }

            if !title.isEmpty {
                Text(title)
                    .font(TypeScale.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(TypeScale.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let resolved = resolvedSummary {
                resolvedBanner(resolved)
            } else {
                interactiveContent
            }

            if !notice.isEmpty {
                InlineNotice(text: notice, tone: .warning)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: 332, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(
                    kind == "staging_review" && resolvedSummary == nil
                        ? Palette.warning.opacity(0.55)
                        : Palette.separator,
                    lineWidth: kind == "staging_review" && resolvedSummary == nil ? 1.2 : 0.5
                )
        )
        .accessibilityIdentifier("widget-bubble-\(kind)-" + messageID)
        .task { await restoreState() }
    }

    @ViewBuilder
    private var stagingHeader: some View {
        HStack(spacing: Space.xs + 2) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .bold))
            Text("已填好 · 停在按钮前")
                .font(TypeScale.caption.weight(.semibold))
            Spacer(minLength: 4)
            Text(stagingActionLabel)
                .font(TypeScale.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .foregroundStyle(Palette.warning)
        .padding(.horizontal, Space.sm + 2)
        .padding(.vertical, 5)
        .background(Palette.warning.opacity(0.14), in: Capsule())
    }

    private var stagingActionLabel: String {
        switch spec["action_type"].string {
        case "email_send": return "邮件发送门禁"
        case "labor_submit": return "劳务/报销门禁"
        case "content_publish": return "内容发布门禁"
        default: return "人工终审"
        }
    }

    @ViewBuilder
    private func resolvedBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs + 2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.success)
                Text(text)
                    .font(TypeScale.footnote.weight(.semibold))
                    .foregroundStyle(Palette.success)
                    .lineLimit(2)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.success.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))

            if kind == "staging_review",
               let targetURL = stagingTargetURL {
                Button {
                    Haptics.selection()
                    Task { _ = await UIApplication.shared.open(targetURL) }
                } label: {
                    Label("再次打开页面核对", systemImage: "safari")
                        .font(TypeScale.caption.weight(.semibold))
                        .foregroundStyle(Palette.accentText)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    private var stagingTargetURL: URL? {
        let raw = spec["target_url"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http") else { return nil }
        return url
    }

    @ViewBuilder
    private var interactiveContent: some View {
        switch kind {
        case "staging_review":
            stagingControls
        case "confirm":
            confirmControls
        case "picker", "choices":
            pickerControls
        case "checklist":
            checklistControls
        case "form":
            formControls
        default:
            confirmControls
        }
    }

    // MARK: staging_review
    private var stagingControls: some View {
        let confirmLabel = spec["confirm_label"].string.isEmpty ? "打开页面我去点" : spec["confirm_label"].string
        let cancelLabel = spec["cancel_label"].string.isEmpty ? "打回重改" : spec["cancel_label"].string
        return VStack(alignment: .leading, spacing: Space.sm) {
            if let url = stagingTargetURL, let host = url.host {
                Label(host, systemImage: "globe")
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            HStack(spacing: Space.sm) {
                Button {
                    Task {
                        if let url = stagingTargetURL {
                            _ = await UIApplication.shared.open(url)
                        }
                        let reply = spec["confirm_reply"].string.isEmpty
                            ? "我已打开页面准备自己点提交：\(title)"
                            : spec["confirm_reply"].string
                        await commitResolution(replyText: reply, summary: "已交接给你亲手点 · \(confirmLabel)")
                    }
                } label: {
                    HStack(spacing: Space.xs) {
                        if busy { ProgressView().controlSize(.small).tint(Palette.onAccent) }
                        Image(systemName: stagingTargetURL != nil ? "arrow.up.right.square.fill" : "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(confirmLabel).font(TypeScale.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .buttonStyle(SoftPressStyle())
                .disabled(busy)
                .accessibilityIdentifier("widget-staging-confirm-" + messageID)

                Button {
                    Task {
                        let reply = spec["cancel_reply"].string.isEmpty
                            ? "先别发，打回重改：\(title)"
                            : spec["cancel_reply"].string
                        await commitResolution(replyText: reply, summary: "已打回重改")
                    }
                } label: {
                    Text(cancelLabel)
                        .font(TypeScale.subheadline.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, Space.md)
                        .frame(minHeight: 42)
                        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .buttonStyle(SoftPressStyle())
                .disabled(busy)
                .accessibilityIdentifier("widget-staging-cancel-" + messageID)
            }
        }
    }

    // MARK: confirm
    private var confirmControls: some View {
        let confirmLabel = spec["confirm_label"].string.isEmpty ? "确认" : spec["confirm_label"].string
        let cancelLabel = spec["cancel_label"].string.isEmpty ? "取消" : spec["cancel_label"].string
        return HStack(spacing: Space.sm) {
            Button {
                Task {
                    let reply = spec["confirm_reply"].string.isEmpty ? confirmLabel : spec["confirm_reply"].string
                    await commitResolution(replyText: reply, summary: "已确认 · \(confirmLabel)")
                }
            } label: {
                HStack(spacing: Space.xs) {
                    if busy { ProgressView().controlSize(.small).tint(Palette.onAccent) }
                    Text(confirmLabel).font(TypeScale.subheadline.weight(.semibold))
                }
                .foregroundStyle(Palette.onAccent)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
            .buttonStyle(SoftPressStyle())
            .disabled(busy)
            .accessibilityIdentifier("widget-confirm-yes-" + messageID)

            Button {
                Task {
                    let reply = spec["cancel_reply"].string.isEmpty ? cancelLabel : spec["cancel_reply"].string
                    await commitResolution(replyText: reply, summary: "已选 · \(cancelLabel)")
                }
            } label: {
                Text(cancelLabel)
                    .font(TypeScale.subheadline.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
            .buttonStyle(SoftPressStyle())
            .disabled(busy)
            .accessibilityIdentifier("widget-confirm-no-" + messageID)
        }
    }

    // MARK: picker
    private struct PickerOption: Identifiable {
        let id: String
        let label: String
        let value: String
        let detail: String
    }

    private var pickerOptions: [PickerOption] {
        spec["options"].array.enumerated().compactMap { idx, item in
            if case .string(let str) = item, !str.isEmpty {
                return PickerOption(id: "\(idx):\(str)", label: str, value: str, detail: "")
            }
            let label = item["label"].string.isEmpty ? item["title"].string : item["label"].string
            let value = item["value"].string.isEmpty ? label : item["value"].string
            guard !label.isEmpty else { return nil }
            return PickerOption(id: "\(idx):\(value)", label: label, value: value, detail: item["description"].string)
        }
    }

    private var pickerControls: some View {
        let isMulti = spec["multi"].bool
        return VStack(spacing: Space.xs + 2) {
            ForEach(pickerOptions) { option in
                let selected = selectedPickerValues.contains(option.value)
                Button {
                    Haptics.selection()
                    if isMulti {
                        if let i = selectedPickerValues.firstIndex(of: option.value) {
                            selectedPickerValues.remove(at: i)
                        } else {
                            selectedPickerValues.append(option.value)
                        }
                    } else {
                        Task {
                            await commitResolution(replyText: option.value, summary: "已选 · \(option.label)")
                        }
                    }
                } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(selected ? Palette.accentText : Palette.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(TypeScale.subheadline.weight(.medium))
                                .foregroundStyle(Palette.textPrimary)
                            if !option.detail.isEmpty {
                                Text(option.detail)
                                    .font(TypeScale.caption)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm + 2)
                    .frame(minHeight: 42)
                    .background(selected ? Palette.accent.opacity(0.28) : Palette.fill, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .buttonStyle(SoftPressStyle(scale: 0.99))
                .disabled(busy)
            }
            if isMulti {
                Button {
                    let chosenLabels = pickerOptions.filter { selectedPickerValues.contains($0.value) }.map(\.label)
                    let joined = chosenLabels.joined(separator: "、")
                    Task {
                        await commitResolution(replyText: selectedPickerValues.joined(separator: "、"), summary: "已选 · \(joined)")
                    }
                } label: {
                    Text("确认选择")
                        .font(TypeScale.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(Palette.accent.opacity(selectedPickerValues.isEmpty ? 0.4 : 1), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .buttonStyle(SoftPressStyle())
                .disabled(selectedPickerValues.isEmpty || busy)
            }
        }
    }

    // MARK: checklist
    private struct CheckItem: Identifiable {
        let id: String
        let label: String
        let defaultChecked: Bool
    }

    private var checklistItems: [CheckItem] {
        spec["items"].array.enumerated().compactMap { idx, raw in
            if case .string(let s) = raw, !s.isEmpty {
                return CheckItem(id: "item-\(idx)", label: s, defaultChecked: false)
            }
            let label = raw["label"].string.isEmpty ? raw["text"].string : raw["label"].string
            guard !label.isEmpty else { return nil }
            let id = raw["id"].string.isEmpty ? "item-\(idx)" : raw["id"].string
            return CheckItem(id: id, label: label, defaultChecked: raw["checked"].bool)
        }
    }

    private func isItemChecked(_ item: CheckItem) -> Bool {
        checkedMap[item.id] ?? item.defaultChecked
    }

    private var checklistControls: some View {
        let submitLabel: String = {
            if !spec["confirm_label"].string.isEmpty { return spec["confirm_label"].string }
            if !spec["submit"].string.isEmpty { return spec["submit"].string }
            return "确认清单"
        }()
        return VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(checklistItems) { item in
                let on = isItemChecked(item)
                Button {
                    Haptics.selection()
                    checkedMap[item.id] = !on
                } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .font(.system(size: 18))
                            .foregroundStyle(on ? Palette.accentText : Palette.textTertiary)
                        Text(item.label)
                            .font(TypeScale.subheadline)
                            .foregroundStyle(on ? Palette.textSecondary : Palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            Button {
                let chosen = checklistItems.filter(isItemChecked)
                let lines = chosen.map { "✓ " + $0.label }
                let bodyText = lines.isEmpty ? "\(submitLabel)：未勾选项目" : ([submitLabel] + lines).joined(separator: "\n")
                Task {
                    await commitResolution(replyText: bodyText, summary: "已确认清单（勾选 \(chosen.count)/\(checklistItems.count) 项）")
                }
            } label: {
                HStack(spacing: Space.xs) {
                    if busy { ProgressView().controlSize(.small).tint(Palette.onAccent) }
                    Text(submitLabel).font(TypeScale.subheadline.weight(.semibold))
                }
                .foregroundStyle(Palette.onAccent)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
            .buttonStyle(SoftPressStyle())
            .disabled(busy)
            .padding(.top, Space.xs)
        }
    }

    // MARK: form
    private struct FormFieldSpec: Identifiable {
        let id: String
        let label: String
        let placeholder: String
        let required: Bool
        let defaultValue: String
    }

    private var formFields: [FormFieldSpec] {
        spec["fields"].array.enumerated().compactMap { idx, f in
            let name = f["name"].string.isEmpty ? f["id"].string : f["name"].string
            let label = f["label"].string.isEmpty ? name : f["label"].string
            guard !label.isEmpty else { return nil }
            let key = name.isEmpty ? "field_\(idx)" : name
            let def = f["default"].string.isEmpty ? f["value"].string : f["default"].string
            return FormFieldSpec(
                id: key,
                label: label,
                placeholder: f["placeholder"].string,
                required: f["required"].bool,
                defaultValue: def
            )
        }
    }

    private func fieldText(_ field: FormFieldSpec) -> String {
        formValues[field.id] ?? field.defaultValue
    }

    private var formReady: Bool {
        formFields.allSatisfy { !$0.required || !fieldText($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var formControls: some View {
        let submitLabel = spec["confirm_label"].string.isEmpty
            ? (spec["submit"].string.isEmpty ? "提交" : spec["submit"].string)
            : spec["confirm_label"].string
        return VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(formFields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 3) {
                        Text(field.label)
                            .font(TypeScale.caption.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                        if field.required {
                            Text("*").font(TypeScale.caption).foregroundStyle(Palette.coral)
                        }
                    }
                    TextField(
                        field.placeholder.isEmpty ? "填写\(field.label)" : field.placeholder,
                        text: Binding(
                            get: { fieldText(field) },
                            set: { formValues[field.id] = $0 }
                        )
                    )
                    .font(TypeScale.subheadline)
                    .padding(.horizontal, Space.md)
                    .frame(minHeight: 40)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
            }
            Button {
                let lines = formFields.compactMap { field -> String? in
                    let v = fieldText(field).trimmingCharacters(in: .whitespacesAndNewlines)
                    return v.isEmpty ? nil : "\(field.label)：\(v)"
                }
                let head = title.isEmpty ? submitLabel : title
                let payload = ([head] + lines).joined(separator: "\n")
                Task {
                    await commitResolution(replyText: payload, summary: "已提交 · \(submitLabel)")
                }
            } label: {
                HStack(spacing: Space.xs) {
                    if busy { ProgressView().controlSize(.small).tint(Palette.onAccent) }
                    Text(submitLabel).font(TypeScale.subheadline.weight(.semibold))
                }
                .foregroundStyle(Palette.onAccent)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(Palette.accent.opacity(formReady ? 1 : 0.4), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
            .buttonStyle(SoftPressStyle())
            .disabled(!formReady || busy)
        }
    }

    // MARK: Persistence & Resolution
    private func restoreState() async {
        guard !loaded else { return }
        loaded = true
        if let cached = model.resolvedWidgetStates[stateKey], cached["resolved"].bool {
            resolvedSummary = cached["summary"].string.isEmpty ? "已处理" : cached["summary"].string
            return
        }
        let remote = await model.load("/personal/artifact-state/" + stateKey.pathEncoded)
        let state = remote?["state"] ?? .null
        if state["resolved"].bool {
            let summary = state["summary"].string.isEmpty ? "已处理" : state["summary"].string
            model.resolvedWidgetStates[stateKey] = state
            resolvedSummary = summary
        }
    }

    private func commitResolution(replyText: String, summary: String) async {
        guard !busy else { return }
        busy = true
        notice = ""
        Haptics.selection()
        let ok = await model.send(textOverride: replyText)
        busy = false
        guard ok else {
            notice = "没发出去，请检查连接后再点一次。"
            return
        }
        let persisted: JSON = .object([
            "resolved": .bool(true),
            "summary": .string(summary)
        ])
        model.resolvedWidgetStates[stateKey] = persisted
        withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) {
            resolvedSummary = summary
        }
        Haptics.success()
        if let api = model.client {
            _ = try? await api.request("/personal/artifact-state/" + stateKey.pathEncoded, body: .object(["state": persisted]))
        }
    }
}

// MARK: - 4. SecretEntryBubbleView（安全遮罩输入框 · 提交后即刻销毁明文）

struct SecretEntryBubbleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce

    let messageID: String
    let bubble: SendMessageBubble

    @State private var secretInput = ""
    @State private var submitting = false
    @State private var submitted = false
    @State private var loaded = false
    @State private var errorNote = ""

    private var stateKey: String { "secret:" + messageID }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.xs + 2) {
                Image(systemName: submitted ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(submitted ? Palette.success : Palette.accentText)
                Text(submitted ? "密钥已安全配置" : "安全密钥请求")
                    .font(TypeScale.caption.weight(.semibold))
                    .foregroundStyle(submitted ? Palette.success : Palette.textSecondary)
                Spacer(minLength: 4)
                Text(bubble.secretName.isEmpty ? "SECRET" : bubble.secretName)
                    .font(TypeScale.code)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(Palette.fill, in: Capsule())
            }

            if !bubble.reason.isEmpty {
                Text(bubble.reason)
                    .font(TypeScale.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !bubble.targetEnv.isEmpty {
                Text("用途范围：\(bubble.targetEnv)")
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.textTertiary)
            }

            if submitted {
                HStack(spacing: Space.xs + 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.success)
                    Text("已加密送达安全保险箱 · 输入明文已销毁")
                        .font(TypeScale.footnote.weight(.semibold))
                        .foregroundStyle(Palette.success)
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.success.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textTertiary)
                        SecureField(
                            bubble.placeholder.isEmpty ? "在此安全输入 \(bubble.secretName)（全程遮罩）" : bubble.placeholder,
                            text: $secretInput
                        )
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(TypeScale.subheadline)
                    }
                    .padding(.horizontal, Space.md)
                    .frame(minHeight: 42)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .accessibilityIdentifier("secret-input-" + messageID)

                    Text("通过 TLS 直投本机/服务端加密保险箱，绝不写入聊天记录或日志。")
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.textTertiary)

                    Button {
                        Task { await submitNow() }
                    } label: {
                        HStack(spacing: Space.xs) {
                            if submitting { ProgressView().controlSize(.small).tint(Palette.onAccent) }
                            Image(systemName: "lock.fill").font(.system(size: 13, weight: .semibold))
                            Text(submitting ? "加密传输中…" : "安全提交并销毁明文")
                                .font(TypeScale.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Palette.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(
                            Palette.accent.opacity(secretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1),
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        )
                    }
                    .buttonStyle(SoftPressStyle())
                    .disabled(submitting || secretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("secret-submit-" + messageID)
                }
            }

            if !errorNote.isEmpty {
                InlineNotice(text: errorNote, tone: .danger)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: 332, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 0.5)
        )
        .accessibilityIdentifier("secret-bubble-" + messageID)
        .onDisappear {
            // 离开视图即清空未提交明文缓冲
            secretInput = ""
        }
        .task { await restoreSubmittedState() }
    }

    private func restoreSubmittedState() async {
        guard !loaded else { return }
        loaded = true
        if model.resolvedWidgetStates[stateKey]?["submitted"].bool == true {
            submitted = true
            return
        }
        let res = await model.load("/personal/artifact-state/" + stateKey.pathEncoded)
        if res?["state"]["submitted"].bool == true {
            model.resolvedWidgetStates[stateKey] = res?["state"] ?? .object(["submitted": .bool(true)])
            submitted = true
        }
    }

    private func submitNow() async {
        guard !submitting else { return }
        let captured = secretInput
        // 立刻销毁输入框明文状态，防止驻留
        secretInput = ""
        errorNote = ""
        submitting = true
        let result = await model.submitSecretEntry(
            messageID: messageID,
            secretName: bubble.secretName,
            targetEnv: bubble.targetEnv,
            secretValue: captured
        )
        submitting = false
        if result.ok {
            withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) {
                submitted = true
            }
        } else {
            errorNote = result.note
        }
    }
}

// MARK: - 5. Live 工具活动胶囊条 + 边干边报轻播报开关

struct LiveToolChipsBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var chips: [LiveToolChip] { model.activeLiveToolChips }

    var body: some View {
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs + 2) {
                    ForEach(chips) { chip in
                        LiveToolChipPill(chip: chip)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, 4)
            }
            .transition(.opacity)
            .animation(ComMotion.reduced(reduce, ComMotion.settle), value: chips)
            .accessibilityIdentifier("chat-live-tool-chips")
        }
    }
}

private struct LiveToolChipPill: View {
    let chip: LiveToolChip
    @State private var pulsing = false

    private var isRunning: Bool { chip.status == "running" }
    private var isFailed: Bool { chip.status == "failed" }

    var body: some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.85)
            } else if isFailed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.warning)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.success)
            }

            Text(chip.title)
                .font(TypeScale.caption.weight(.medium))
                .foregroundStyle(isRunning ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)

            if !isRunning, let ms = chip.durationMs, ms > 0 {
                Text(ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000.0) : "\(ms)ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, Space.sm + 2)
        .padding(.vertical, 5)
        .background(
            isRunning ? Palette.accent.opacity(pulsing ? 0.24 : 0.12) : Palette.surface,
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(
                isRunning ? Palette.accent.opacity(0.45) : Palette.separator,
                lineWidth: 0.6
            )
        )
        .onAppear {
            if isRunning {
                withAnimation(ComMotion.breath) { pulsing = true }
            }
        }
        .onChange(of: chip.status) { _, newValue in
            if newValue != "running" { pulsing = false }
        }
    }
}

struct VoiceNarrationTogglePill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Haptics.selection()
            model.voiceNarrationEnabled.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.voiceNarrationEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 11, weight: .semibold))
                Text("边干边报")
                    .font(TypeScale.caption.weight(.semibold))
            }
            .foregroundStyle(model.voiceNarrationEnabled ? Palette.onAccent : Palette.textSecondary)
            .padding(.horizontal, Space.sm + 2)
            .frame(height: 28)
            .background(
                model.voiceNarrationEnabled ? Palette.accent : Palette.fill,
                in: Capsule()
            )
        }
        .buttonStyle(SoftPressStyle(scale: 0.95))
        .accessibilityLabel(model.voiceNarrationEnabled ? "关闭语音边干边报" : "开启语音边干边报")
        .accessibilityIdentifier("chat-voice-narration-toggle")
    }
}

// MARK: - 6. 输入框上方双胶囊（上下文吸附胶囊 + 剪贴板新链接一键投递胶囊）

struct ComposerDualCapsulesBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs + 2) {
            if let item = model.attachedContext {
                AttachedContextCapsule(item: item) {
                    Haptics.selection()
                    withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) {
                        model.attachedContext = nil
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let candidate = model.clipboardDropCandidate, !candidate.isEmpty {
                ClipboardDropCapsule(
                    urlString: candidate,
                    onDrop: {
                        model.submitDrop(url: candidate)
                    },
                    onDismiss: {
                        Haptics.selection()
                        withAnimation(ComMotion.reduced(reduce, ComMotion.settle)) {
                            model.dismissClipboardDropCandidate()
                        }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(ComMotion.reduced(reduce, ComMotion.settle), value: model.attachedContext)
        .animation(ComMotion.reduced(reduce, ComMotion.settle), value: model.clipboardDropCandidate)
    }
}

private struct AttachedContextCapsule: View {
    let item: AttachedContextItem
    let onClear: () -> Void

    private var kindMeta: (label: String, symbol: String) {
        switch item.kind {
        case "next": return ("下一步", "shoeprints.fill")
        case "today": return ("今天", "calendar")
        case "sohu": return ("搜狐", "play.rectangle.fill")
        case "drop": return ("投递", "tray.and.arrow.down.fill")
        default: return ("关联", "link")
        }
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            Label(kindMeta.label, systemImage: kindMeta.symbol)
                .font(TypeScale.caption.weight(.semibold))
                .foregroundStyle(Palette.accentText)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 3)
                .background(Palette.accent.opacity(0.2), in: Capsule())

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(TypeScale.footnote.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除关联上下文")
            .accessibilityIdentifier("chat-attached-context-clear")
        }
        .padding(.horizontal, Space.sm + 2)
        .padding(.vertical, Space.xs + 2)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.45), lineWidth: 0.8)
        )
        .accessibilityIdentifier("chat-attached-context-capsule")
    }
}

private struct ClipboardDropCapsule: View {
    let urlString: String
    let onDrop: () -> Void
    let onDismiss: () -> Void

    private var hostPreview: String {
        guard let url = URL(string: urlString), let host = url.host else {
            return String(urlString.prefix(36))
        }
        if host.contains("capcut.cn") { return "剪映分享 · " + host }
        if host.contains("douyin.com") { return "抖音链接 · " + host }
        if host.contains("xiaohongshu.com") || host.contains("xhslink.com") { return "小红书 · " + host }
        if host.contains("sohu.com") { return "搜狐视频 · " + host }
        if host.contains("github.com") { return "GitHub · " + host }
        return host
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.accentText)

            VStack(alignment: .leading, spacing: 1) {
                Text("检测到复制链接")
                    .font(TypeScale.caption.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(hostPreview)
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onDrop) {
                Text("丢给 Com 处理")
                    .font(TypeScale.caption.weight(.semibold))
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, Space.sm + 2)
                    .frame(height: 28)
                    .background(Palette.accent, in: Capsule())
            }
            .buttonStyle(SoftPressStyle(scale: 0.96))
            .accessibilityIdentifier("chat-clipboard-drop-submit")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("忽略此剪贴板链接")
            .accessibilityIdentifier("chat-clipboard-drop-dismiss")
        }
        .padding(.horizontal, Space.sm + 2)
        .padding(.vertical, Space.xs + 2)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 0.6)
        )
        .accessibilityIdentifier("chat-clipboard-drop-capsule")
    }
}
