//
//  ProxySettings.swift
//  BuddyAuth — socks5 代理配置
//
//  支持：
//  - NSURLSession 层：connectionProxyDictionary 官方支持 SOCKS5（含认证）
//  - WKWebView 层：私有 _proxyConfiguration 接口（TrollStore/越狱场景可用；
//    非越狱公开环境不生效时浏览器保持直连，不影响 API 层）
//  - 不设置代理 → 全部直连
//

import Foundation
import WebKit

struct ProxySettings: Codable, Equatable {
    var enabled: Bool = false
    var host: String = ""
    var port: Int = 1080
    var username: String = ""
    var password: String = ""

    var isValid: Bool {
        enabled && !host.trimmingCharacters(in: .whitespaces).isEmpty && port > 0 && port < 65536
    }

    /// 配置指纹（代理变化时重建 session）
    var fingerprint: String {
        "\(enabled)|\(host)|\(port)|\(username)|\(password.count)"
    }
}

/// 全局代理配置（线程安全，供 API 层与浏览器层共用）
final class ProxyStore: ObservableObject {

    static let shared = ProxyStore()

    @Published var settings: ProxySettings {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let key = "proxy_settings_v1"
    private var lock = NSLock()

    private init() {
        if let d = defaults.data(forKey: key),
           let s = try? JSONDecoder().decode(ProxySettings.self, from: d) {
            settings = s
        } else {
            settings = ProxySettings()
        }
    }

    private func save() {
        lock.lock()
        defer { lock.unlock() }
        if let d = try? JSONEncoder().encode(settings) {
            defaults.set(d, forKey: key)
        }
    }

    // MARK: - NSURLSession 配置（官方 SOCKS5 支持）

    /// 按当前代理设置生成 URLSessionConfiguration；未启用代理则返回默认直连配置
    var sessionConfiguration: URLSessionConfiguration {
        lock.lock()
        defer { lock.unlock() }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        if settings.isValid {
            // iOS connectionProxyDictionary 的 SOCKS key（CFNetwork 常量字符串）
            var dict: [String: Any] = [
                "SOCKSEnable": 1,
                "SOCKSProxy": settings.host.trimmingCharacters(in: .whitespaces),
                "SOCKSPort": settings.port,
            ]
            // SOCKS5 版本 + 认证
            dict["SOCKSVersion"] = 5
            if !settings.username.isEmpty {
                dict["SOCKSUser"] = settings.username
                dict["SOCKSPassword"] = settings.password
            }
            cfg.connectionProxyDictionary = dict
        }
        return cfg
    }

    // MARK: - WKWebView 私有代理（TrollStore 场景）

    /// 应用代理到 WKWebViewConfiguration（私有 proxyConfiguration）
    /// 多路径尝试：config.proxyConfiguration / config._proxyConfiguration / dataStore
    /// 返回是否成功应用（便于 UI 提示）
    @discardableResult
    func applyToWebView(_ config: WKWebViewConfiguration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard settings.isValid else { return false }

        // WebKit 代理字典 key：HTTP/HTTPS/SOCKS 全套（CFNetwork 常量字符串）
        let host = settings.host.trimmingCharacters(in: .whitespaces)
        var d: [String: Any] = [
            "HTTPEnable": 1,
            "HTTPProxy": host,
            "HTTPPort": settings.port,
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": settings.port,
            "SOCKSEnable": 1,
            "SOCKSProxy": host,
            "SOCKSPort": settings.port,
            "SOCKSVersion": 5,
        ]
        if !settings.username.isEmpty {
            d["SOCKSUser"] = settings.username
            d["SOCKSPassword"] = settings.password
            d["HTTPUser"] = settings.username
            d["HTTPPassword"] = settings.password
            d["HTTPSUser"] = settings.username
            d["HTTPSPassword"] = settings.password
        }

        // 路径1：proxyConfiguration（无下划线）——用 NSSelectorFromString 更可靠
        let sel1 = NSSelectorFromString("setProxyConfiguration:")
        if config.responds(to: sel1) {
            config.perform(sel1, with: d)
            return true
        }
        // 路径2：_proxyConfiguration（下划线 ivar）
        let sel2 = NSSelectorFromString("set_proxyConfiguration:")
        if config.responds(to: sel2) {
            config.perform(sel2, with: d)
            return true
        }
        // 路径3：通过 WKWebsiteDataStore 设置
        let store = config.websiteDataStore
        if store.responds(to: sel1) {
            store.perform(sel1, with: d)
            return true
        }
        if store.responds(to: sel2) {
            store.perform(sel2, with: d)
            return true
        }
        return false
    }
}
