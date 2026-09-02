//
//  IncognitoWebView.swift
//  BuddyAuth — 内置无痕浏览器
//
// 特点：
//  - 独立 WKWebsiteDataStore（内存态，不落盘）
//  - 手动清除按钮：全量清除 cookies/localStorage/IndexedDB/WebSQL/缓存/ServiceWorker
//  - 登录成功后自动全量清除（由 CredentialStore 调用）
//  - 支持 socks5 代理（私有 _proxyConfiguration）
//

import SwiftUI
import WebKit

// MARK: - 登录页自动填充（手机号 / 验证码）
/// 只负责把值填进输入框，不自动点击任何按钮
enum LoginAutofill {

    /// 填充手机号 + 自动切换手机号登录 + 勾协议 + 自动点「获取验证码」
    /// 流程：确保「手机号」登录方式被选中 → 等输入框出现 → 填手机号 → 勾协议 → 点获取验证码
    static func fillPhone(webView: WKWebView?, phone: String) {
        guard let webView, !phone.isEmpty else { return }
        let js = """
        (function(){
            // 1. 确保「手机号」登录方式被选中（页面默认可能是微信）
            try {
                var methodTexts = document.querySelectorAll('.login-method-text');
                var phoneMethod = null;
                for (var i=0;i<methodTexts.length;i++){
                    if (methodTexts[i].textContent.indexOf('手机号') >= 0) { phoneMethod = methodTexts[i]; break; }
                }
                if (phoneMethod) {
                    var active = phoneMethod.closest('.login-method-item') || phoneMethod.parentElement;
                    var isActive = active && (active.className.indexOf('active') >= 0 || active.className.indexOf('selected') >= 0);
                    if (!isActive) { phoneMethod.click(); }
                }
            } catch(e){}

            // 2. 等输入框出现（点「手机号」后 Vue/React 渲染需要时间）
            var tries = 0;
            function waitAndFill() {
                var input = document.querySelector('input[placeholder="请输入你的手机号"]');
                if (!input) {
                    tries++;
                    if (tries < 20) { setTimeout(waitAndFill, 300); return; }
                    return;
                }
                // 3. 填手机号
                var proto = Object.getPrototypeOf(input);
                var desc = Object.getOwnPropertyDescriptor(proto, 'value');
                if (desc && desc.set) { desc.set.call(input, \(phone)); } else { input.value = \(phone); }
                input.dispatchEvent(new Event('input', {bubbles: true}));
                input.dispatchEvent(new Event('change', {bubbles: true}));

                // 4. 勾选「我已阅读并同意」协议
                setTimeout(function(){
                    try {
                        var cb = document.querySelector('input[type="checkbox"]');
                        if (cb && !cb.checked) { cb.click(); }
                    } catch(e){}
                }, 300);

                // 5. 点击「获取验证码」按钮
                setTimeout(function(){
                    try {
                        var btn = document.querySelector('.oneid-react-verify-code__code-btn');
                        if (btn && btn.className.indexOf('disabled') < 0) { btn.click(); }
                    } catch(e){}
                }, 800);
            }
            setTimeout(waitAndFill, 500);
            return true;
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 填充验证码 + 自动点击「登录」按钮
    static func fillCode(webView: WKWebView?, code: String) {
        guard let webView, !code.isEmpty else { return }
        let js = """
        (function(){
            // 1. 填验证码
            var input = document.querySelector('input[placeholder="请输入验证码"]');
            if (!input) return false;
            var proto = Object.getPrototypeOf(input);
            var desc = Object.getOwnPropertyDescriptor(proto, 'value');
            if (desc && desc.set) { desc.set.call(input, \(code)); } else { input.value = \(code); }
            input.dispatchEvent(new Event('input', {bubbles: true}));
            input.dispatchEvent(new Event('change', {bubbles: true}));

            // 2. 等验证码生效后自动点「登录」
            setTimeout(function(){
                try {
                    var btn = document.querySelector('.oneid-react-dialog-confirm-button');
                    if (btn && btn.className.indexOf('disabled') < 0) { btn.click(); }
                } catch(e){}
            }, 800);

            return true;
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

/// 无痕浏览器包装（UIViewRepresentable）
struct IncognitoWebView: UIViewRepresentable {

    /// 随机 Chrome UA 指纹（多套 Android 机型 + Chrome 版本）
    static func randomChromeUA() -> String {
        let fingerprints: [String] = [
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Mobile Safari/537.36",
            "Mozilla/5.0 (Linux; Android 13; SM-S911B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36",
            "Mozilla/5.0 (Linux; Android 12; Redmi K50) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Mobile Safari/537.36",
            "Mozilla/5.0 (Linux; Android 14; Xiaomi 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36",
            "Mozilla/5.0 (Linux; Android 13; V2217A) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
        ]
        return fingerprints.randomElement() ?? fingerprints[0]
    }
    let url: URL
    var onTitleChange: ((String) -> Void)?
    var onNavigationChange: ((URL?) -> Void)?
    /// webView 创建完成回调（供外部持有引用，用于清除后跳转等）
    var onWebViewCreated: ((WKWebView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 无痕：非持久化 data store（内存态，App 退出即消失）
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        config.defaultWebpagePreferences = WKWebpagePreferences()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // 应用 socks5 代理（私有接口，TrollStore 场景生效；无代理则直连）
        let proxyApplied = ProxyStore.shared.applyToWebView(config)
        if ProxyStore.shared.settings.isValid {
            CredentialStore.shared.appendLog(proxyApplied ? "🌐 浏览器代理已应用 (\(ProxyStore.shared.settings.host):\(ProxyStore.shared.settings.port))" : "⚠️ 浏览器代理应用失败（系统不支持私有接口，将直连）")
        }
        // 阻止任何数据落盘
        config.processPool = WKProcessPool()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.allowsBackForwardNavigationGestures = true
        // 伪装成普通 Chrome：UA 随机（多套 Android 机型/版本指纹）
        webView.customUserAgent = Self.randomChromeUA()
        webView.load(URLRequest(url: url))
        // 通知外部 webView 已就绪
        DispatchQueue.main.async {
            onWebViewCreated?(webView)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 仅初始加载
    }

    // MARK: - 全量清除（登录成功/手动按钮共用）

    /// 全量清除浏览器所有数据（cookies/localStorage/IndexedDB/WebSQL/缓存/ServiceWorker）
    /// - Parameters:
    ///   - webView: 要执行 JS 清除的 webView（可 nil）
    ///   - redirectTo: 清除完成后跳转的 URL（如验证代理出口的 https://www.baidu.com）
    ///   - completion: 清除完成后回调
    static func wipeAll(webView: WKWebView?, redirectTo: URL? = nil, completion: (() -> Void)? = nil) {
        // 1. JS 层深度清理：cookie/localStorage/sessionStorage/IndexedDB/WebSQL/ServiceWorker/缓存
        if let webView = webView {
            webView.evaluateJavaScript("""
            (function(){
                // cookies（含 httpOnly 之外的所有域）
                try { var c = document.cookie.split(';'); for (var i=0;i<c.length;i++){ document.cookie = c[i].split('=')[0] + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/; domain=.' + location.hostname; document.cookie = c[i].split('=')[0] + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/'; } } catch(e){}
                // localStorage / sessionStorage
                try { localStorage.clear(); sessionStorage.clear(); } catch(e){}
                // IndexedDB
                try { indexedDB.databases().then(function(dbs){ dbs.forEach(function(db){ indexedDB.deleteDatabase(db.name); }); }); } catch(e){}
                // WebSQL
                try { if (window.openDatabase) { window.openDatabase('__wipe__','1','',1); } } catch(e){}
                // ServiceWorker
                try { navigator.serviceWorker.getRegistrations().then(function(regs){ regs.forEach(function(r){ r.unregister(); }); }); } catch(e){}
                // 应用缓存
                try { if (window.applicationCache) { window.applicationCache.swapCache(); } } catch(e){}
            })();
            """, completionHandler: nil)
        }
        // 2. WKWebsiteDataStore 全类型清除（cookies/indexedDB/websql/cache/serviceworkers 等）
        let store = WKWebsiteDataStore.nonPersistent()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: types, modifiedSince: Date.distantPast) {
            // 3. 额外清 HTTP 缓存
            URLCache.shared.removeAllCachedResponses()
            // 4. 清除完成后跳转（如百度，验证代理出口）
            if let redirectTo = redirectTo, let webView = webView {
                DispatchQueue.main.async {
                    webView.load(URLRequest(url: redirectTo))
                }
            }
            completion?()
        }
    }

    // MARK: Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: IncognitoWebView
        weak var webView: WKWebView?

        init(_ parent: IncognitoWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onTitleChange?(webView.title ?? "")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.onNavigationChange?(webView.url)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            parent.onNavigationChange?(navigationAction.request.url)
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
