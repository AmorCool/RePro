import Foundation
import UIKit
import SwiftUI

// MARK: - 已安装应用模型

/// 界面层使用的应用快照。数据全部来自 RPVBridge（Vendor/ReProvision），
/// 这里不再做任何本地持久化，所以不需要 Codable。
struct InstalledApp: Identifiable, Hashable {
    let bundleIdentifier: String
    let displayName: String
    let version: String
    let iconData: Data?
    let certificateExpiryDate: Date?
    let hasEmbeddedProvision: Bool

    /// 是否正在签名（仅 UI 状态，由 SigningViewModel 维护）
    var isSigning: Bool = false
    /// 签名进度 0-100（仅 UI 状态）
    var signingProgress: Int = 0

    /// bundle identifier 在设备上唯一，直接当作 Identifiable 的 id，
    /// 这样列表刷新后 SwiftUI 仍能把同一个应用对上号。
    var id: String { bundleIdentifier }

    var icon: UIImage? {
        guard let data = iconData else { return nil }
        return UIImage(data: data)
    }

    /// 距离证书过期还剩几天；没有到期日时返回 nil
    var daysUntilExpiry: Int? {
        guard let expiry = certificateExpiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiry).day
    }
}

// MARK: - 开发者 Team

/// 登录后 Apple 返回的可选 Team
struct DeveloperTeam: Identifiable, Hashable {
    let teamID: String
    let name: String
    let membership: String?

    var id: String { teamID }
}

// MARK: - 越狱类型

enum JailbreakType: String, CaseIterable {
    case dopamine, roothide, rootful, unknown

    var displayName: String {
        switch self {
        case .dopamine: return "Dopamine (rootless)"
        case .roothide: return "RootHide"
        case .rootful: return "Rootful"
        case .unknown: return "未识别"
        }
    }

    /// 桥接层返回的是字符串标识，这里做一次映射
    init(kind: String?) {
        self = JailbreakType(rawValue: kind ?? "") ?? .unknown
    }
}

// MARK: - 运行环境快照

/// 「状态」页展示的环境体检结果，全部由 RPVBridge 在进程内直接探测得出，
/// 不依赖任何常驻服务。
struct EnvironmentSnapshot {
    let jailbreak: JailbreakType
    let jailbreakRoot: String?
    let zsignPath: String?
    let certificatesBundled: Bool
    let rootHelperAvailable: Bool
    let rootHelperPath: String?
    let signedIn: Bool
    let username: String?
    let teamID: String?
    let deviceUDID: String?
    let sideloadedAppCount: Int
    let nearestExpiryDate: Date?
}

// MARK: - 日志级别

enum LogLevel: String, Codable, CaseIterable {
    case info, warning, error, debug

    var displayName: String {
        switch self {
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        case .debug: return "调试"
        }
    }

    var color: Color {
        switch self {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .debug: return .purple
        }
    }
}

// MARK: - 日志条目

struct LogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String
    let source: String
}

// MARK: - RePro 错误类型

enum ReProError: LocalizedError {
    case notSignedIn
    case busy
    case appNotFound
    case signingFailed(String)
    case installFailed(String)
    case certNotFound
    case profileNotFound
    case zsignNotFound
    case invalidIPA
    case networkTimeout
    case authFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "请先登录 Apple ID"
        case .busy: return "已有签名任务正在进行"
        case .appNotFound: return "找不到该应用"
        case .signingFailed(let reason): return "签名失败: \(reason)"
        case .installFailed(let reason): return "安装失败: \(reason)"
        case .certNotFound: return "未找到有效证书"
        case .profileNotFound: return "未找到匹配的配置描述文件"
        case .zsignNotFound: return "未找到 zsign 二进制文件"
        case .invalidIPA: return "无效的 IPA 文件"
        case .networkTimeout: return "网络超时"
        case .authFailed: return "认证失败，请检查 Apple ID 和密码"
        case .permissionDenied: return "权限不足"
        }
    }
}

// MARK: - 已注册 AppID（来自 Apple Developer API）

struct RegisteredAppID: Identifiable, Hashable {
    let identifier: String          // bundle identifier
    let applicationName: String     // App 名称
    let applicationExpiryDate: Date?

    var id: String { identifier }

    /// 距过期还剩几天；已过期返回负数，无日期返回 nil
    var daysRemaining: Int? {
        guard let expiry = applicationExpiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiry).day
    }

    /// 格式化的剩余时间字符串（与原版 RPVResources.getFormattedTimeRemaining 一致）
    var formattedTimeRemaining: String {
        guard let days = daysRemaining else { return "未知" }
        if days < 0 { return "已过期 \(abs(days)) 天" }
        if days == 0 { return "今天过期" }
        if days <= 30 { return "\(days) 天后过期" }
        // 超过 30 天显示具体日期
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        if let expiry = applicationExpiryDate { return fmt.string(from: expiry) }
        return "未知"
    }

    init(from objC: RPVAppID) {
        self.identifier = objC.identifier ?? ""
        self.applicationName = objC.applicationName ?? identifier
        self.applicationExpiryDate = objC.applicationExpiryDate
    }
}

// MARK: - 开发者证书（来自 Apple certificates API）

struct DevCertificate: Identifiable, Hashable {
    let id: String                 // 证书 ID（用于撤销）
    let serialNumber: String       // 序列号
    let machineName: String        // 设备名
    let applicationName: String    // 来源应用（ReProvision / AltStore / Xcode 等）

    init(from objC: RPVCertificateInfo) {
        self.id = objC.identifier ?? ""
        self.serialNumber = objC.serialNumber ?? ""
        self.machineName = objC.machineName ?? "Unknown"
        self.applicationName = objC.applicationName ?? "Xcode"
    }
}
