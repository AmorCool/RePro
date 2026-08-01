import Foundation
import os.log

// MARK: - 统一日志管理器（参考 SideStore 日志系统）

class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published private(set) var logs: [LogEntry] = []
    private let maxLogEntries = 5000
    private let queue = DispatchQueue(label: "com.reprovision.logmanager", qos: .utility)

    private init() {}

    // MARK: daemon 日志转发
    /// 设为非 nil 时，所有日志同时追加写入该文件（实时，一行一条）。
    /// 用于自动续签期间把详尽日志写入 reprorefresh_at.log。
    var daemonLogPath: String? {
        didSet {
            if let path = daemonLogPath, !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
                chmod(path, 0o644)
            }
        }
    }

    // MARK: 初始化
    func initialize() {
        loadFromDisk()

        // 接收 Vendor 业务层（RPVApplicationSigning / RPVBridge / repro-helper 经 RPVBridge
        // 转发）发来的诊断，使其出现在 App「日志」页，用户可在重签后导出发给开发者。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDiagnostic(_:)),
            name: Notification.Name("com.reprovision.diagnostic"),
            object: nil
        )
    }

    /// Vendor 层通过 RPVDiagnostic 转发的诊断（见 RPVDiagnostics.h）。
    @objc private func handleDiagnostic(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let message = userInfo["message"] as? String else { return }
        let source = (userInfo["source"] as? String) ?? "Vendor"
        let levelInt = (userInfo["level"] as? Int) ?? 0
        switch levelInt {
        case 1: warning(message, source: source)
        case 2: error(message, source: source)
        case 3:
            #if DEBUG
            debug(message, source: source)
            #else
            info(message, source: source)
            #endif
        default: info(message, source: source)
        }
    }

    // MARK: 写入日志
    func info(_ message: String, source: String = "General") {
        append(level: .info, message: message, source: source)
    }

    func warning(_ message: String, source: String = "General") {
        append(level: .warning, message: message, source: source)
    }

    func error(_ message: String, source: String = "General") {
        append(level: .error, message: message, source: source)
    }

    func debug(_ message: String, source: String = "General") {
        #if DEBUG
        append(level: .debug, message: message, source: source)
        #endif
    }

    private func append(level: LogLevel, message: String, source: String) {
        queue.async { [weak self] in
            let entry = LogEntry(
                id: UUID(),
                timestamp: Date(),
                level: level,
                message: message,
                source: source
            )

            // @Published 属性必须在主线程更新（SwiftUI 要求）
            DispatchQueue.main.async {
                self?.logs.append(entry)

                // 限制日志数量，防止内存膨胀
                while (self?.logs.count ?? 0) > (self?.maxLogEntries ?? 50) {
                    self?.logs.removeFirst()
                }
            }

            // 同时输出到系统日志（控制台可见）
            let osLogType: OSLogType = {
                switch level {
                case .info: return .info
                case .warning: return .default
                case .error: return .error
                case .debug: return .debug
                }
            }()
            os_log("[%@][%@] %@", log: OSLog(subsystem: "com.reprovision", category: source),
               type: osLogType, level.displayName, source, message)

            // daemon 日志转发（自动续签时实时写入 reprorefresh_at.log）
            if let dp = self?.daemonLogPath {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let ts = df.string(from: entry.timestamp)
                if let line = "[\(ts)] [\(source)] \(message)\n".data(using: .utf8) {
                    if let fh = FileHandle(forWritingAtPath: dp) {
                        fh.seekToEndOfFile()
                        fh.write(line)
                        fh.closeFile()
                    }
                }
            }
        }
    }

    // MARK: 清空日志
    func clear() {
        queue.async { [weak self] in
            self?.logs.removeAll()
            self?.deleteLogFile()
        }
    }

    // MARK: 持久化
    private func saveToDisk() {
        guard let url = logFileURL else { return }
        do {
            let data = try JSONEncoder().encode(logs)
            try data.write(to: url, options: .atomic)
        } catch {
            os_log("保存日志失败: %{public}@", type: .error, error.localizedDescription)
        }
    }

    private func loadFromDisk() {
        guard let url = logFileURL else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([LogEntry].self, from: data)
            DispatchQueue.main.async { [weak self] in
                self?.logs = decoded
            }
        } catch {
            // 首次启动或文件损坏，忽略
        }
    }

    private func deleteLogFile() {
        guard let url = logFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private var logFileURL: URL? {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ReProvision")
        guard let safeDir = dir else { return nil }
        try? FileManager.default.createDirectory(at: safeDir, withIntermediateDirectories: true)
        return safeDir.appendingPathComponent("logs.json")
    }
}
