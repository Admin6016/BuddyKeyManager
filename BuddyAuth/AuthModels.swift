//
//  AuthModels.swift
//  BuddyAuth — WorkBuddy OAuth 授权管理器
//

import Foundation

// MARK: - 认证凭证（与 workbuddy2api 落盘格式兼容）

struct BuddyAccount: Codable, Identifiable, Equatable, Hashable {
    var id: String { uid }
    var uid: String
    var enterpriseId: String
    var nickname: String

    enum CodingKeys: String, CodingKey {
        case uid, enterpriseId, nickname
    }
}

struct BuddyAuth: Codable, Equatable, Hashable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Int64        // Unix 秒
    var domain: String
}

struct BuddyCredential: Codable, Identifiable, Equatable, Hashable {
    var account: BuddyAccount
    var auth: BuddyAuth
    /// 用户标注（备注，如"买的号1"），非空时列表优先展示
    var note: String?
    /// 入库时间（Unix 秒），0 = 未知
    var savedAt: Int64
    /// 缓存余额（积分），-1 = 未查询
    var balance: Int64
    /// 测活状态：nil=未测，true=有效，false=失效/异常
    var alive: Bool?
    /// 风控标记（测活 403 等，凭证可能有效但被风控）
    var riskControlled: Bool?

    // 兼容旧数据（缺字段时给默认值）
    init(account: BuddyAccount, auth: BuddyAuth, note: String? = nil, savedAt: Int64 = 0, balance: Int64 = -1, alive: Bool? = nil, riskControlled: Bool? = nil) {
        self.account = account
        self.auth = auth
        self.note = note
        self.savedAt = savedAt
        self.balance = balance
        self.alive = alive
        self.riskControlled = riskControlled
    }

    enum CodingKeys: String, CodingKey {
        case account, auth, note, savedAt, balance, alive, riskControlled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decode(BuddyAccount.self, forKey: .account)
        auth = try c.decode(BuddyAuth.self, forKey: .auth)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        savedAt = try c.decodeIfPresent(Int64.self, forKey: .savedAt) ?? 0
        balance = try c.decodeIfPresent(Int64.self, forKey: .balance) ?? -1
        alive = try c.decodeIfPresent(Bool.self, forKey: .alive)
        riskControlled = try c.decodeIfPresent(Bool.self, forKey: .riskControlled)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(account, forKey: .account)
        try c.encode(auth, forKey: .auth)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(savedAt, forKey: .savedAt)
        try c.encode(balance, forKey: .balance)
        try c.encodeIfPresent(alive, forKey: .alive)
        try c.encodeIfPresent(riskControlled, forKey: .riskControlled)
    }

    var id: String { account.uid }

    /// 列表主标题：标注优先，否则昵称，否则手机号（preferred_username 在 nickname）
    var displayName: String {
        if let note = note, !note.isEmpty { return note }
        if !account.nickname.isEmpty { return account.nickname }
        return account.uid
    }

    /// 副标题：括号显示手机号（nickname 是手机号/邮箱时）
    var subInfo: String {
        // nickname 通常是手机号/邮箱，标注时括号展示
        let nick = account.nickname
        if let note = note, !note.isEmpty, !nick.isEmpty, nick != note {
            return "（\(nick)）"
        }
        return ""
    }

    // 与 workbuddy2api 落盘格式一致
    static func from(token: TokenData, uid: String, nickname: String, domain: String, now: Int64 = Int64(Date().timeIntervalSince1970)) -> BuddyCredential {
        BuddyCredential(
            account: BuddyAccount(uid: uid, enterpriseId: "", nickname: nickname),
            auth: BuddyAuth(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: token.expiresIn > 0 ? now + token.expiresIn : now + 5184000,
                domain: domain.isEmpty ? "www.codebuddy.cn" : domain
            ),
            note: nil,
            savedAt: now,
            balance: -1
        )
    }
}

// MARK: - 授权会话（一次创建的授权链接）

struct AuthSession: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var state: String
    var authUrl: String
    var platform: String
    var createdAt: Date
    var status: SessionStatus    // pending / polling / completed / failed
    var accountUid: String?      // 完成登录后回填
    var lastError: String?
    var tokenExpiresAt: Int64?   // 登录成功后的 token 过期时间

    enum SessionStatus: String, Codable {
        case pending    // 等待用户打开浏览器登录
        case polling    // 正在轮询 token
        case completed  // 凭证已入库
        case failed     // 失败/超时
    }
}

// MARK: - OAuth 接口响应模型（统一信封，兼容单层/双层 data 嵌套）

/// 通用信封：{code, msg, data}
struct Envelope: Codable {
    let code: Int?
    let msg: String?
    let data: JSONValue?

    enum JSONValue: Codable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
            else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
            else { self = .null }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .number(let n): try c.encode(n)
            case .string(let s): try c.encode(s)
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }

        var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
        var stringValue: String? { if case .string(let s) = self { return s }; return nil }
        var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    }

    /// 剥壳：取最内层 data（兼容 {data:{data:...}} 与 {data:{...}}）
    var innerData: [String: JSONValue]? {
        guard var cur = data?.objectValue else { return nil }
        // 循环下钻：只要 data 的值还是 object 且只含 data 键，继续剥
        while let next = cur["data"]?.objectValue, cur.count <= 1 || cur["data"] != nil {
            if cur.count > 1 { break }
            cur = next
        }
        return cur
    }

    func stringField(_ key: String) -> String? { innerData?[key]?.stringValue }
    func intField(_ key: String) -> Int64? { innerData?[key]?.doubleValue.map { Int64($0) } }
}

// MARK: - JWT 解码（uid/nickname 来自 access_token payload）

struct JWTDecoder {
    /// 解码 JWT payload（不校验签名），返回 [String: Any]
    static func decodePayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payload = String(parts[1])
        let pad = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: pad.replacingOccurrences(of: "-", with: "+")
                                .replacingOccurrences(of: "_", with: "/")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// 从 JWT 提取 uid（sub）和昵称（preferred_username）
    static func userInfo(from token: String) -> (uid: String, nickname: String) {
        guard let payload = decodePayload(token) else { return ("", "") }
        let uid = payload["sub"] as? String ?? ""
        let nick = payload["preferred_username"] as? String ?? payload["email"] as? String ?? ""
        return (uid, nick)
    }
}

// MARK: - 简化 Token 数据（剥壳后的 token 字段）

struct TokenData: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int64
    let domain: String?
}
