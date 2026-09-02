//
//  SmsBar.swift
//  BuddyAuth — 接码快捷栏（内嵌于浏览器登录页）
//
//  一行式：取号 → 显示手机号 → 复制 → 轮询取码 → 显示验证码 → 复制
//  60 秒未收到自动释放换号；可手动提前换号
//  无独立页面，Token 在「设置」里保存
//

import SwiftUI
import WebKit
import UIKit
import UserNotifications

// MARK: - 接码 Store（纯逻辑）

@MainActor
final class SmsStore: ObservableObject {

    /// 接码方式：ejiema（token） / svipxx（卡密）
    enum SmsProvider: String, CaseIterable, Identifiable {
        case ejiema = "ejiema"
        case svipxx = "workbuddy"
        var id: String { rawValue }
        var name: String {
            switch self {
            case .ejiema: return "ejiema 接码"
            case .svipxx: return "workbuddy 卡密"
            }
        }
    }

    @Published var provider: SmsProvider {
        didSet { defaults.set(provider.rawValue, forKey: "sms_provider") }
    }
    @Published var token: String {
        didSet { defaults.set(token, forKey: "sms_token") }
    }
    /// svipxx 卡密
    @Published var cardKey: String {
        didSet { defaults.set(cardKey, forKey: "sms_card_key") }
    }
    /// svipxx 接码网址（含卡密）
    @Published var svipxxURL: String {
        didSet { defaults.set(svipxxURL, forKey: "sms_svipxx_url") }
    }
    @Published var keyword: String = "腾讯" {
        didSet { defaults.set(keyword, forKey: "sms_keyword") }
    }
    @Published var cardType: String = "实卡" {
        didSet { defaults.set(cardType, forKey: "sms_card_type") }
    }
    @Published var phone: String = ""
    @Published var smsContent: String = ""
    @Published var code: String = ""
    @Published var statusText: String = "未取号"
    @Published var isPolling = false
    @Published var isBlockedSms = false
    @Published var errorMessage: String?
    @Published var phoneGetTime: Date?
    @Published var tick: Date = Date()
    /// 接码平台余额
    @Published var balance: String = "—"
    @Published var balanceUpdatedAt: String = ""

    private let defaults = UserDefaults.standard
    private let api = SmsAPI()
    private let svipxxApi = SvipxxSmsAPI()
    private var pollTask: Task<Void, Never>?
    /// 后台保活任务 ID
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    /// 登录页 webView 弱引用（取号/收到验证码后自动填充）
    weak var loginWebView: WKWebView?

    /// 全自动换号模式（15s 没收到 → 自动刷新+释放+重新取号，循环直到登录成功）
    @Published var autoMode: Bool {
        didSet { defaults.set(autoMode, forKey: "sms_auto_mode") }
    }
    /// 全自动模式下的等待秒数
    var autoRetrySeconds: Int = 15

    /// 全局共享单例（浏览器快捷栏 + 设置页共用）
    static let shared = SmsStore()

    init() {
        provider = SmsProvider(rawValue: defaults.string(forKey: "sms_provider") ?? "") ?? .ejiema
        token = defaults.string(forKey: "sms_token") ?? ""
        cardKey = defaults.string(forKey: "sms_card_key") ?? ""
        svipxxURL = defaults.string(forKey: "sms_svipxx_url") ?? ""
        keyword = defaults.string(forKey: "sms_keyword") ?? "腾讯"
        autoMode = defaults.bool(forKey: "sms_auto_mode")
        cardType = defaults.string(forKey: "sms_card_type") ?? "实卡"
    }

