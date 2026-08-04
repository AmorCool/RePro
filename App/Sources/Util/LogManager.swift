import Foundation
import os.log

// MARK: - 全局 daemon 日志句柄（用 C FILE* 同步写入，可靠）

private var gDaemonLogFile: UnsafeMutablePointer<FILE>? = nil
private var gDaemonLogPath: String? = nil

/// 开启 daemon 日志转发（后续所有 LogManager 日志同步写入该文件）
func DaemonLogStart(_ path: String) {
    gDaemonLogPath = path
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    gDaemonLogFile = fopen(path, "a")
    if gDaemonLogFile != nil { chmod(path, 0666) }
}

/// 关闭 daemon 日志转发
func DaemonLogStop() {
    if let f = gDaemonLogFile { fclose(f) }
    gDaemonLogFile = nil
    gDaemonLogPath = nil
}

/// 清空 daemon 日志（fopen("w")截断，不依赖权限）
func DaemonLogClear(_ path: String) {
    if let f = gDaemonLogFile { fclose(f); gDaemonLogFile = nil }
    if let f = fopen(path, "w") { fclose(f); chmod(path, 0666) }
}

/// 获取 daemon 日志文件大小
func DaemonLogSize(_ path: String) -> String {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? Int64 else { return "—" }
    if size < 1024 { return "\(size) B" }
    if size < 1024*1024 { return String(format: "%.1f KB", Double(size)/1024.0) }
    return String(format: "%.1f MB", Double(size)/(1024.0*1024.0))
}

/// daemon 日志路径（从 App bundle 推 jbroot）
func DaemonLogDefaultPath() -> String {
    let p = Bundle.main.bundlePath
    if let r = p.range(of: "/Applications/", options: .backwards) {
        return "\(p[..<r.lowerBound])/var/log/reprorefresh_at.log"
    }
    return "/var/jb/var/log/reprorefresh_at.log"
}

/// daemon 日志文件大小上限（2 MB），超出后截断重建（见 daemonLogWrite 轮转逻辑）
private let maxDaemonLogSize: Int64 = 2 * 1024 * 1024
/// 轮转检查计数器（daemonLogWrite 每 ~100 行 stat 一次文件大小；Swift 函数内不允许 static 局部变量，用文件级全局）
private var daemonLogWriteCount: Int = 0

/// 同步写入一行到 daemon 日志（在 LogManager.append 中调用）
/// 内置 2 MB 轮转：超出后截断保留后半段，避免长期运行撑满磁盘
private func daemonLogWrite(ts: String, source: String, message: String) {
    guard let f = gDaemonLogFile else { return }

    // 每写入 ~100 行检查一次文件大小（避免每次都 stat 的开销）
    daemonLogWriteCount += 1
    if daemonLogWriteCount % 100 == 1, let path = gDaemonLogPath {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64,
           size > maxDaemonLogSize {
            // 截断：关闭当前文件 → 重开（fopen "w" 清空）→ 写入轮转标记
            fclose(f)
            gDaemonLogFile = nil
            if let nf = fopen(path, "w") {
                gDaemonLogFile = nf
                chmod(path, 0666)
                fputs("=== 日志文件已自动轮转（超出 2 MB 上限，旧日志已清除）===\n", nf)
                fflush(nf)
            }
        }
    }

    let line = "[\(ts)] [\(source)] \(message)\n"
    fputs(line, f)
    fflush(f)
}

// MARK: - 统一日志管理器

class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published private(set) var logs: [LogEntry] = []
    private let maxLogEntries = 5000
    private let queue = DispatchQueue(label: "com.reprovision.logmanager", qos: .utility)

    private init() {}

    // MARK: 初始化
    func initialize() {
        loadFromDisk()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDiagnostic(_:)),
            name: Notification.Name("com.reprovision.diagnostic"), object: nil)
    }

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
    func info(_ message: String, source: String = "General")    { append(level: .info,    message: message, source: source) }
    func warning(_ message: String, source: String = "General")  { append(level: .warning, message: message, source: source) }
    func error(_ message: String, source: String = "General")    { append(level: .error,   message: message, source: source) }
    func debug(_ message: String, source: String = "General")    {
        #if DEBUG
        append(level: .debug, message: message, source: source)
        #endif
    }

    // 静态 formatter 复用（append 每秒可能被调用多次，避免反复创建 DateFormatter）
    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func append(level: LogLevel, message: String, source: String) {
        let now = Date()
        let entry = LogEntry(id: UUID(), timestamp: now, level: level, message: message, source: source)

        // daemon 日志：同步写入（最关键——不用 async，不丢数据）
        let ts = LogManager.dateFormat.string(from: now)
        daemonLogWrite(ts: ts, source: source, message: message)

        // 内存日志：异步更新 UI
        queue.async { [weak self] in
            DispatchQueue.main.async {
                self?.logs.append(entry)
                while (self?.logs.count ?? 0) > (self?.maxLogEntries ?? 50) { self?.logs.removeFirst() }
            }
            os_log("[%@][%@] %@", log: OSLog(subsystem: "com.reprovision", category: source),
                   type: (level == .error ? .error : level == .warning ? .default : .info),
                   level.displayName, source, message)
        }
    }

    // MARK: 清空
    func clear() {
        queue.async { [weak self] in self?.logs.removeAll(); self?.deleteLogFile() }
    }

    private func saveToDisk() {
        guard let url = logFileURL else { return }
        try? (try? JSONEncoder().encode(logs))?.write(to: url, options: .atomic)
    }

    private func loadFromDisk() {
        guard let url = logFileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([LogEntry].self, from: data) else { return }
        DispatchQueue.main.async { [weak self] in self?.logs = decoded }
    }

    private func deleteLogFile() { if let u = logFileURL { try? FileManager.default.removeItem(at: u) } }

    private var logFileURL: URL? {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ReProvision")
        guard let d = dir else { return nil }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("logs.json")
    }
}
