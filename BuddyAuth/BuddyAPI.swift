//
//  BuddyAPI.swift
//  BuddyAuth — WorkBuddy OAuth 网络层
//
// 协议来源：EchoPing07/Buddy-2API-Go internal/upstream/client.go + fingerprint.go
// 流程：POST /v2/plugin/auth/state → 浏览器登录 → GET /v2/plugin/auth/token 轮询
//       → 从 access_token JWT 提取 uid/nickname（无需 /login/account 接口！）
//

import Foundation

/// OAuth API 客户端
struct BuddyAPI {

    enum Region: String, CaseIterable, Identifiable {
        case cn = "cn"
        case global = "global"

        var id: String { rawValue }

        var name: String {
            switch self {
            case .cn: return "中国区"
            case .global: return "国际区"
            }
        }

        var upstream: String {
            switch self {
            case .cn: return "https://copilot.tencent.com"
            case .global: return "https://www.codebuddy.ai"
            }
        }

        var domain: String {
            switch self {
            case .cn: return "www.codebuddy.cn"
            case .global: return "www.codebuddy.ai"
            }
        }

        var origin: String {
            switch self {
            case .cn: return "https://www.codebuddy.cn"
            case .global: return "https://www.workbuddy.ai"
            }
        }
    }

    let region: Region

    init(region: Region = .cn) {
        self.region = region
    }

