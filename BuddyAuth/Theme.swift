//
//  Theme.swift
//  BuddyAuth — 设计系统（品牌色 / 渐变 / 卡片 / 徽章）
//

import SwiftUI

// MARK: - 品牌色（绿色系）

enum Theme {
    /// 主品牌色（翠绿）
    static let brand = Color(red: 0.06, green: 0.72, blue: 0.51)
    /// 次品牌色（薄荷绿）
    static let brandPurple = Color(red: 0.20, green: 0.91, blue: 0.62)
    /// 品牌渐变
    static let brandGradient = LinearGradient(
        colors: [brand, brandPurple],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    /// 成功绿
    static let success = Color(red: 0.06, green: 0.72, blue: 0.51)
    /// 警告橙
    static let warning = Color(red: 0.95, green: 0.60, blue: 0.20)
    /// 危险红
    static let danger = Color(red: 0.92, green: 0.34, blue: 0.34)

    /// 卡片背景（浅色/深色自适应）
    static var cardBackground: Color {
        Color(.secondarySystemBackground)
    }

    /// 卡片圆角
    static let cornerRadius: CGFloat = 16
}

// MARK: - 品牌渐变按钮

struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.brandGradient)
                    .shadow(color: Theme.brand.opacity(0.35), radius: 8, y: 4)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - 玻璃态卡片

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5
                    )
            )
    }
}

// MARK: - 状态徽章（升级版：渐变底 + 图标）

struct StatusBadge: View {
    let status: AuthSession.SessionStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(color.opacity(0.15))
        )
        .foregroundColor(color)
        .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 0.5))
    }

    private var label: String {
        switch status {
        case .pending: return "待登录"
        case .polling: return "轮询中"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    private var icon: String {
        switch status {
        case .pending: return "clock"
        case .polling: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark"
        case .failed: return "xmark"
        }
    }

    private var color: Color {
        switch status {
        case .pending: return Theme.warning
        case .polling: return Theme.brand
        case .completed: return Theme.success
        case .failed: return Theme.danger
        }
    }
}

// MARK: - 凭证有效期徽章

struct ExpiryBadge: View {
    let expiresAt: Int64

    var body: some View {
        let remaining = expiresAt - Int64(Date().timeIntervalSince1970)
        let color: Color = remaining < 86400 * 7 ? Theme.danger
            : remaining < 86400 * 30 ? Theme.warning : Theme.success
        HStack(spacing: 3) {
            Image(systemName: "timer")
                .font(.system(size: 9))
            Text(expiryText)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.13)))
        .foregroundColor(color)
    }

    private var expiryText: String {
        let d = Date(timeIntervalSince1970: TimeInterval(expiresAt))
        return "剩 " + d.formatted(.relative(presentation: .numeric))
    }
}

// MARK: - 空状态视图

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.brand.opacity(0.1))
                    .frame(width: 76, height: 76)
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundColor(Theme.brand)
            }
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 仪表卡片（凭证详情用）

struct MetricCard: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.brand)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
