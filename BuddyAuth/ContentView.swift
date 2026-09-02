//
//  ContentView.swift
//  BuddyAuth — 主界面
//

import SwiftUI
import UIKit
import WebKit

struct ContentView: View {
    @StateObject private var store = CredentialStore.shared
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            SessionsView(store: store)
                .tabItem { Label("授权", systemImage: "link.badge.plus") }
                .tag(0)

            CredentialsView(store: store)
                .tabItem { Label("凭证", systemImage: "key.fill") }
                .tag(1)

            LogView(store: store)
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }
                .tag(2)

            ProxySettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .tint(Theme.brand)
        .onAppear {
            store.refreshAllIfNeeded()
        }
    }
}

// MARK: - 授权会话列表

struct SessionsView: View {
    @ObservedObject var store: CredentialStore
    @State private var selectedRegion: BuddyAPI.Region = .cn
    @State private var creating = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 顶部品牌卡
                    headerCard

                    // 创建授权卡
                    createCard

                    // 会话列表
                    sessionsSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("授权")
            .navigationDestination(for: AuthSession.self) { sess in
                SessionDetailView(store: store, session: sess)
            }
        }
    }

    // MARK: 顶部品牌卡

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("WorkBuddy 授权管理")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("OAuth 设备流 · 无痕登录 · 自动入库")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.85))
                }
                Spacer()
            }
            Text("创建授权链接 → 内置无痕浏览器登录 → 凭证自动入库并持续轮询监听")
                .font(.caption)
                .foregroundColor(.white.opacity(0.92))
                .padding(.top, 2)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.brandGradient)
                .shadow(color: Theme.brand.opacity(0.35), radius: 12, y: 6)
        )
        .padding(.top, 8)
    }

    // MARK: 创建授权卡

    private var createCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("区域")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("区域", selection: $selectedRegion) {
                    ForEach(BuddyAPI.Region.allCases) { r in
                        Text(r.name).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }

            Button {
                creating = true
                Task {
                    await store.createAuthSession()
                    creating = false
                }
            } label: {
                HStack(spacing: 8) {
                    if creating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "plus.circle.fill")
                    }
                    Text(creating ? "正在创建…" : "创建授权链接")
                }
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(creating)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: 会话列表

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("授权会话")
                .font(.headline)
                .padding(.leading, 4)

            if store.sessions.isEmpty {
                GlassCard {
                    EmptyStateView(
                        icon: "link.badge.plus",
                        title: "还没有授权会话",
                        subtitle: "点击上方「创建授权链接」开始\n登录后会在这里看到会话状态"
                    )
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(store.sessions) { sess in
                        NavigationLink(value: sess) {
                            SessionRow(sess: sess)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.deleteSession(sess)
                            } label: {
                                Label("删除会话", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 会话卡片

struct SessionRow: View {
    let sess: AuthSession

    var body: some View {
        HStack(spacing: 12) {
            // 状态图标
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(statusColor.opacity(0.13))
                    .frame(width: 42, height: 42)
                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(sess.platform)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    if sess.accountUid != nil {
                        Text("已登录")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.success.opacity(0.15)))
                            .foregroundColor(Theme.success)
                    }
                    Spacer(minLength: 4)
                    StatusBadge(status: sess.status)
                }
                Text("state: \(sess.state.prefix(10))…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(sess.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        )
    }

    private var statusColor: Color {
        switch sess.status {
        case .pending: return Theme.warning
        case .polling: return Theme.brand
        case .completed: return Theme.success
        case .failed: return Theme.danger
        }
    }

    private var statusIcon: String {
        switch sess.status {
        case .pending: return "clock"
        case .polling: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark"
        case .failed: return "xmark"
        }
    }
}
// MARK: - 会话详情（内置浏览器）

struct SessionDetailView: View {
    @ObservedObject var store: CredentialStore
    let session: AuthSession

    @State private var webTitle: String = ""
    @State private var currentURL: URL?
    @State private var showClearAlert = false
    @State private var showClearedAlert = false
    @State private var didAutoWipe = false
    @State private var webViewRef: WKWebView?
    @ObservedObject private var smsStore = SmsStore.shared

    /// 清除后跳转验证页（百度，验证代理出口）
    private var verifyURL: URL? { URL(string: "https://www.baidu.com") }

    var body: some View {
        VStack(spacing: 0) {
            // 状态条
            HStack {
                StatusBadge(status: currentStatus)
                Spacer()
                if currentStatus == .completed {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                        Text("凭证已入库")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.success)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.success.opacity(0.12)))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(
                LinearGradient(colors: [
                    Theme.brand.opacity(0.08),
                    Theme.brandPurple.opacity(0.05)
                ], startPoint: .leading, endPoint: .trailing)
            )

            Divider()

            // 内置无痕浏览器
            if let url = URL(string: session.authUrl) {
                IncognitoWebView(
                    url: url,
                    onTitleChange: { t in webTitle = t },
                    onNavigationChange: { u in currentURL = u },
                    onWebViewCreated: { wv in
                        webViewRef = wv
                        // 接码自动填充绑定
                        smsStore.loginWebView = wv
                    }
                )
                .id(session.id)  // 每次进入重新加载
                .overlay(alignment: .topTrailing) {
                    VStack {
                        // 刷新按钮（重新加载页面）
                        Button {
                            webViewRef?.reload()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                        }
                        .padding(.bottom, 6)
                        // 手动清除按钮（保留，美化）
                        Button {
                            showClearAlert = true
                        } label: {
                            Label("清除数据", systemImage: "trash")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                        }
                        .padding(8)
                        Spacer()
                    }
                }
                // 登录成功后自动全量清除（一次性）+ 跳转百度
                .onChange(of: currentStatus) { newStatus in
                    if newStatus == .completed && !didAutoWipe {
                        didAutoWipe = true
                        autoWipeAfterLogin()
                    }
                }
            } else {
                Text("无效的授权链接")
            }

            // 接码快捷栏（浏览器登录时取号/取码）
            SmsBar(store: smsStore)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))

            Divider()

            // 底部信息
            VStack(alignment: .leading, spacing: 4) {
                Text("页面标题：\(webTitle.isEmpty ? "-" : webTitle)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text("当前地址：\(currentURL?.absoluteString ?? session.authUrl)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
        }
        .navigationTitle("授权会话")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清除浏览器数据", isPresented: $showClearAlert) {
            Button("清除", role: .destructive) {
                IncognitoWebView.wipeAll(webView: webViewRef, redirectTo: verifyURL) {
                    showClearedAlert = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除全部 Cookies、本地存储、IndexedDB、缓存、ServiceWorker 等所有网站数据，并跳转百度验证代理出口")
        }
        .alert("删除成功", isPresented: $showClearedAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("已全量清除浏览器所有数据（Cookies / 本地存储 / IndexedDB / 缓存 / ServiceWorker），已跳转百度")
        }
        .onAppear {
            // 确保轮询在进入详情页时已启动
            if session.status == .pending || session.status == .polling {
                store.startPolling(sessionID: session.id)
            }
        }
    }

    /// 登录成功后自动全量清除浏览器数据 + 跳转百度 + 提示
    private func autoWipeAfterLogin() {
        IncognitoWebView.wipeAll(webView: webViewRef, redirectTo: verifyURL) {
            showClearedAlert = true
        }
        store.appendLog("✅ 登录成功，浏览器数据已自动全量清除，已跳转百度")
    }

    private var currentStatus: AuthSession.SessionStatus {
        store.sessions.first(where: { $0.id == session.id })?.status ?? session.status
    }
}

// MARK: - 凭证筛选

enum CredFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case ok = "有效"
    case risk = "风控"
    case dead = "失效"
    case untested = "未测"

    var id: String { rawValue }

    /// 筛选匹配
    func matches(_ cred: BuddyCredential) -> Bool {
        switch self {
        case .all: return true
        case .ok: return cred.alive == true && cred.riskControlled != true
        case .risk: return cred.riskControlled == true
        case .dead: return cred.alive == false && cred.riskControlled != true
        case .untested: return cred.alive == nil
        }
    }
}

// MARK: - 凭证列表

struct CredentialsView: View {
    @ObservedObject var store: CredentialStore
    @State private var refreshSpinning = false
    @State private var pushSpinning = false
    @State private var pushResult: String?
    @State private var pushDetail: String?
    @State private var pushSingleResult: String?
    @State private var pingAllSpinning = false
    @State private var pingAllResult: String?
    @State private var filter: CredFilter = .all
    @State private var noteTarget: BuddyCredential?
    @State private var noteText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 刷新卡
                    refreshCard

                    // 批量测活卡
                    pingAllCard

                    // 推送卡
                    pushCard

                    // 推送失败详情（可复制）
                    if let d = pushDetail, !d.isEmpty {
                        pushErrorDetail
                    }

                    // 单个推送结果提示
                    if let r = pushSingleResult {
                        HStack(spacing: 6) {
                            Image(systemName: r.hasPrefix("✅") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(r.hasPrefix("✅") ? Theme.success : Theme.danger)
                            Text(r)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill((r.hasPrefix("✅") ? Theme.success : Theme.danger).opacity(0.08))
                        )
                    }

                    // 凭证卡片列表
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("已入库凭证")
                                .font(.headline)
                            Spacer()
                            // 状态筛选
                            Picker("筛选", selection: $filter) {
                                ForEach(CredFilter.allCases) { f in
                                    Text(f.rawValue).tag(f)
                                }
                            }
                            .pickerStyle(.menu)
                            .font(.caption)
                        }
                        // 筛选结果数
                        Text("\(store.sortedCredentials.filter { filter.matches($0) }.count) 个")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        .padding(.leading, 4)

                        if store.credentials.isEmpty {
                            GlassCard {
                                EmptyStateView(
                                    icon: "key.slash",
                                    title: "暂无凭证",
                                    subtitle: "先在「授权」页创建链接并完成登录\n凭证会自动入库"
                                )
                            }
                        } else {
                            let filtered = store.sortedCredentials.filter { filter.matches($0) }
                            if filtered.isEmpty {
                                GlassCard {
                                    EmptyStateView(
                                        icon: "line.3.horizontal.decrease.circle",
                                        title: "无匹配凭证",
                                        subtitle: "当前筛选「\(filter.rawValue)」下没有凭证\n可切换筛选或先批量测活"
                                    )
                                }
                            } else {
                                VStack(spacing: 10) {
                                    ForEach(filtered) { cred in
                                        NavigationLink(value: cred) {
                                            CredentialRow(cred: cred)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            // 推送单个到服务器
                                            Button {
                                                Task {
                                                    pushSingleResult = "推送中…"
                                                    do {
                                                        let (uid, nick) = try await store.pushCredential(cred)
                                                        pushSingleResult = "✅ 已推送 \(nick.isEmpty ? uid : nick)"
                                                    } catch {
                                                        pushSingleResult = "❌ 推送失败: \(error.localizedDescription)"
                                                    }
                                                }
                                            } label: {
                                                Label("推送到服务器", systemImage: "paperplane")
                                            }
                                            // 标注
                                            Button {
                                                noteTarget = cred
                                            } label: {
                                                Label("标注", systemImage: "tag")
                                            }
                                            // 删除
                                            Button(role: .destructive) {
                                                store.deleteCredential(cred)
                                            } label: {
                                                Label("删除", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("凭证")
            .navigationDestination(for: BuddyCredential.self) { cred in
                CredentialDetailView(store: store, cred: cred)
            }
            .alert("标注凭证", isPresented: Binding(
                get: { noteTarget != nil },
                set: { if !$0 { noteTarget = nil } }
            )) {
                TextField("备注（如：买的号1）", text: $noteText)
                Button("保存") {
                    if let t = noteTarget {
                        store.setNote(uid: t.account.uid, note: noteText)
                    }
                    noteTarget = nil
                }
                Button("清除标注", role: .destructive) {
                    if let t = noteTarget {
                        store.setNote(uid: t.account.uid, note: "")
                    }
                    noteTarget = nil
                }
                Button("取消", role: .cancel) {
                    noteTarget = nil
                }
            } message: {
                Text("标注后列表优先展示该凭证")
            }
        }
    }

    private var refreshCard: some View {
        Button {
            Task {
                refreshSpinning = true
                store.refreshAllIfNeeded(within: 0)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refreshSpinning = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(refreshSpinning ? 360 : 0))
                    .animation(refreshSpinning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: refreshSpinning)
                Text(refreshSpinning ? "刷新中…" : "立即刷新全部 Token")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .opacity(0.4)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Theme.brand)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.brand.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.brand.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    /// 批量测活卡
    private var pingAllCard: some View {
        Button {
            Task {
                pingAllSpinning = true
                pingAllResult = nil
                let (ok, risk, dead) = await store.pingAllCredentials()
                pingAllSpinning = false
                pingAllResult = "✅ 有效 \(ok) · ⚠️ 风控 \(risk) · ❌ 失效 \(dead)"
            }
        } label: {
            HStack(spacing: 8) {
                if pingAllSpinning {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(Theme.warning)
                } else {
                    Image(systemName: "stethoscope")
                }
                Text(pingAllSpinning ? "测活中…" : "批量测活全部凭证")
                Spacer()
                if let r = pingAllResult, !pingAllSpinning {
                    Text(r)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else if !pingAllSpinning {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .opacity(0.4)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Theme.warning)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.warning.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.warning.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.credentials.isEmpty)
        .opacity(store.credentials.isEmpty ? 0.5 : 1)
    }

    /// 推送卡（一键入库到 Buddy2API 服务器）
    private var pushCard: some View {
        Button {
            Task {
                pushSpinning = true
                pushResult = "推送中…"
                pushDetail = nil
                let (ok, failed) = await store.pushAllCredentials()
                pushSpinning = false
                if failed.isEmpty {
                    pushResult = "✅ 成功 \(ok) 个"
                } else {
                    pushResult = "✅ 成功 \(ok) 个 · ❌ 失败 \(failed.count) 个"
                    pushDetail = failed.joined(separator: "\n")
                }
            }
        } label: {
            HStack(spacing: 8) {
                if pushSpinning {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(Theme.success)
                } else {
                    Image(systemName: "paperplane.fill")
                }
                Text(pushSpinning ? "推送中…" : "推送全部凭证到服务器")
                Spacer()
                if let r = pushResult, !pushSpinning {
                    Text(r)
                        .font(.caption)
                        .foregroundColor(r.hasPrefix("✅") ? Theme.success : Theme.warning)
                        .lineLimit(1)
                } else if !pushSpinning {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .opacity(0.4)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Theme.success)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.success.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.success.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!PushStore.shared.configured || store.credentials.isEmpty)
        .opacity((!PushStore.shared.configured || store.credentials.isEmpty) ? 0.5 : 1)
    }

    /// 推送失败详情条（可复制）
    private var pushErrorDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("推送失败详情", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.danger)
                Spacer()
                Button {
                    UIPasteboard.general.string = pushDetail ?? ""
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.danger.opacity(0.1)))
                        .foregroundColor(Theme.danger)
                }
                .buttonStyle(.plain)
            }
            Text(pushDetail ?? "")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.danger.opacity(0.06))
        )
    }
}

struct CredentialRow: View {
    let cred: BuddyCredential

    var body: some View {
        HStack(spacing: 12) {
            // 头像（首字母）
            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 42, height: 42)
                Text(initial)
                    .font(.headline)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                // 标题：标注优先 + 括号手机号
                HStack(spacing: 5) {
                    Text(cred.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !cred.subInfo.isEmpty {
                        Text(cred.subInfo)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    // 风控徽章（优先显示）
                    if cred.riskControlled == true {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                            Text("风控")
                                .font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.warning.opacity(0.15)))
                        .foregroundColor(Theme.warning)
                    } else if let alive = cred.alive {
                        // 测活状态徽章
                        HStack(spacing: 3) {
                            Image(systemName: alive ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 9))
                            Text(alive ? "有效" : "失效")
                                .font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((alive ? Theme.success : Theme.danger).opacity(0.13)))
                        .foregroundColor(alive ? Theme.success : Theme.danger)
                    }
                    ExpiryBadge(expiresAt: cred.auth.expiresAt)
                }

                // 余额 + 入库时间
                HStack(spacing: 10) {
                    // 余额徽章
                    if cred.balance >= 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "creditcard.fill")
                                .font(.system(size: 9))
                            Text("\(cred.balance) 积分")
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.success.opacity(0.12)))
                        .foregroundColor(Theme.success)
                    }
                    // 入库时间
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(savedAtText)
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }

                // 域名
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.system(size: 9))
                    Text(cred.auth.domain)
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        )
    }

    private var initial: String {
        let n = cred.displayName
        if n.isEmpty { return String(cred.account.uid.prefix(1)).uppercased() }
        return String(n.prefix(1)).uppercased()
    }

    /// 入库时间（具体时间）
    private var savedAtText: String {
        if cred.savedAt <= 0 { return "时间未知" }
        return Date(timeIntervalSince1970: TimeInterval(cred.savedAt)).formatted(date: .numeric, time: .shortened)
    }
}

