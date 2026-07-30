import Foundation
import os.log

// MARK: - 统一日志管理器（参考 SideStore 日志系统）

class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published private(set) var logs: [LogEntry] = []
    private let maxLogEntries = 5000
    private let queue = DispatchQueue(label: "com.reprovision.logmanager", qos: .utility)

    private init() {}

    // MARK: 初始化
    func initialize() {
        loadFromDisk()
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

            self?.logs.append(entry)

            // 限制日志数量，防止内存膨胀
            while (self?.logs.count ?? 0) > self?.maxLogEntries {
                self?.logs.removeFirst()
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
            logs = decoded
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
        try? FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        return dir?.appendingPathComponent("logs.json")
    }
}
