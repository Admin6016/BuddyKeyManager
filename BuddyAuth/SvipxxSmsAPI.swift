//
//  SvipxxSmsAPI.swift
//  BuddyAuth — workbuddy.svipxx.cn 验证码接收平台（卡密制）
//
//  协议：
//  POST https://workbuddy.svipxx.cn/api.php (multipart/form-data)
//  action: status / get_phone / get_sms / change_phone
//  card_key: 卡密 AES-128-CBC 加密后 Base64
//

import Foundation
import CommonCrypto

struct SvipxxSmsAPI {

    /// workbuddy 验证码接收平台协议常量
    let apiURL = "https://workbuddy.svipxx.cn/api.php"
    /// AES-128-CBC 加密卡密（平台固定协议）
    let aesKey = "xXjM2026#cardK!y"   // 16 字节
    let aesIV  = "a6s8d0f2g4h6j8k0"   // 16 字节

    enum SmsError: LocalizedError {
        case api(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .api(let m): return m
            case .network(let m): return "网络错误: \(m)"
            }
        }
    }

    // MARK: - AES-128-CBC 加密卡密（PKCS7 + Base64）

    func encryptCardKey(_ card: String) -> String? {
        let keyData = Data(aesKey.utf8)
        let ivData = Data(aesIV.utf8)
        guard keyData.count == 16, ivData.count == 16 else { return nil }
        // 不要手动 PKCS7 填充！让 CCCrypt 用 kCCOptionPKCS7Padding 自动填充
        let input = Data(card.utf8)

        var outLen = input.count + 16
        var out = [UInt8](repeating: 0, count: outLen)
        let status = input.withUnsafeBytes { inBuf in
            keyData.withUnsafeBytes { keyBuf in
                ivData.withUnsafeBytes { ivBuf in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, keyData.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, input.count,
                            &out, outLen, &outLen)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(outLen)).base64EncodedString()
    }

    // MARK: - API 调用

    private func call(action: String, card: String) async throws -> [String: Any] {
        guard let encrypted = encryptCardKey(card) else {
            throw SmsError.api("卡密加密失败")
        }
        var req = URLRequest(url: URL(string: apiURL)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30

        // multipart/form-data
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        appendField("action", action)
        appendField("card_key", encrypted)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        // 直连（不走代理，国内服务器）
        let session = URLSession(configuration: .ephemeral)
        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                throw SmsError.api("HTTP \(http.statusCode)")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SmsError.api("响应解析失败")
            }
            return obj
        } catch let e as SmsError {
            throw e
        } catch {
            throw SmsError.network(error.localizedDescription)
        }
    }

    // MARK: - 四个接口

    /// status 查询状态
    func status(card: String) async throws -> [String: Any] {
        try await call(action: "status", card: card)
    }

    /// get_phone 取号
    func getPhone(card: String) async throws -> [String: Any] {
        try await call(action: "get_phone", card: card)
    }

    /// get_sms 取码（code:0=等待, code:1=收到）
    func getSms(card: String) async throws -> [String: Any] {
        try await call(action: "get_sms", card: card)
    }

    /// change_phone 换号
    func changePhone(card: String) async throws -> [String: Any] {
        try await call(action: "change_phone", card: card)
    }
}