    var hasToken: Bool {
        if provider == .svipxx {
            return !cardKey.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 取号时用的凭据（token 或卡密）
    var activeCredential: String {
        provider == .svipxx ? cardKey.trimmingCharacters(in: .whitespaces) : token.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 余额查询

    func queryBalance() async {
        guard hasToken else { return }
        do {
            let b = try await api.leftAmount(token: token)
            balance = b
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            balanceUpdatedAt = f.string(from: Date())
        } catch {
            balance = "查询失败"
        }
    }

    /// 系统通知（收到验证码/重要状态时提醒，后台也生效）
    func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            center.add(req)
        }
    }

    /// 简易日志：接入 CredentialStore 共享日志（日志页可见），同时保留最近几条
    private var recentLogs: [String] = []
    func appendLog(_ msg: String) {
        recentLogs.append(msg)
        if recentLogs.count > 20 { recentLogs.removeFirst() }
        // 同步到 CredentialStore 日志页
        CredentialStore.shared.appendLog(msg)
    }

    var autoReleaseSeconds: Int {
        guard let t = phoneGetTime else { return 0 }
        let timeout = autoMode ? autoRetrySeconds : pollTimeout
        return max(0, timeout - Int(Date().timeIntervalSince(t)))
    }

    // MARK: - svipxx 解析网址并取号

    /// 解析接码网址里的卡密（?key=xxx），设置 cardKey 后自动取号
    func parseSvipxxURLAndRun() async {
        let url = svipxxURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else {
            errorMessage = "请输入接码网址"
            return
        }
        // 提取 ?key= 参数
        if let q = url.split(separator: "?").last,
           let keyParam = q.split(separator: "&").first(where: { $0.hasPrefix("key=") }) {
            let k = String(keyParam.dropFirst(4))
            if !k.isEmpty {
                cardKey = k
                appendLog("🔑 已从网址提取卡密")
            }
        }
        guard !cardKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "网址中未找到卡密（?key=）"
            return
        }
        await getPhone()
    }

    // MARK: - 取号

    /// 取号防重入：正在自动换号时避免 stopPolling cancel 自身 Task
    private var isAutoRephoning = false