// MARK: - 凭证详情（单独复制 + 导出）

struct CredentialDetailView: View {
    @ObservedObject var store: CredentialStore
    let cred: BuddyCredential

    @State private var copiedField = ""
    @State private var showDeleteConfirm = false
    @State private var pingResult: String?
    @State private var balanceResult: String?
    @State private var balancePackages: [BuddyAPI.ResourcePackage] = []
    @State private var pushDetailResult: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 账号头像卡
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 72, height: 72)
                        Text(cred.account.nickname.isEmpty ? String(cred.account.uid.prefix(1)).uppercased() : String(cred.account.nickname.prefix(1)).uppercased())
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Text(cred.account.nickname.isEmpty ? cred.account.uid : cred.account.nickname)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 11))
                        Text(cred.auth.domain)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .padding(.top, 8)

                // 账号信息卡
                VStack(alignment: .leading, spacing: 10) {
                    Text("账号信息")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        MetricCard(icon: "person.crop.circle", label: "UID", value: cred.account.uid)
                        MetricCard(icon: "calendar", label: "过期时间", value: expiryShort)
                        if !cred.account.enterpriseId.isEmpty {
                            MetricCard(icon: "building.2", label: "Enterprise", value: cred.account.enterpriseId)
                        }
                        MetricCard(icon: "globe", label: "区域", value: cred.auth.domain)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )

                // 凭证卡（可复制）
                VStack(alignment: .leading, spacing: 10) {
                    Text("凭证（点击复制）")
                        .font(.headline)
                    copyCard("Access Token", cred.auth.accessToken)
                    copyCard("Refresh Token", cred.auth.refreshToken)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )

                // 操作卡
                VStack(spacing: 10) {
                    // 测活
                    Button {
                        Task {
                            pingResult = "检测中…"
                            let ok = await store.pingCredential(cred)
                            pingResult = ok ? "✅ 凭证有效" : "❌ 凭证失效"
                        }
                    } label: {
                        HStack {
                            Image(systemName: "stethoscope")
                            Text("测活（验证 Token 有效）")
                            Spacer()
                            if let r = pingResult {
                                Text(r)
                                    .font(.caption)
                                    .foregroundColor(r.hasPrefix("✅") ? Theme.success : Theme.danger)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .opacity(0.4)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.brand)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.brand.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)

                    // 余额查询
                    Button {
                        Task {
                            balanceResult = "查询中…"
                            let (total, pkgs) = await store.queryResource(cred)
                            if pkgs.isEmpty {
                                balanceResult = "未查询到套餐（或已过期）"
                            } else {
                                balanceResult = "💰 剩余 \(total) 积分 · \(pkgs.count) 个套餐"
                                balancePackages = pkgs
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "creditcard.fill")
                            Text("余额查询（套餐）")
                            Spacer()
                            if let b = balanceResult {
                                Text(b)
                                    .font(.caption)
                                    .foregroundColor(b.contains("💰") ? Theme.success : (b == "查询中…" ? Theme.warning : Theme.danger))
                                    .lineLimit(1)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .opacity(0.4)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.success)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.success.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)

                    // 套餐明细（查询后展开）
                    if !balancePackages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(balancePackages.enumerated()), id: \.offset) { _, pkg in
                                packageRow(pkg)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.tertiarySystemGroupedBackground))
                        )
                    }

                    // 推送到服务器
                    Button {
                        Task {
                            pushDetailResult = "推送中…"
                            do {
                                let (uid, nick) = try await store.pushCredential(cred)
                                pushDetailResult = "✅ 已推送 \(nick.isEmpty ? uid : nick)"
                            } catch {
                                pushDetailResult = "❌ 推送失败: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "paperplane.fill")
                            Text("推送到服务器")
                            Spacer()
                            if let r = pushDetailResult {
                                Text(r)
                                    .font(.caption)
                                    .foregroundColor(r.hasPrefix("✅") ? Theme.success : Theme.danger)
                                    .lineLimit(1)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .opacity(0.4)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.success)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.success.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!PushStore.shared.configured)

                    // 导出
                    Button {
                        shareCredential()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("导出凭证（JSON 分享）")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .opacity(0.4)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.brand)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.brand.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)

                    // 删除
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("删除凭证")
                            Spacer()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.danger)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.danger.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("凭证详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除凭证「\(cred.account.nickname)」？此操作不可恢复", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.deleteCredential(cred)
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var expiryShort: String {
        Date(timeIntervalSince1970: TimeInterval(cred.auth.expiresAt)).formatted(date: .numeric, time: .shortened)
    }

    /// 可复制凭证卡（点击复制 + 反馈）
    private func copyCard(_ label: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copiedField = label
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copiedField = ""
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(value)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.primary)
                }
                Spacer()
                ZStack {
                    Circle()
                        .fill(copiedField == label ? Theme.success.opacity(0.15) : Theme.brand.opacity(0.1))
                        .frame(width: 30, height: 30)
                    Image(systemName: copiedField == label ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(copiedField == label ? Theme.success : Theme.brand)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    /// 套餐明细行（进度条 + 剩余/已用）
    private func packageRow(_ pkg: BuddyAPI.ResourcePackage) -> some View {
        // 优先用周期额度；周期为 0 时回退总额度
        let hasCycle = pkg.cycleSize > 0 || pkg.cycleUsed > 0 || pkg.cycleRemain > 0
        let total = max(hasCycle ? pkg.cycleSize : pkg.capacitySize, 1)
        let remain = max(hasCycle ? pkg.cycleRemain : pkg.capacityRemain, 0)
        let used = max(hasCycle ? pkg.cycleUsed : pkg.capacityUsed, 0)
        let ratio = Double(used) / Double(total)
        let color: Color = ratio > 0.85 ? Theme.danger : (ratio > 0.6 ? Theme.warning : Theme.success)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(pkg.packageName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("剩余 \(remain)")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(color)
            }
            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(ratio, 1)))
                }
            }
            .frame(height: 6)
            HStack {
                Text("已用 \(used)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("总额 \(total)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            // 周期额度信息（与总额度不同时展示）
            if hasCycle && pkg.capacitySize != pkg.cycleSize {
                Text("周期内 \(pkg.cycleRemain)/\(pkg.cycleSize) · 总 \(pkg.capacityRemain)/\(pkg.capacitySize)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 导出：JSON 分享（UIActivityViewController）
    private func shareCredential() {
        let doc: [String: Any] = [
            "account": [
                "uid": cred.account.uid,
                "enterpriseId": cred.account.enterpriseId,
                "nickname": cred.account.nickname,
            ],
            "auth": [
                "accessToken": cred.auth.accessToken,
                "refreshToken": cred.auth.refreshToken,
                "expiresAt": cred.auth.expiresAt,
                "domain": cred.auth.domain,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return }

        let filename = "workbuddy-\(cred.account.uid).json"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? str.write(to: tmp, atomically: true, encoding: .utf8)

        let avc = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
        avc.popoverPresentationController?.sourceView = nil
        // 从 root VC present（处理嵌套 presented VC）
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            var presenter = root
            while let top = presenter.presentedViewController { presenter = top }
            presenter.present(avc, animated: true)
        }
    }
}

// MARK: - 日志

struct LogView: View {
    @ObservedObject var store: CredentialStore
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // 操作条
                    HStack {
                        Label("操作日志", systemImage: "list.bullet.rectangle")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            UIPasteboard.general.string = store.log
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Theme.brand.opacity(0.1)))
                                .foregroundColor(copied ? Theme.success : Theme.brand)
                        }
                        Button {
                            store.log = ""
                        } label: {
                            Label("清空", systemImage: "trash")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Theme.danger.opacity(0.1)))
                                .foregroundColor(Theme.danger)
                        }
                    }
                    .padding(.top, 8)

                    // 日志内容
                    GlassCard(padding: 12) {
                        if store.log.isEmpty {
                            Text("暂无日志")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 40)
                        } else {
                            Text(store.log)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("日志")
        }
    }
}

