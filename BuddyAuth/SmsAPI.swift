//
//  SmsAPI.swift
//  BuddyAuth — ejiema 接码平台客户端
//
//  API: https://api.ejiema.com/zc/data.php (GET, 明文返回)
//  getPhone / getMsg / release / block / leftAmount
//

import Foundation

struct SmsAPI {

    let base = "https://api.ejiema.com/zc/data.php"

    enum SmsError: LocalizedError {
        case noToken
        case api(String)
        case notReceived

        var errorDescription: String? {
            switch self {
            case .noToken: return "未设置接码 Token"
            case .api(let msg): return msg
            case .notReceived: return "尚未收到"
            }
        }
    }

    private func call(_ params: [String: String]) async throws -> String {
        var comps = URLComponents(string: base)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw SmsError.api("URL 构造失败") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        // 走代理配置（如有）
        let cfg = ProxyStore.shared.sessionConfiguration
        let (data, resp) = try await URLSession(configuration: cfg).data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw SmsError.api("HTTP \(http.statusCode)")
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasPrefix("ERROR:") {
            throw SmsError.api(text)
        }
        return text
    }

    // MARK: - 查询余额

    func leftAmount(token: String) async throws -> String {
        try await call(["code": "leftAmount", "token": token])
    }

    // MARK: - 取号

    func getPhone(token: String, keyword: String, card: String = "全部") async throws -> String {
        var params: [String: String] = ["code": "getPhone", "token": token]
        if !keyword.isEmpty { params["keyWord"] = keyword }
        if !card.isEmpty { params["cardType"] = card }
        return try await call(params)
    }

    // MARK: - 取码（轮询）

    /// 返回 nil = 尚未收到；返回短信内容
    func getMsg(token: String, phone: String, keyword: String) async throws -> String? {
        var params: [String: String] = ["code": "getMsg", "token": token, "phone": phone]
        if !keyword.isEmpty { params["keyWord"] = keyword }
        let text = try await call(params)
        if text.contains("[尚未收到]") || text.contains("尚未收到") {
            return nil
        }
        return text
    }

    // MARK: - 释放 / 拉黑

    func release(token: String, phone: String) async throws -> String {
        try await call(["code": "release", "token": token, "phone": phone])
    }

    func block(token: String, phone: String) async throws -> String {
        try await call(["code": "block", "token": token, "phone": phone])
    }

    // MARK: - 验证码提取

    /// 从短信内容提取验证码（优先找「验证码」等关键字后面的数字，避免手机号/金额干扰）
    /// 真实格式：<号码>/<金额>/【腾讯科技】您本次的腾讯统一身份验证码是094478 ，请在5分钟内完成验证。
    static func extractCode(from msg: String) -> String? {
        // 1. 优先找「验证码」关键字后的 4-8 位数字（支持 冒号/空格/是 等分隔）
        let patterns = [
            // 验证码是094478 / 验证码：123456 / 验证码 654321 / 验证码为888888
            "验证码\\s*(是|为|：|:)?\\s*([0-9]{4,8})",
            "code\\s*(是|为|：|:)?\\s*([0-9]{4,8})",
            "CODE\\s*(是|为|：|:)?\\s*([0-9]{4,8})",
            // 短信尾部常见：,123456 / ：123456 结束
            "(?:[：:，,，\\s])([0-9]{6})(?:[，,。\\s]|$)",
            "([0-9]{6})(?:[，,。]|$)",
        ]
        for p in patterns {
            if let m = msg.range(of: p, options: .regularExpression) {
                let matched = String(msg[m])
                let digits = matched.filter(\.isNumber)
                if digits.count >= 4 && digits.count <= 8 {
                    return digits
                }
            }
        }
        // 2. 兜底：取最后一个 4-8 位数字串（验证码通常在短信末尾）
        let all = msg.split(whereSeparator: { !$0.isNumber }).map(String.init)
        for part in all.reversed() {
            if part.count >= 4 && part.count <= 8 {
                return part
            }
        }
        return nil
    }
}