    func getPhone(retryCount: Int = 0) async {
        guard hasToken else {
            errorMessage = "未设置接码凭据（Token 或卡密），请到「设置」页填写"
            return
        }
        if !isAutoRephoning {
            stopPolling()
        }
        statusText = retryCount > 0 ? "取号中…（第 \(retryCount) 次重试）" : "取号中…"
        // 记录当前占用号（失败时要释放）
        let oldPhone = phone
        phone = ""
        code = ""
        smsContent = ""
        do {
            // 按 provider 分流取号
            let num: String
            if provider == .svipxx {
                num = try await getSvipxxPhone()
            } else {
                num = try await api.getPhone(token: token, keyword: keyword, card: cardType)
            }
            let digits = num.filter(\.isNumber)
            phone = String(digits.prefix(11))
            if phone.count < 11 {
                throw NSError(domain: "sms", code: 2, userInfo: [NSLocalizedDescriptionKey: "取号返回异常: \(num.prefix(50))"])
            }
            phoneGetTime = Date()
            statusText = "✅ \(phone)（已复制）"
            appendLog("📞 取号成功: \(phone)")
            UIPasteboard.general.string = phone
            // 自动填入登录页手机号输入框
            LoginAutofill.fillPhone(webView: loginWebView, phone: phone)
            startPolling()
        } catch {
            // 取号失败：释放可能占用的旧号
            if !oldPhone.isEmpty {
                try? await releaseCurrentPhone(oldPhone)
            }
            statusText = "取号失败"
            errorMessage = error.localizedDescription
            appendLog("❌ 取号失败: \(error.localizedDescription)")
            if autoMode && retryCount < 20 {
                // 全自动模式：失败 5 秒后自动重试（限流降频，最多 20 次）
                appendLog("⏳ 取号失败，5s 后重试（第 \(retryCount + 1) 次）: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await getPhone(retryCount: retryCount + 1)
            } else if autoMode {
                statusText = "取号失败（已达最大重试次数）"
            }
        }
    }

    // MARK: - svipxx 平台方法

    /// svipxx 取号
    private func getSvipxxPhone() async throws -> String {
        let card = cardKey.trimmingCharacters(in: .whitespaces)
        let resp = try await svipxxApi.getPhone(card: card)
        guard let data = resp["data"] as? [String: Any],
              let ph = data["phone"] as? String else {
            throw NSError(domain: "sms", code: 3, userInfo: [NSLocalizedDescriptionKey: "svipxx 取号失败: \(resp["msg"] ?? resp)"])
        }
        return ph
    }

    /// svipxx 换号（150s 内不可切换）
    private func svipxxChangePhone() async throws -> String {
        let card = cardKey.trimmingCharacters(in: .whitespaces)
        let resp = try await svipxxApi.changePhone(card: card)
        guard let data = resp["data"] as? [String: Any],
              let ph = data["phone"] as? String else {
            throw NSError(domain: "sms", code: 4, userInfo: [NSLocalizedDescriptionKey: "svipxx 换号失败: \(resp["msg"] ?? resp)"])
        }
        return ph
    }

    /// 按 provider 释放/换号
    private func releaseCurrentPhone(_ ph: String) async {
        if provider == .svipxx {
            // svipxx 用 change_phone 换号
            try? await svipxxApi.changePhone(card: cardKey.trimmingCharacters(in: .whitespaces))
        } else {
            try? await api.release(token: token, phone: ph)
        }
    }

    // MARK: - 轮询取码（每 5 秒）

    /// 取号后自动轮询取码，最长等待秒数（默认 180s = 3 分钟，足够浏览器登录收码）
    var pollTimeout: Int = 180

    private func startPolling() {
        stopPolling()
        isPolling = true
        // 后台保活：延长后台运行时间（切后台/锁屏时逻辑继续跑）
        bgTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self else { return }
            if self.bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTaskID)
                self.bgTaskID = .invalid
            }
        }
        // 全自动模式：15s 无短信就自动换号；普通模式：180s
        let timeout = autoMode ? autoRetrySeconds : pollTimeout
        statusText = autoMode ? "🤖 全自动模式：\(timeout)s 无短信自动换号…" : "取号成功，自动等待验证码…"
        appendLog(autoMode ? "🔁 开始轮询（全自动模式，\(timeout)s 无短信自动换号）" : "🔁 开始轮询取码（\(timeout)s 超时自动换号）")
        pollTask = Task { [weak self] in
            guard let self else { return }
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                elapsed += 5
                // 会话已失效/登录完成 → 停止取码（不浪费）
                if self.shouldStopForSession() {
                    await self.stopForSession()
                    return
                }
                if elapsed >= timeout {
                    await self.autoReleaseAndRephone()
                    return
                }
                await self.pollOnce()
            }
        }
    }

    /// 会话失效/登录完成检测：授权会话 completed（登录成功）或 failed（失效）→ 停止取码
    private func shouldStopForSession() -> Bool {
        let sessions = CredentialStore.shared.sessions
        // 存在已完成或失败的会话
        let done = sessions.contains { $0.status == .completed || $0.status == .failed }
        // 且当前没有 pending/polling 会话在等登录
        let active = sessions.contains { $0.status == .pending || $0.status == .polling }
        return done && !active
    }

    /// 会话结束 → 释放号码 + 停止轮询
    private func stopForSession() async {
        appendLog("⏹ 授权会话已结束，停止取码（释放 \(phone)）")
        if !phone.isEmpty {
            await releaseCurrentPhone(phone)
        }
        phone = ""
        code = ""
        smsContent = ""
        statusText = "会话已结束，停止取码"
        stopPolling()
    }

    private func pollOnce() async {
        guard !phone.isEmpty else { return }
        do {
            // 按 provider 分流取码
            var msg: String? = nil
            if provider == .svipxx {
                msg = await pollSvipxxSms()
            } else {
                msg = try await api.getMsg(token: token, phone: phone, keyword: keyword)
            }
            guard let msg else { return }  // 未收到继续等

            smsContent = msg
            // 屏蔽检测：短信含「屏蔽」字样
            if isBlocked(msg) {
                isBlockedSms = true
                if autoMode {
                    // 全自动模式：屏蔽号无用，自动换号
                    await autoReleaseAndRephone()
                    return
                }
                // 普通模式：提示并停止
                isPolling = false
                statusText = "🚫 短信被屏蔽，请换号重试"
                appendLog("🚫 短信被屏蔽: \(phone)（\(smsContent.prefix(60))）")
                code = ""
                stopPolling()
                return
            }
            code = SmsAPI.extractCode(from: msg) ?? ""
            isPolling = false
            statusText = code.isEmpty ? "✅ 已收到短信" : "✅ 验证码: \(code)（已复制）"
            appendLog(code.isEmpty ? "📩 收到短信（无验证码）" : "📩 收到验证码: \(code)（已复制并自动填入）")
            if !code.isEmpty {
                UIPasteboard.general.string = code
                // 自动填入登录页验证码输入框
                LoginAutofill.fillCode(webView: loginWebView, code: code)
                // 系统通知（后台也提醒）
                sendNotification(title: "📩 收到验证码", body: "\(phone) 的验证码: \(code)（已自动填入）")
            }
            stopPolling()
        } catch {
            // 网络错误不中断
        }
    }

    /// svipxx 轮询取码：get_sms + status 双通道解析
    /// 返回 nil=未收到；返回短信文本/验证码
    private func pollSvipxxSms() async -> String? {
        let card = cardKey.trimmingCharacters(in: .whitespaces)
        // 通道1：get_sms
        do {
            let resp = try await svipxxApi.getSms(card: card)
            if let msg = extractSvipxxSms(from: resp) { return msg }
        } catch { /* 继续通道2 */ }
        // 通道2：status（返回 verify_code + sms_content）
        do {
            let resp = try await svipxxApi.status(card: card)
            if let msg = extractSvipxxSms(from: resp) { return msg }
        } catch { }
        return nil
    }

    /// 从 svipxx 响应解析短信/验证码（兼容 data 各种结构）
    private func extractSvipxxSms(from resp: [String: Any]) -> String? {
        // 顶层直接给 yzm
        if let yzm = resp["yzm"] as? String, !yzm.isEmpty, yzm != "0" {
            return "验证码：\(yzm)"
        }
        if let sms = resp["sms"] as? String, !sms.isEmpty {
            return sms
        }
        // data 字典
        if let data = resp["data"] as? [String: Any] {
            if let sms = data["sms"] as? String, !sms.isEmpty { return sms }
            if let yzm = data["yzm"] as? String, !yzm.isEmpty, yzm != "0" { return "验证码：\(yzm)" }
            if let vc = data["verify_code"] as? String, !vc.isEmpty, vc != "0" { return "验证码：\(vc)" }
            if let sc = data["sms_content"] as? String, !sc.isEmpty { return sc }
        }
        // data 数组（可能含短信）
        if let arr = resp["data"] as? [Any], !arr.isEmpty {
            let s = arr.map { "\($0)" }.joined(separator: " ")
            if !s.isEmpty, s != "[]" { return s }
        }
        // data 直接是字符串（短信文本）
        if let str = resp["data"] as? String, !str.isEmpty, str != "[]" {
            return str
        }
        return nil
    }

    /// 短信被屏蔽检测
    private func isBlocked(_ msg: String) -> Bool {
        msg.contains("屏蔽") || msg.contains("已被屏蔽") || msg.contains("被拦截")
    }

    /// 超时自动换号：全自动模式刷新浏览器→释放→重新取号→自动填充（循环）
    private func autoReleaseAndRephone() async {
        if autoMode {
            // 全自动：完整换号流程（刷新页面 + 释放 + 取新号 + 自动填充）
            isAutoRephoning = true
            defer { isAutoRephoning = false }
            statusText = "🤖 \(autoRetrySeconds)s 无短信，自动换号…"
            appendLog("🔄 全自动换号（\(autoRetrySeconds)s 无短信）：刷新页面+释放+\(phone)")
            if let wv = loginWebView {
                wv.reload()
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !phone.isEmpty {
                await releaseCurrentPhone(phone)
            }
            await getPhone()  // getPhone 内自动填新号 + 重新 startPolling
            return
        }
        // 普通模式：直接换号
        isAutoRephoning = true
        defer { isAutoRephoning = false }
        statusText = "⏱ \(pollTimeout)s 未收到，自动换号…"
        appendLog("🔄 超时自动换号（\(pollTimeout)s 无短信）")
        if !phone.isEmpty {
            await releaseCurrentPhone(phone)
        }
        await getPhone()
    }

    // MARK: - 手动换号（刷新浏览器 → 等加载 → 释放 → 取号 → 自动填充全流程）

    func rephone() async {
        // 1. 刷新浏览器登录页（等页面重新加载）
        if let wv = loginWebView {
            wv.reload()
            statusText = "刷新登录页…"
            appendLog("🔄 手动换号：刷新登录页 + 释放 \(phone)")
        }
        // 2. 等页面加载（最多等 3 秒）
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        // 3. 释放旧号
        if !phone.isEmpty {
            await releaseCurrentPhone(phone)
        }
        // 4. 取新号 + 自动填充（getPhone 内已含：点手机号登录→填号→勾协议→点获取验证码）
        await getPhone()
    }

    // MARK: - 释放号码（停止轮询 + 释放 + 清空）

    func releasePhone() async {
        guard !phone.isEmpty else { return }
        stopPolling()
        do {
            if provider == .svipxx {
                // svipxx 无 release，用 change_phone 换号
                let newPhone = try await svipxxChangePhone()
                statusText = "已换号: \(newPhone)"
                appendLog("♻️ svipxx 已换号: \(phone) → \(newPhone)")
            } else {
                let r = try await api.release(token: token, phone: phone)
                statusText = "已释放 \(phone)：\(r)"
                appendLog("♻️ 已释放号码: \(phone)")
            }
        } catch {
            statusText = "释放失败"
            appendLog("❌ 释放失败: \(phone) — \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        phone = ""
        code = ""
        smsContent = ""
        phoneGetTime = nil
        isPolling = false
    }

    // MARK: - 停止

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
        // 结束后台保活
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
    }
}

// MARK: - 接码快捷栏（一行式，用于浏览器登录页底部）

struct SmsBar: View {
    @ObservedObject var store: SmsStore
    @State private var showConfirm = false
    @State private var showReleaseConfirm = false
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 8) {
            // workbuddy 模式：接码网址输入框
            if store.provider == .svipxx {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.brand)
                    TextField("输入接码网址（含卡密）", text: $store.svipxxURL)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            Task { await store.parseSvipxxURLAndRun() }
                        }
                    // 解析网址开始取号
                    Button {
                        Task { await store.parseSvipxxURLAndRun() }
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.brand)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }

            // 全自动模式开关
            HStack(spacing: 8) {
                Image(systemName: store.autoMode ? "bolt.circle.fill" : "circle.dashed")
                    .font(.system(size: 14))
                    .foregroundColor(store.autoMode ? Theme.warning : .secondary)
                Text("全自动换号")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(store.autoMode ? Theme.warning : .secondary)
                Text(store.autoMode ? "\(store.autoRetrySeconds)s 无短信自动刷新换号，直到登录成功" : "\(store.pollTimeout)s 无短信自动换号")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Toggle("", isOn: $store.autoMode)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .tint(Theme.warning)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((store.autoMode ? Theme.warning : Color(.tertiarySystemFill)).opacity(0.12))
            )

            // 第一行：手机号 + 操作按钮
            HStack(spacing: 8) {
                // 状态图标
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(statusColor.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: statusIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(statusColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(store.phone.isEmpty ? "未取号" : store.phone)
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .foregroundColor(store.phone.isEmpty ? .secondary : Theme.brand)
                    Text(store.statusText)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // 复制手机号
                if !store.phone.isEmpty {
                    Button {
                        UIPasteboard.general.string = store.phone
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color(.tertiarySystemFill)))
                            .foregroundColor(Theme.brand)
                    }
                    .buttonStyle(.plain)
                }

                // 无号 → 取号；有号 → 停止/释放/换号
                if store.phone.isEmpty {
                    Button {
                        Task { await store.getPhone() }
                    } label: {
                        Text("取号")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(AnyShapeStyle(Theme.brandGradient)))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                } else {
                    // 停止（终止轮询，保留号码）
                    Button {
                        store.stopPolling()
                        store.statusText = "已停止（号码保留）"
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.warning.opacity(0.15)))
                            .foregroundColor(Theme.warning)
                    }
                    .buttonStyle(.plain)
                    .help("停止轮询")

                    // 释放（释放号码，回到未取号）
                    Button {
                        showReleaseConfirm = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.danger.opacity(0.15)))
                            .foregroundColor(Theme.danger)
                    }
                    .buttonStyle(.plain)
                    .help("释放号码")

                    // 换号（释放 + 重新取）
                    Button {
                        showConfirm = true
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.brand.opacity(0.15)))
                            .foregroundColor(Theme.brand)
                    }
                    .buttonStyle(.plain)
                    .help("换号")
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )

            // 第二行：验证码（收到后显示）
            if !store.code.isEmpty {
                HStack(spacing: 8) {
                    Text("验证码")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(store.code)
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .foregroundColor(Theme.success)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = store.code
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Theme.success.opacity(0.12)))
                            .foregroundColor(Theme.success)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.success.opacity(0.06))
                )
            } else if store.isPolling {
                // 轮询中：显示等待验证码状态
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("自动查询验证码中…（\(store.autoReleaseSeconds)s 后换号）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.tertiarySystemGroupedBackground))
                )
            }
        }
        .confirmationDialog("确定换号？当前号码将释放", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("换号", role: .destructive) {
                Task { await store.rephone() }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("释放号码 \(store.phone)？", isPresented: $showReleaseConfirm, titleVisibility: .visible) {
            Button("释放", role: .destructive) {
                Task { await store.releasePhone() }
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak store] _ in
                store?.tick = Date()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
        .onChange(of: store.tick) { _ in }
    }

    private var statusColor: Color {
        if store.isPolling { return Theme.warning }
        if !store.code.isEmpty { return Theme.success }
        if !store.phone.isEmpty { return Theme.brand }
        return .secondary
    }

    private var statusIcon: String {
        if store.isPolling { return "arrow.triangle.2.circlepath" }
        if !store.code.isEmpty { return "checkmark" }
        if !store.phone.isEmpty { return "phone.fill" }
        return "iphone"
    }
}