#Preview {
    ContentView()
}

// MARK: - 代理设置

struct ProxySettingsView: View {
    @ObservedObject private var sms = SmsStore.shared
    @ObservedObject private var push = PushStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 接码设置卡
                    smsSettingsCard

                    // 服务器推送设置卡
                    pushSettingsCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("设置")
        }
    }

    /// 接码设置
    private var smsSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("接码设置", systemImage: "iphone.badge.plus")
                    .font(.headline)
                Spacer()
                Text(sms.provider.name)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // 接码方式二选一
            Picker("接码方式", selection: $sms.provider) {
                ForEach(SmsStore.SmsProvider.allCases) { p in
                    Text(p.name).tag(p)
                }
            }
            .pickerStyle(.segmented)

            // ejiema：Token 输入
            if sms.provider == .ejiema {
                SecureField("ejiema API Token", text: $sms.token)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
            } else {
                // workbuddy：卡密 + 网址
                SecureField("workbuddy 卡密", text: $sms.cardKey)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
                Text("浏览器快捷栏输入接码网址，自动取号/取码/填号/登录")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // 余额 + 刷新（ejiema 模式）
            if sms.provider == .ejiema {
                HStack {
                    Label("余额", systemImage: "creditcard.fill")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(sms.balance)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(sms.balance == "—" || sms.balance == "查询失败" ? .secondary : Theme.success)
                    if !sms.balanceUpdatedAt.isEmpty && sms.balance != "查询失败" {
                        Text("(\(sms.balanceUpdatedAt))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Button {
                        Task { await sms.queryBalance() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Theme.brand.opacity(0.1)))
                            .foregroundColor(Theme.brand)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
            }

            // ejiema：关键词 + 卡类型
            if sms.provider == .ejiema {
                TextField("短信关键词（默认：腾讯）", text: $sms.keyword)
                    .font(.subheadline)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
                HStack {
                    Text("卡类型").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    Picker("卡类型", selection: $sms.cardType) {
                        ForEach(["全部", "实卡", "虚卡"], id: \.self) { c in Text(c).tag(c) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .padding(.top, 8)
    }

    /// 服务器推送设置
    private var pushSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("服务器推送", systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                Text("Buddy2API").font(.caption2).foregroundColor(.secondary)
            }
            TextField("服务器地址（如 http://YOUR_SERVER_IP:10082）", text: $push.baseURL)
                .font(.system(.subheadline, design: .monospaced))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
            SecureField("管理密码", text: $push.password)
                .font(.system(.subheadline, design: .monospaced))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
            Text("在「凭证」页点击推送，把本地凭证一键入库到 Buddy2API 服务器")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

