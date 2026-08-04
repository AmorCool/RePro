import Foundation
import UIKit
import SwiftUI

// MARK: - 小黑屋来源

/// 应用被拉黑时所属的原始列表，用于在小黑屋里标注它来自哪里。
enum BlacklistSource: String {
    case installed  // ReSign 签应用
    case other      // 其它应用

    var label: String {
        switch self {
        case .installed: return "ReSign"
        case .other: return "其它应用"
        }
    }
}

// MARK: - 已安装应用模型

/// 界面层使用的应用快照。数据全部来自 RPVBridge（Vendor/ReProvision），
/// 这里不再做任何本地持久化，所以不需要 Codable。

/// 应用图标解码缓存（InstalledApp 是 struct，无法在内部缓存可变状态；
/// 用全局 NSCache 以 bundleID 为键缓存解码后的 UIImage，避免列表滚动时
/// 每帧都 UIImage(data:) 重新解码同一份 PNG 数据导致卡顿）
private let iconCache = NSCache<NSString, UIImage>()

struct InstalledApp: Identifiable, Hashable {
    let bundleIdentifier: String
    let displayName: String
    let version: String
    let iconData: Data?
    let certificateExpiryDate: Date?
    let hasEmbeddedProvision: Bool
    /// 原始签名者的 Team ID（「其他应用」中显示，用于区分非当前账户签名的应用）
    let originalTeamID: String?

    /// 在小黑屋列表里标注它来自哪个原始列表（ReSign 签应用 / 其它应用）。
    /// 普通列表里为 nil，被移入小黑屋后才赋值。
    var source: BlacklistSource? = nil

    /// 是否正在签名（仅 UI 状态，由 SigningViewModel 维护）
    var isSigning: Bool = false
    /// 签名进度 0-100（仅 UI 状态）
    var signingProgress: Int = 0

    /// bundle identifier 在设备上唯一，直接当作 Identifiable 的 id，
    /// 这样列表刷新后 SwiftUI 仍能把同一个应用对上号。
    var id: String { bundleIdentifier }

    /// 解码后的图标（带全局 NSCache：避免列表滚动时每帧都 UIImage(data:) 重新解码 PNG）
    /// SwiftUI 的 List 在滚动时会反复调用此属性，不缓存会导致明显卡顿。
    var icon: UIImage? {
        if let cached = iconCache.object(forKey: bundleIdentifier as NSString) { return cached }
        guard let data = iconData else { return nil }
        guard let decoded = UIImage(data: data) else { return nil }
        iconCache.setObject(decoded, forKey: bundleIdentifier as NSString)
        return decoded
    }

    /// 距离证书过期还剩几天；没有到期日时返回 nil
    var daysUntilExpiry: Int? {
        guard let expiry = certificateExpiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiry).day
    }

    /// 小黑屋来源标签：ReSign 签应用 / 其它应用 / 未知
    var sourceLabel: String {
        source?.label ?? "未知"
    }

    // MARK: 签名来源判定（证书 vs Apple ID）

    /// 签名来源：证书签（一年期）、Apple ID 免费签（7 天）、未知。
    /// 依据 embedded.mobileprovision 的 ExpirationDate 距今天数判定：
    /// Apple ID 免费签仅 7 天，证书签约 365 天，故阈值取 30 天——
    /// 还差 30 天以上才到期的基本可确定是证书，30 天以内的基本是 Apple ID 免费签。
    enum SigningSource {
        case cert     // 证书签（一年期）
        case appleID  // Apple ID 免费签（7 天）
        case unknown  // 无到期信息
    }

    var signingSource: SigningSource {
        guard let expiry = certificateExpiryDate else { return .unknown }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
        return days < 30 ? .appleID : .cert
    }

    /// 签名来源标签：证书 / Apple ID / 未知
    var signingSourceLabel: String {
        switch signingSource {
        case .cert: return "证书"
        case .appleID: return "Apple ID"
        case .unknown: return "未知"
        }
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

// MARK: - ReSign 错误类型

enum ReSignError: LocalizedError {
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

    /// 静态 formatter 复用（超过 30 天显示具体日期用；避免每次调用都创建 DateFormatter）
    private static let mediumFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var id: String { identifier }

    /// 距过期还剩几天；已过期返回负数，无日期返回 nil
    var daysRemaining: Int? {
        guard let expiry = applicationExpiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiry).day
    }

    /// 详细剩余时间（X天X小时X分钟），与原版 ReProvision 一致
    var detailedTimeRemaining: String {
        guard let expiry = applicationExpiryDate else { return "到期时间未知" }
        let now = Date()
        if expiry <= now {
            // 已过期 —— 显示过了多久
            let components = Calendar.current.dateComponents([.day, .hour, .minute], from: expiry, to: now)
            if let d = components.day, d > 0 {
                return "已过期 \(d) 天"
            } else if let h = components.hour, h > 0 {
                return "已过期 \(h) 小时"
            } else {
                return "已过期"
            }
        }

        // 未过期 —— 精确到天/小时/分钟
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: expiry)
        var parts: [String] = []
        if let d = components.day, d > 0 {
            parts.append("\(d)天")
        }
        if let h = components.hour, h > 0 {
            parts.append("\(h)小时")
        }
        if let m = components.minute, m > 0, parts.isEmpty {
            // 只在不足 1 小时时显示分钟
            parts.append("\(m)分钟")
        }
        if parts.isEmpty {
            return "即将过期"
        }
        return parts.joined() + "后过期"
    }

    /// 格式化的剩余时间字符串（与原版 RPVResources.getFormattedTimeRemaining 一致）
    var formattedTimeRemaining: String {
        guard let days = daysRemaining else { return "未知" }
        if days < 0 { return "已过期 \(abs(days)) 天" }
        if days == 0 { return "今天过期" }
        if days <= 30 { return "\(days) 天后过期" }
        // 超过 30 天显示具体日期（静态 formatter 复用，见类型级 mediumFmt）
        if let expiry = applicationExpiryDate { return RegisteredAppID.mediumFmt.string(from: expiry) }
        return "未知"
    }

    init(from objC: RPVRegisteredAppID) {
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
    let machineId: String          // 机器标识（与本机 uuid 比对可判定是否本机证书）
    let applicationName: String    // 来源应用（ReProvision / AltStore / Xcode 等）

    init(from objC: RPVCertificateInfo) {
        self.id = objC.identifier ?? ""
        self.serialNumber = objC.serialNumber ?? ""
        self.machineName = objC.machineName ?? "Unknown"
        self.machineId = objC.machineId ?? ""
        self.applicationName = objC.applicationName ?? "Xcode"
    }
}
