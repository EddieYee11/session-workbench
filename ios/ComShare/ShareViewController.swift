import UIKit
import UniformTypeIdentifiers

private enum SharedValue: Sendable { case text(String), url(URL) }

@MainActor final class ShareViewController: UIViewController {
    private let status = UILabel()
    private var working = false
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        status.numberOfLines = 0; status.textAlignment = .center; status.font = .preferredFont(forTextStyle: .body)
        status.text = "正在准备分享给 Com…"
        let close = UIButton(type: .system); close.setTitle("完成", for: .normal)
        close.addTarget(self, action: #selector(finish), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [status, close]); stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack); NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: view.centerYAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30)])
        Task { await collect() }
    }
    private func collect() async {
        guard !working else { return }; working = true
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var draft = SharedDraft(id: UUID().uuidString.lowercased(), text: "", attachments: [], createdAt: Date())
        do {
            guard let root = ShareInbox.directory else { throw CocoaError(.fileNoSuchFile) }
            let folder = root.appendingPathComponent(draft.id); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for provider in providers.prefix(8) {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    let item = try await load(provider, type: UTType.fileURL.identifier)
                    if case .url(let url) = item { try copy(url, folder: folder, draft: &draft) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
                    let url = try await fileRepresentation(provider, type: type, folder: folder)
                    let actual = UTType(type)
                    draft.attachments.append(SharedAttachment(id: UUID().uuidString.lowercased(), name: "分享照片." + (actual?.preferredFilenameExtension ?? "jpg"), mime: actual?.preferredMIMEType ?? "image/jpeg", filename: url.lastPathComponent))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if case .url(let url) = try await load(provider, type: UTType.url.identifier) { draft.text += (draft.text.isEmpty ? "" : "\n") + url.absoluteString }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    if case .text(let text) = try await load(provider, type: UTType.text.identifier) { draft.text += (draft.text.isEmpty ? "" : "\n") + String(text.prefix(20000)) }
                }
            }
            guard !draft.text.isEmpty || !draft.attachments.isEmpty else { throw CocoaError(.fileReadUnknown) }
            try ShareInbox.save(draft)
            status.text = "已保存到 Com 分享收件箱。\n打开 Com 后检查内容，再确认发送。"
        } catch { status.text = "分享未保存：" + error.localizedDescription }
    }
    private func load(_ provider: NSItemProvider, type: String) async throws -> SharedValue {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in if let error { continuation.resume(throwing: error) } else if let url = item as? URL { continuation.resume(returning: .url(url)) } else if let text = item as? String { continuation.resume(returning: .text(text)) } else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) } }
        }
    }
    private func fileRepresentation(_ provider: NSItemProvider, type: String, folder: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    if let error { throw error }; guard let url else { throw CocoaError(.fileReadUnknown) }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 20 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    let destination = folder.appendingPathComponent(UUID().uuidString + "." + (UTType(type)?.preferredFilenameExtension ?? url.pathExtension))
                    try FileManager.default.copyItem(at: url, to: destination)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                    continuation.resume(returning: destination)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func copy(_ url: URL, folder: URL, draft: inout SharedDraft) throws {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let filename = UUID().uuidString + "." + url.pathExtension
        let destination = folder.appendingPathComponent(filename); try FileManager.default.copyItem(at: url, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        draft.attachments.append(SharedAttachment(id: UUID().uuidString.lowercased(), name: url.lastPathComponent, mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", filename: filename))
    }
    @objc private func finish() { extensionContext?.completeRequest(returningItems: nil) }
}
