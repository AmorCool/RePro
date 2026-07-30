import Foundation
import UIKit

// MARK: - 已安装应用模型

struct InstalledApp: Identifiable, Codable, Hashable {
    let id: UUID
    let bundleIdentifier: String
    let displayName: String
    let version: String
    let iconData: Data?
    let certificateExpiryDate: Date?
    var isSigning: Bool = false

    var icon: UIImage? {
        guard let data = iconData else { return nil }
        return UIImage(data: data)
    }

    var daysUntilExpiry: Int {
        guard let expiry = certificateExpiryDate else { return -999 }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? -999
    }
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

struct LogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String
    let source: String
}

// MARK: - 越狱类型

enum JailbreakType: String, CaseIterable {
    case dopamine, roothide, rootful, unknown

    var displayName: String {
        switch self {
        case .dopamine: return "Dopamine"
        case .roothide: return "RootHide"
        case .rootful: return "Rootful"
        case .unknown: return "未知"
        }
    }
}

// MARK: - 守护进程健康状态

struct DaemonHealthStatus: Codable {
    let daemonRunning: Bool
    let hasRootPrivileges: Bool
    let isSandboxed: Bool
    let zsignPath: String?
    let lastResignTime: Date?
    let validTokenCount: Int
    let anisetteReady: Bool
    let jailbreakType: JailbreakType
    let uptimeSeconds: TimeInterval?
}

// MARK: - 签名结果

enum SigningResult {
    case success(installedApp: InstalledApp)
    case failure(error: Error)
}

// MARK: - RePro 错误类型

enum ReProError: LocalizedError {
    case daemonNotRunning
    case daemonConnectionFailed(String)
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
        case .daemonNotRunning: return "守护进程未运行"
        case .daemonConnectionFailed(let reason): return "无法连接守护进程: \(reason)"
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