    enum APIError: LocalizedError {
        case http(Int, String)
        case badEnvelope(String)
        case noAuthUrl
        case noState
        case noToken
        case network(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body)"
            case .badEnvelope(let msg): return "响应解析失败: \(msg)"
            case .noAuthUrl: return "响应缺少 authUrl"
            case .noState: return "响应缺少 state"
            case .noToken: return "响应缺少 accessToken"
            case .network(let msg): return "网络错误: \(msg)"
            }
        }
    }

    // MARK: - OAuth 请求头（来自 EchoPing07 oauthHeaders）

    /// OAuth 启动/轮询头：无账号，X-No-* 标记
    private func oauthHeaders() -> [String: String] {
        let rid = Self.uuidHex()
        return [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "X-Requested-With": "XMLHttpRequest",
            "X-Domain": "www.codebuddy.ai",       // 固定值，中国端点同样适用
            "X-No-Authorization": "true",
            "X-No-User-Id": "true",
            "X-No-Enterprise-Id": "true",
            "X-No-Department-Info": "true",
            "X-Product": "SaaS",
            "User-Agent": Self.userAgent(),
            "X-Request-ID": rid,
            "X-B3-TraceId": rid,
            "X-B3-SpanId": Self.randHex(8),
            "X-B3-Sampled": "1",
        ]
    }

    /// 刷新头（refreshHeaders）：带 Authorization + X-Refresh-Token
    private func refreshHeaders(cred: BuddyCredential) -> [String: String] {
        let rid = Self.uuidHex()
        var h: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/plain, */*",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "X-Requested-With": "XMLHttpRequest",
            "Origin": region.origin,
            "Referer": region.origin + "/",
            "X-Product": "SaaS",
            "User-Agent": Self.userAgent(),
            "X-Request-ID": rid,
            "X-B3-TraceId": rid,
            "X-B3-SpanId": Self.randHex(8),
            "X-B3-Sampled": "1",
            "X-Auth-Refresh-Source": "plugin",
        ]
        if !cred.auth.accessToken.isEmpty {
            h["Authorization"] = "Bearer \(cred.auth.accessToken)"
        }
        h["X-Refresh-Token"] = cred.auth.refreshToken
        // accountHeader 模式：有值用 X-User-Id，无值用 X-No-User-Id
        if !cred.account.uid.isEmpty {
            h["X-User-Id"] = cred.account.uid
        } else {
            h["X-No-User-Id"] = "1"
        }
        if !cred.account.enterpriseId.isEmpty {
            h["X-Enterprise-Id"] = cred.account.enterpriseId
        } else {
            h["X-No-Enterprise-Id"] = "1"
        }
        // domainHeader：有 domain 用 X-Domain，无值用 X-No-Department-Info
        if !cred.auth.domain.isEmpty {
            h["X-Domain"] = cred.auth.domain
        } else {
            h["X-No-Department-Info"] = "1"
        }
        return h
    }

    // MARK: - 1. 创建授权链接（OAuthStart）

    func createAuthSession(platform: String = "CLI") async throws -> (authUrl: String, state: String) {
        let nonce = Self.randHex(8)
        let urlStr = "\(region.upstream)/v2/plugin/auth/state?platform=\(platform.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? platform)&nonce=\(nonce)"
        guard let url = URL(string: urlStr) else { throw APIError.network("bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.allHTTPHeaderFields = oauthHeaders()
        req.httpBody = Data("{\"nonce\":\"\(nonce)\"}".utf8)

        let raw = try await perform(req)
        let env = try decodeEnvelope(raw)
        guard let inner = env.innerData else { throw APIError.badEnvelope(String(data: raw.prefix(200), encoding: .utf8) ?? "") }
        guard let authUrl = inner["authUrl"]?.stringValue, !authUrl.isEmpty else { throw APIError.noAuthUrl }
        guard let state = inner["state"]?.stringValue, !state.isEmpty else { throw APIError.noState }
        return (authUrl, state)
    }

    // MARK: - 2. 轮询 token（OAuthPoll）

    /// 返回 nil 表示还在等待登录（code=11217），非 nil 表示登录成功
    func pollToken(state: String) async throws -> TokenData? {
        let urlStr = "\(region.upstream)/v2/plugin/auth/token?state=\(state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state)"
        guard let url = URL(string: urlStr) else { throw APIError.network("bad url") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.allHTTPHeaderFields = oauthHeaders()

        let raw = try await perform(req)
        let env = try decodeEnvelope(raw)
        guard let inner = env.innerData else {
            // code=11217 时 data 可能为空
            if env.code == 11217 { return nil }
            throw APIError.badEnvelope(String(data: raw.prefix(200), encoding: .utf8) ?? "")
        }
        guard let accessToken = inner["accessToken"]?.stringValue, !accessToken.isEmpty else {
            throw APIError.noToken
        }
        return TokenData(
            accessToken: accessToken,
            refreshToken: inner["refreshToken"]?.stringValue ?? "",
            expiresIn: inner["expiresIn"]?.doubleValue.map { Int64($0) } ?? 0,
            domain: inner["domain"]?.stringValue
        )
    }

    // MARK: - 3. 刷新 token

    func refresh(credential: BuddyCredential) async throws -> TokenData {
        let url = URL(string: "\(region.upstream)/v2/plugin/auth/token/refresh")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.allHTTPHeaderFields = refreshHeaders(cred: credential)
        req.httpBody = Data("{}".utf8)

        let raw = try await perform(req)
        let env = try decodeEnvelope(raw)
        guard let inner = env.innerData,
              let accessToken = inner["accessToken"]?.stringValue, !accessToken.isEmpty else {
            throw APIError.noToken
        }
        return TokenData(
            accessToken: accessToken,
            refreshToken: inner["refreshToken"]?.stringValue ?? "",
            expiresIn: inner["expiresIn"]?.doubleValue.map { Int64($0) } ?? 0,
            domain: inner["domain"]?.stringValue
        )
    }

    // MARK: - 每日签到

    @discardableResult
    func dailyCheckin(credential: BuddyCredential) async throws -> Bool {
        let url = URL(string: "\(region.upstream)/v2/billing/meter/daily-checkin")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        var headers = commonBillingHeaders(cred: credential)
        headers["X-Product"] = "SaaS"
        req.allHTTPHeaderFields = headers
        req.httpBody = Data("{}".utf8)

        let raw = try await perform(req)
        let env = try decodeEnvelope(raw)
        if let code = env.code, code != 0 {
            throw APIError.http(200, "code=\(code) msg=\(env.msg ?? "")")
        }
        return true
    }

    // MARK: - 余额查询

    /// 单个套餐资源
    struct ResourcePackage {
        let packageName: String
        let capacitySize: Int64     // 总额度
        let capacityRemain: Int64   // 剩余
        let capacityUsed: Int64     // 已用
        let cycleSize: Int64        // 周期总额
        let cycleRemain: Int64      // 周期剩余
        let cycleUsed: Int64        // 周期已用
    }

    /// 余额查询（get-user-resource）：返回套餐明细列表
    func userResource(credential: BuddyCredential) async throws -> [ResourcePackage] {
        let url = URL(string: "\(region.upstream)/v2/billing/meter/get-user-resource")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        var headers = commonBillingHeaders(cred: credential)
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let body: [String: Any] = [
            "PageNumber": 1, "PageSize": 100, "ProductCode": "p_tcaca",
            "Status": [0, 3],
            "PackageEndTimeRangeBegin": fmt.string(from: now),
            "PackageEndTimeRangeEnd": fmt.string(from: now.addingTimeInterval(365 * 101 * 24 * 3600)),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.allHTTPHeaderFields = headers

        let raw = try await perform(req)
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let data = obj["data"] as? [String: Any],
              let resp = data["Response"] as? [String: Any],
              let rdata = resp["Data"] as? [String: Any],
              let accounts = rdata["Accounts"] as? [[String: Any]] else {
            return []
        }
        var out: [ResourcePackage] = []
        for a in accounts {
            let g = { (k: String) -> Int64 in (a[k] as? NSNumber)?.int64Value ?? 0 }
            out.append(ResourcePackage(
                packageName: a["PackageName"] as? String ?? "套餐",
                capacitySize: g("CapacitySize"),
                capacityRemain: g("CapacityRemain"),
                capacityUsed: g("CapacityUsed"),
                cycleSize: g("CycleCapacitySize"),
                cycleRemain: g("CycleCapacityRemain"),
                cycleUsed: g("CycleCapacityUsed")
            ))
        }
        return out
    }

    /// 聚合余额（所有套餐 CycleCapacityRemain 之和，负值钳 0）
    func totalResource(credential: BuddyCredential) async throws -> Int64 {
        let pkgs = try await userResource(credential: credential)
        var total: Int64 = 0
        for p in pkgs {
            let r: Int64
            if p.cycleSize > 0 { r = p.cycleRemain }
            else if p.cycleRemain > 0 || p.cycleUsed > 0 { r = p.cycleRemain }
            else { r = p.capacityRemain }
            total += max(r, 0)
        }
        return total
    }

    private func commonBillingHeaders(cred: BuddyCredential) -> [String: String] {
        let rid = Self.uuidHex()
        var h: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/plain, */*",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "X-Requested-With": "XMLHttpRequest",
            "Origin": region.origin,
            "Referer": region.origin + "/",
            "User-Agent": Self.userAgent(),
            "X-Request-ID": rid,
            "X-B3-TraceId": rid,
            "X-B3-SpanId": Self.randHex(8),
            "X-B3-Sampled": "1",
        ]
        if !cred.auth.accessToken.isEmpty {
            h["Authorization"] = "Bearer \(cred.auth.accessToken)"
        } else {
            h["X-No-Authorization"] = "1"
        }
        if !cred.account.uid.isEmpty {
            h["X-User-Id"] = cred.account.uid
        } else {
            h["X-No-User-Id"] = "1"
        }
        if !cred.account.enterpriseId.isEmpty {
            h["X-Enterprise-Id"] = cred.account.enterpriseId
            h["X-Tenant-Id"] = cred.account.enterpriseId
        } else {
            h["X-No-Enterprise-Id"] = "1"
        }
        if !cred.auth.domain.isEmpty {
            h["X-Domain"] = cred.auth.domain
        } else {
            h["X-No-Department-Info"] = "1"
        }
        return h
    }

    // MARK: - 信封解析（单层 data，兼容双层）

    private func decodeEnvelope(_ raw: Data) throws -> Envelope {
        let env: Envelope
        do {
            env = try JSONDecoder().decode(Envelope.self, from: raw)
        } catch {
            throw APIError.badEnvelope(String(data: raw.prefix(200), encoding: .utf8) ?? "")
        }
        if let code = env.code, code != 0, code != 11217 {
            throw APIError.http(200, "code=\(code) msg=\(env.msg ?? "")")
        }
        return env
    }

    // MARK: - 底层请求

    /// 每次构建 session（跟随代理配置变化；未启用代理则直连）
    private var session: URLSession {
        let cfg = ProxyStore.shared.sessionConfiguration
        return URLSession(configuration: cfg)
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
                throw APIError.http(http.statusCode, body)
            }
            return data
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }

    // MARK: - 测活（Ping）

    /// 凭证测活：发最小 chat 请求验证 token 有效
    /// 返回 nil = 凭证有效（HTTP 200）；抛错 = 失效/异常
    func ping(credential: BuddyCredential) async throws {
        let url = URL(string: "\(region.upstream)/v2/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30

        // chatHeaders（EchoPing07）：common + 账号 + IDE/CLI + SDK
        let rid = Self.uuidHex()
        let span = Self.randHex(8)
        var h: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/plain, */*",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "X-Requested-With": "XMLHttpRequest",
            "Origin": region.origin,
            "Referer": region.origin + "/",
            "X-Product": "SaaS",
            "User-Agent": Self.userAgent(),
            "X-Request-ID": rid,
            "X-B3-TraceId": rid,
            "X-B3-SpanId": span,
            "X-B3-Sampled": "1",
            "b3": "\(rid)-\(span)-1-",
            "X-IDE-Type": "CLI",
            "X-IDE-Name": "CLI",
            "X-IDE-Version": "2.63.2",
            "x-codebuddy-request": "1",
            "X-Agent-Intent": "craft",
            "X-Conversation-ID": Self.uuidHex(),
            "X-Conversation-Request-ID": rid,
            "X-Conversation-Message-ID": Self.uuidHex(),
            "x-stainless-arch": "x64",
            "x-stainless-lang": "js",
            "x-stainless-os": "Linux",
            "x-stainless-package-version": "2.63.2",
            "x-stainless-retry-count": "0",
            "x-stainless-runtime": "node",
            "x-stainless-runtime-version": "20.11.0",
        ]
        if !credential.auth.accessToken.isEmpty {
            h["Authorization"] = "Bearer \(credential.auth.accessToken)"
        } else {
            h["X-No-Authorization"] = "1"
        }
        if !credential.account.uid.isEmpty {
            h["X-User-Id"] = credential.account.uid
        } else {
            h["X-No-User-Id"] = "1"
        }
        if !credential.account.enterpriseId.isEmpty {
            h["X-Enterprise-Id"] = credential.account.enterpriseId
            h["X-Tenant-Id"] = credential.account.enterpriseId
        } else {
            h["X-No-Enterprise-Id"] = "1"
        }
        if !credential.auth.domain.isEmpty {
            h["X-Domain"] = credential.auth.domain
        } else {
            h["X-No-Department-Info"] = "1"
        }
        req.allHTTPHeaderFields = h

        let body: [String: Any] = [
            "model": "auto",
            "stream": true,
            "messages": [
                ["role": "system", "content": "You are a helpful assistant."],
                ["role": "user", "content": "你好"],
            ],
            "stream_options": ["include_usage": true],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let bodyText = String(data: data.prefix(400), encoding: .utf8) ?? ""
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            throw APIError.http(401, bodyText)
        }
        if let http = resp as? HTTPURLResponse, http.statusCode == 403 {
            // 403 可能是安全审核（凭证有效但内容/模型受限）——单独提示
            throw APIError.http(403, "安全审核拦截（凭证可能有效）：\(bodyText)")
        }
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError.http(http.statusCode, bodyText)
        }
        // 200 = 凭证有效
    }

    // MARK: - 工具

    static func userAgent() -> String {
        "CLI/2.63.2 CodeBuddy/2.63.2"
    }

    /// 32 字符无连字符 uuid hex
    static func uuidHex() -> String {
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { b[i] = UInt8.random(in: 0...255) }
        b[6] = (b[6] & 0x0f) | 0x40
        b[8] = (b[8] & 0x3f) | 0x80
        return b.map { String(format: "%02x", $0) }.joined()
    }

    /// n 字节 hex
    static func randHex(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        for i in 0..<n { b[i] = UInt8.random(in: 0...255) }
        return b.map { String(format: "%02x", $0) }.joined()
    }
}
