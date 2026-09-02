//
//  CredentialStore.swift
//  BuddyAuth — 凭证存储与轮询管理
//

import Foundation
import Combine

@MainActor
final class CredentialStore: ObservableObject {

    @Published var credentials: [BuddyCredential] = []
    @Published var sessions: [AuthSession] = []
    @Published var log: String = ""

    private let api: BuddyAPI
    private var pollTimers: [UUID: Task<Void, Never>] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// 全局共享实例（供 SmsStore 等写日志）
    static let shared = CredentialStore()

    init(region: BuddyAPI.Region = .cn) {
        self.api = BuddyAPI(region: region)
        load()
    }

    // MARK: - 持久化

    private var credFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("credentials.json")
    }

    private var sessFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sessions.json")
    }

    func load() {
        if let d = try? Data(contentsOf: credFileURL),
           let arr = try? decoder.decode([BuddyCredential].self, from: d) {
            credentials = arr
        }
        if let d = try? Data(contentsOf: sessFileURL),
           let arr = try? decoder.decode([AuthSession].self, from: d) {
            sessions = arr
        }
        appendLog("加载完成：\(credentials.count) 个凭证，\(sessions.count) 个会话")
    }

    private func persist() {
        if let d = try? encoder.encode(credentials) {
            try? d.write(to: credFileURL, options: .atomic)
        }
        if let d = try? encoder.encode(sessions) {
            try? d.write(to: sessFileURL, options: .atomic)
        }
    }

    func appendLog(_ msg: String) {
        let line = "[\(Self.timeStr())] \(msg)"
        log = line + "\n" + log
        if log.count > 8000 { log = String(log.prefix(8000)) }
    }

    static func timeStr(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    // MARK: - 创建授权链接

    func createAuthSession(platform: String = "CLI") async {
        do {
            let (authUrl, state) = try await api.createAuthSession(platform: platform)
            let sess = AuthSession(id: UUID(), state: state, authUrl: authUrl,
                                   platform: platform, createdAt: Date(), status: .pending)
            sessions.insert(sess, at: 0)
            persist()
            appendLog("已创建授权会话 \(sess.id.uuidString.prefix(8))（\(api.region.name)）")
            startPolling(sessionID: sess.id)
        } catch {
            appendLog("创建授权链接失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 轮询监听（每 3 秒）

    func startPolling(sessionID: UUID) {
        stopPolling(sessionID: sessionID)
        pollTimers[sessionID] = Task { [weak self] in
            guard let self else { return }
            var attempts = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                attempts += 1
                await self.pollOnce(sessionID: sessionID)
                if attempts >= 100 {
                    await self.failSession(sessionID: sessionID, reason: "等待登录超时（10分钟）")
                    self.stopPolling(sessionID: sessionID)
                    return
                }
            }
        }
    }

    func stopPolling(sessionID: UUID) {
        pollTimers[sessionID]?.cancel()
        pollTimers[sessionID] = nil
    }

    private func failSession(sessionID: UUID, reason: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].status = .failed
        sessions[idx].lastError = reason
        persist()
        appendLog("会话 \(sessionID.uuidString.prefix(8)) 失败: \(reason)")
    }

    private func pollOnce(sessionID: UUID) async {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else {
            stopPolling(sessionID: sessionID)
            return
        }
        let sess = sessions[idx]
        guard sess.status == .pending || sess.status == .polling else {
            stopPolling(sessionID: sessionID)
            return
        }
        if sess.status != .polling {
            sessions[idx].status = .polling
            persist()
            appendLog("开始轮询 token（state=\(sess.state.prefix(8))…）")
        }

        do {
            // 轮询 token：nil = 还在等待登录（code 11217）
            guard let tok = try await api.pollToken(state: sess.state) else {
                return  // 用户还没登录完，继续等
            }
            // 从 access_token JWT 提取 uid + nickname（无需 login/account 接口）
            let (uid, nickname) = JWTDecoder.userInfo(from: tok.accessToken)
            guard !uid.isEmpty else {
                appendLog("JWT 解析 uid 失败，继续轮询")
                return
            }
            let domain = tok.domain ?? api.region.domain
            var cred = BuddyCredential.from(token: tok, uid: uid, nickname: nickname.isEmpty ? uid.prefix(8).description : nickname, domain: domain)
            if let existing = credentials.firstIndex(where: { $0.account.uid == uid }) {
                // 更新时保留旧凭证的 note/balance/savedAt/alive
                cred.note = credentials[existing].note
                cred.balance = credentials[existing].balance
                cred.savedAt = credentials[existing].savedAt
                cred.alive = credentials[existing].alive
                credentials[existing] = cred
                appendLog("凭证已更新: \(nickname)（\(api.region.name)）")
            } else {
                credentials.insert(cred, at: 0)
                appendLog("新凭证入库: \(nickname)（\(api.region.name)）")
            }

            if let si = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[si].status = .completed
                sessions[si].accountUid = uid
                sessions[si].tokenExpiresAt = cred.auth.expiresAt
                sessions[si].lastError = nil
            }
            persist()
            stopPolling(sessionID: sessionID)
            appendLog("✅ 登录成功，凭证已保存（过期 \(fmtExpiry(cred.auth.expiresAt))）")
        } catch {
            if attemptTooMany(sessionID: sessionID) {
                appendLog("轮询 \(sess.state.prefix(8)) 出错: \(error.localizedDescription)")
            }
        }
    }

    private var attemptCounts: [UUID: Int] = [:]
    private func attemptTooMany(sessionID: UUID) -> Bool {
        let n = attemptCounts[sessionID] ?? 0
        attemptCounts[sessionID] = n + 1
        return n % 10 == 0
    }

    // MARK: - 刷新 token

    func refreshCredential(_ cred: BuddyCredential) async {
        do {
            let tok = try await api.refresh(credential: cred)
            var updated = cred
            updated.auth.accessToken = tok.accessToken
            if !tok.refreshToken.isEmpty { updated.auth.refreshToken = tok.refreshToken }
            if let d = tok.domain, !d.isEmpty { updated.auth.domain = d }
            if tok.expiresIn > 0 { updated.auth.expiresAt = Int64(Date().timeIntervalSince1970) + tok.expiresIn }
            if let idx = credentials.firstIndex(where: { $0.account.uid == cred.account.uid }) {
                // 保留现有 note/alive/balance/savedAt（刷新不丢标注等）
                let existing = credentials[idx]
                updated.note = existing.note
                updated.alive = existing.alive
                updated.balance = existing.balance
                updated.savedAt = existing.savedAt
                credentials[idx] = updated
            }
            if let si = sessions.firstIndex(where: { $0.accountUid == cred.account.uid }) {
                sessions[si].tokenExpiresAt = updated.auth.expiresAt
            }
            persist()
            appendLog("已刷新凭证 \(cred.account.nickname): 新 token 有效期 \(fmtExpiry(updated.auth.expiresAt))")
        } catch {
            appendLog("刷新凭证 \(cred.account.nickname) 失败: \(error.localizedDescription)")
        }
    }

    private func fmtExpiry(_ ts: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: - 全部刷新（App 启动/前台）

    func refreshAllIfNeeded(within: TimeInterval = 3600 * 24) {
        for cred in credentials {
            let now = Int64(Date().timeIntervalSince1970)
            if cred.auth.expiresAt <= now + Int64(within) {
                Task { await refreshCredential(cred) }
            }
        }
    }

    // MARK: - 余额查询

    /// 查询凭证余额：返回 (聚合余额, 套餐明细)，并把余额缓存到凭证
    func queryResource(_ cred: BuddyCredential) async -> (total: Int64, packages: [BuddyAPI.ResourcePackage]) {
        do {
            let pkgs = try await api.userResource(credential: cred)
            var total: Int64 = 0
            for p in pkgs {
                let r: Int64
                if p.cycleSize > 0 { r = p.cycleRemain }
                else if p.cycleRemain > 0 || p.cycleUsed > 0 { r = p.cycleRemain }
                else { r = p.capacityRemain }
                total += max(r, 0)
            }
            // 缓存余额到凭证
            if let idx = credentials.firstIndex(where: { $0.account.uid == cred.account.uid }) {
                credentials[idx].balance = total
                persist()
            }
            appendLog("💰 余额查询: \(cred.account.nickname) 剩余 \(total) 积分（\(pkgs.count) 个套餐）")
            return (total, pkgs)
        } catch {
            appendLog("❌ 余额查询失败: \(cred.account.nickname) — \(error.localizedDescription)")
            return (0, [])
        }
    }

    // MARK: - 排序（标注优先 → 按入库时间）

    /// 标注的优先展示，其次按入库时间倒序
    var sortedCredentials: [BuddyCredential] {
        credentials.sorted { a, b in
            let aNote = !(a.note ?? "").isEmpty
            let bNote = !(b.note ?? "").isEmpty
            if aNote != bNote { return aNote }
            return a.savedAt > b.savedAt
        }
    }

    // MARK: - 标注

    /// 设置/清除标注
    func setNote(uid: String, note: String) {
        guard let idx = credentials.firstIndex(where: { $0.account.uid == uid }) else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        credentials[idx].note = trimmed.isEmpty ? nil : trimmed
        persist()
        appendLog("标注 \(credentials[idx].displayName): \(trimmed.isEmpty ? "已清除" : trimmed)")
    }

    // MARK: - 推送（Buddy2API 服务器入库）

    /// 推送单个凭证到服务器；返回 (uid, nickname)
    func pushCredential(_ cred: BuddyCredential) async throws -> (String, String) {
        guard let api = PushStore.shared.api else {
            let err = NSError(domain: "push", code: 1, userInfo: [NSLocalizedDescriptionKey: "未配置服务器地址，请到设置页填写"])
            appendLog("❌ 推送失败: \(cred.account.nickname) — \(err.localizedDescription)")
            throw err
        }
        do {
            let cookies = try await api.login(password: PushStore.shared.password)
            let result = try await api.importCredential(cred, cookies: cookies)
            appendLog("📤 推送成功: \(cred.account.nickname) → \(result.1.isEmpty ? result.0 : result.1)")
            return result
        } catch {
            appendLog("❌ 推送失败: \(cred.account.nickname) — \(error.localizedDescription)")
            throw error
        }
    }

    /// 批量推送全部凭证；返回 (成功数, 失败详情列表)
    func pushAllCredentials() async -> (success: Int, failed: [String]) {
        guard !credentials.isEmpty else { return (0, []) }
        appendLog("📤 开始批量推送 \(credentials.count) 个凭证…")
        var ok = 0
        var failed: [String] = []
        for cred in credentials {
            do {
                let (uid, nick) = try await pushCredential(cred)
                ok += 1
            } catch {
                failed.append("\(cred.account.nickname): \(error.localizedDescription)")
            }
        }
        appendLog("📤 批量推送完成: 成功 \(ok) 个，失败 \(failed.count) 个")
        return (ok, failed)
    }

    // MARK: - 批量测活

    /// 批量测活全部凭证；返回 (成功数, 风控数, 失效数)
    func pingAllCredentials() async -> (ok: Int, risk: Int, dead: Int) {
        guard !credentials.isEmpty else { return (0, 0, 0) }
        appendLog("🔍 开始批量测活 \(credentials.count) 个凭证…")
        var ok = 0, risk = 0, dead = 0
        for cred in credentials {
            let alive = await pingCredential(cred)
            if alive { ok += 1 }
            else if cred.riskControlled == true { risk += 1 }
            else { dead += 1 }
        }
        appendLog("🔍 批量测活完成: 有效 \(ok)，风控 \(risk)，失效 \(dead)")
        return (ok, risk, dead)
    }

    // MARK: - 测活

    /// 测活：返回 true=凭证有效，false=失效；结果缓存到凭证 alive 字段
    func pingCredential(_ cred: BuddyCredential) async -> Bool {
        let result: Bool
        var isRisk = false
        do {
            try await api.ping(credential: cred)
            appendLog("✅ 测活成功: \(cred.account.nickname)（token 有效）")
            result = true
        } catch {
            // 401 → 尝试刷新后重试一次
            let msg = error.localizedDescription
            if msg.contains("401") {
                appendLog("测活 \(cred.account.nickname) 返回 401，尝试刷新…")
                await refreshCredential(cred)
                if let updated = credentials.first(where: { $0.account.uid == cred.account.uid }) {
                    do {
                        try await api.ping(credential: updated)
                        appendLog("✅ 刷新后测活成功: \(cred.account.nickname)")
                        result = true
                    } catch {
                        appendLog("❌ 刷新后仍失败: \(error.localizedDescription)")
                        result = false
                    }
                } else {
                    result = false
                }
            } else if msg.contains("403") {
                // 403 风控：凭证可能有效但被风控拦截——标记风控
                isRisk = true
                appendLog("⚠️ 测活 403（风控拦截）: \(cred.account.nickname)")
                result = false
            } else {
                appendLog("❌ 测活失败: \(cred.account.nickname) — \(msg)")
                result = false
            }
        }
        // 写回 alive 状态
        if let idx = credentials.firstIndex(where: { $0.account.uid == cred.account.uid }) {
            credentials[idx].alive = result
            credentials[idx].riskControlled = isRisk
            persist()
        }
        return result
    }

    // MARK: - 删除

    func deleteCredential(_ cred: BuddyCredential) {
        credentials.removeAll { $0.account.uid == cred.account.uid }
        persist()
        appendLog("已删除凭证 \(cred.account.nickname)")
    }

    func deleteSession(_ sess: AuthSession) {
        stopPolling(sessionID: sess.id)
        sessions.removeAll { $0.id == sess.id }
        persist()
    }
}
