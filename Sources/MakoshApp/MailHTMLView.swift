import SwiftUI
import WebKit
import AppKit

struct MailHTMLView: NSViewRepresentable {
    let html: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration=WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript=false
        let view=WKWebView(frame:.zero,configuration:configuration)
        view.navigationDelegate=context.coordinator
        view.setValue(false,forKey:"drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView,context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML=html
        // The restrictive first policy cannot be loosened by a later message policy.
        let document="""
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; script-src 'none'"><style>body{font:15px -apple-system;padding:22px;line-height:1.55;overflow-wrap:anywhere;color:#20202a;background:#ada388}img{max-width:100%}pre{white-space:pre-wrap}a{color:#7855bd}</style></head><body>\(html)</body></html>
        """
        view.loadHTMLString(document,baseURL:nil)
    }
    @MainActor final class Coordinator: NSObject,WKNavigationDelegate {
        var lastHTML=""
        func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url=navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .linkActivated {
                guard ["https","http","mailto"].contains(url.scheme?.lowercased() ?? "") else { return .cancel }
                let alert=NSAlert();alert.messageText="Открыть ссылку из письма?";alert.informativeText=url.absoluteString
                alert.addButton(withTitle:"Открыть");alert.addButton(withTitle:"Отмена")
                guard let window=webView.window else { return .cancel }
                alert.beginSheetModal(for:window) { response in if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) } }
                return .cancel
            } else { return url.scheme=="about" || url.scheme=="data" ? .allow : .cancel }
        }
    }
}
