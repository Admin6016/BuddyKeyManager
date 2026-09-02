//
//  PushAPI.swift
//  BuddyAuth — 推送凭据到 Buddy2API 服务器
//
//  101 版 buddy2api 管理接口：
//  POST /admin/login            {password} → 种 b2a_session cookie
//  POST /admin/account/import   {access_token, refresh_token, token_type, expires_at, domain, nickname, proxy} → {ok, uid, nickname, domain}
//

import Foundation

// MARK: - 推送配置 Store

@MainActor
final class PushStore: ObservableObject {
    static let shared = PushStore()

    @Published var baseURL: String {
        didSet { defaults.set(baseURL, forKey: "push_baseurl") }
    }
    @Published var password: String {
        didSet { defaults.set(password, forKey: "push_password") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        baseURL = defaults.string(forKey: "push_baseurl") ?? ""
        password = defaults.string(forKey: "push_password") ?? ""
    }

    var configured: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 规范化 baseURL（自动补 http://，去尾部斜杠）
    var normalizedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url.removeLast() }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://" + url
        }
        return url
    }

    var api: PushAPI? {
        let url = normalizedBaseURL
        guard !url.isEmpty else { return nil }
        return PushAPI(baseURL: url)
    }
}

struct PushAPI {

    let baseURL: String

    enum PushError: LocalizedError {
        case badURL
        case http(Int, String)
        case network(String)
        case loginFailed(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "服务器地址无效"
            case .http(let c, let b): return "HTTP \(c): \(b)"
            case .network(let m): return "网络错误: \(m)"
            case .loginFailed(let m): return "登录失败: \(m)"
            }
        }
    }

    /// 使用默认 URLSession（共享 cookie 存储，登录后自动带 cookie）
    /// 推送直连服务器（101 是国内服务器，不走代理避免代理失效导致失败）
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    /// 登录并返回 cookie（b2a_session）
    func login(password: String) async throws -> [HTTPCookie] {
        let url = URL(string: baseURL + "/admin/login")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])

        let (data, resp) = try await doRequest(req)
        if resp.statusCode >= 400 {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw PushError.http(resp.statusCode, body)
        }
        // 从响应头提取 Set-Cookie 存到共享存储
        if let headers = resp.allHeaderFields as? [String: String] {
            let newCookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            for c in newCookies {
                HTTPCookieStorage.shared.setCookie(c)
            }
        }
        return HTTPCookieStorage.shared.cookies(for: url) ?? []
    }

    /// 统一网络请求（带详细错误诊断）
    private func doRequest(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw PushError.network("无 HTTP 响应")
            }
            return (data, http)
        } catch let e as PushError {
            throw e
        } catch {
            // 详细诊断：NSError 的 domain/code/underlying
            let ns = error as NSError
            var detail = error.localizedDescription
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                detail += " (underlying: \(underlying.domain) \(underlying.code) \(underlying.localizedDescription))"
            }
            throw PushError.network("\(detail) [domain=\(ns.domain) code=\(ns.code)]")
        }
    }

    /// 推送单个凭证（带 cookie）
    func importCredential(_ cred: BuddyCredential, cookies: [HTTPCookie]) async throws -> (uid: String, nickname: String) {
        let url = URL(string: baseURL + "/admin/account/import")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 带 cookie
        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !cookieHeader.isEmpty {
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let body: [String: Any] = [
            "access_token": cred.auth.accessToken,
            "refresh_token": cred.auth.refreshToken,
            "token_type": "Bearer",
            "expires_at": cred.auth.expiresAt,
            "domain": cred.auth.domain,
            "nickname": cred.account.nickname,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await doRequest(req)
        let bodyText = String(data: data.prefix(500), encoding: .utf8) ?? ""
        if resp.statusCode >= 400 {
            throw PushError.http(resp.statusCode, bodyText)
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ok = obj["ok"] as? Bool ?? false
            if ok {
                return (obj["uid"] as? String ?? "", obj["nickname"] as? String ?? "")
            }
            throw PushError.loginFailed(bodyText)
        }
        throw PushError.network("响应解析失败")
    }
}
