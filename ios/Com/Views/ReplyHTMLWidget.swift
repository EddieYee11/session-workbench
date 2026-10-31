import SwiftUI
import WebKit
import ComCore

/// 回复里内嵌的小工具（计算器、对比滑块这类）。HTML 是模型写的，按不可信内容处理：
/// 不能联网、不能跳转、不存数据；只有他亲手点了才能替他发消息。
struct ReplyHTMLWidget: View {
    let id: String
    let title: String
    let html: String
    let send: (String) -> Void
    /// 高度记在格子外面：滑走再滑回来不用从 120pt 重新长一遍，列表不跳。
    @MainActor private static var heights: [String: CGFloat] = [:]
    @State private var height: CGFloat

    init(id: String, title: String, html: String, send: @escaping (String) -> Void) {
        self.id = id; self.title = title; self.html = html; self.send = send
        _height = State(initialValue: Self.heights[id] ?? 120)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if !title.isEmpty { Text(title).font(TypeScale.rowTitle).foregroundStyle(Palette.textPrimary) }
            SandboxedHTML(html: html, send: send) { next in
                let clamped = min(560, max(44, next))
                guard abs(clamped - height) > 1 else { return }
                Self.heights[id] = clamped
                height = clamped
            }
            .frame(height: height)
            .accessibilityIdentifier("widget-html-" + id)
        }
        .padding(Space.md)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.md, style: .continuous))
    }
}

private struct SandboxedHTML: UIViewRepresentable {
    let html: String
    let send: (String) -> Void
    let resized: (CGFloat) -> Void

    private static let policy = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:"
    private static let bridge = """
    window.Com={send:function(t){if(!navigator.userActivation||navigator.userActivation.isActive){webkit.messageHandlers.comWidget.postMessage({send:String(t).slice(0,2000)})}}};
    (function(){function r(){webkit.messageHandlers.comWidget.postMessage({height:Math.ceil(document.body.getBoundingClientRect().height)})}
    new ResizeObserver(r).observe(document.body);window.addEventListener('load',r);r()})();
    """

    func makeCoordinator() -> Coordinator { Coordinator(send: send, resized: resized) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(WeakHandler(context.coordinator), name: "comWidget")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false  // 外层聊天列表负责滚动
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(Self.policy)">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>:root{color-scheme:light dark}body{margin:0;font:16px -apple-system,sans-serif;-webkit-text-size-adjust:100%}</style>
        </head><body>\(html)</body></html>
        """
        view.loadHTMLString(page, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.send = send
        context.coordinator.resized = resized
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "comWidget")
    }

    /// WKUserContentController 强持有 handler：隔一层，格子回收时才放得掉。
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?
        init(_ target: Coordinator) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var send: (String) -> Void
        var resized: (CGFloat) -> Void
        init(send: @escaping (String) -> Void, resized: @escaping (CGFloat) -> Void) {
            self.send = send; self.resized = resized
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let text = body["send"] as? String, !text.isEmpty { send(text) }
            if let value = body["height"] as? Double { resized(CGFloat(value)) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }
    }
}
