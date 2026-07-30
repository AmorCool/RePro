import Foundation

// MARK: - Daemon 通信客户端 (XPC)

class DaemonClient: NSObject {
    static let shared = DaemonClient()

    private var connection: NSXPCConnection?
    private(set) var isConnected: Bool = false
    private var reconnectTimer: Timer?

    // XPC 协议版本
    static let protocolVersion: UInt8 = 1

    override init() {
        super.init()
        setupConnection()
    }

    deinit {
        invalidate()
    }

    // MARK: 建立 XPC 连接
    private func setupConnection() {
        connection = NSXPCConnection(machServiceName: "com.reprovision.daemon", options: .privileged)
        connection?.remoteObjectInterface = NSXPCInterface(with: RZDaemonProtocol.self)
        connection?.invalidationHandler = { [weak self] in
            self?.handleDisconnection()
        }
        connection?.interruptedHandler = { [weak self] in
            self?.handleDisconnection()
        }
        connection?.resume()
    }

    private func handleDisconnection() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = false
            LogManager.shared.info("Daemon 连接断开", source: "DaemonClient")
            // 5 秒后自动重连
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                self?.setupConnection()
                self?.checkConnection()
            }
        }
    }

    func checkConnection() {
        guard let conn = connection else { return }
        conn.remoteObjectProxy as? RZDaemonProtocol { [weak self] proxy in
            if let proxy = proxy {
                proxy.ping { response in
                    DispatchQueue.main.async {
                        self?.isConnected = true
                    }
                }
            } else {
                self?.isConnected = false
            }
        }
    }

    private func invalidate() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        connection?.invalidate()
        connection = nil
        isConnected = false
    }

    // MARK: 获取代理对象
    private func getProxy(completion: @escaping (RZDaemonProtocol?) -> Void) {
        guard let conn = connection else {
            completion(nil)
            return
        }
        conn.remoteObjectProxy as? RZDaemonProtocol { proxy in
            completion(proxy)
        }
    }

    // MARK: 公共 API

    /// 登录 Apple ID
    func login(appleID: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        getProxy { [weak self] proxy in
            guard let proxy = proxy else {
                completion(.failure(ReProError.daemonConnectionFailed("连接未建立")))
                return
            }
            // ObjC 端返回 (NSDictionary?, Error?)
            proxy.login(withAppleID: appleID, password: password) { resultDict, error in
                if let error = error {
                    completion(.failure(error))
                } else if resultDict != nil {
                    completion(.success(()))
                } else {
                    completion(.failure(ReProError.daemonConnectionFailed("登录返回空结果")))
                }
            }
        }
    }

    /// 获取已安装应用列表
    func getInstalledApps(completion: @escaping (Result<[InstalledApp], Error>) -> Void) {
        getProxy { proxy in
            guard let proxy = proxy else {
                completion(.failure(ReProError.daemonConnectionFailed("连接未建立")))
                return
            }
            // ObjC 端返回 NSArray<NSDictionary *>，这里映射为 [[String: Any]]
            proxy.getInstalledApps { dicts in
                let apps = dicts.map { InstalledApp.fromDictionary($0) }
                completion(.success(apps))
            }
        }
    }

    /// 导入 IPA 文件
    func importIPA(path: String, completion: @escaping (Result<InstalledApp, Error>) -> Void) {
        getProxy { proxy in
            guard let proxy = proxy else {
                completion(.failure(ReProError.daemonConnectionFailed("连接未建立")))
                return
            }
            proxy.importIPA(atPath: path) { appDict, error in
                if let error = error {
                    completion(.failure(error))
                } else if let dict = appDict {
                    completion(.success(InstalledApp.fromDictionary(dict)))
                } else {
                    completion(.failure(ReProError.daemonConnectionFailed("导入返回空结果")))
                }
            }
        }
    }

    /// 重签应用（ObjC 选择器: resignApplicationWithBundleIdentifier:reply:）
    func resign(bundleID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        getProxy { proxy in
            guard let proxy = proxy else {
                completion(.failure(ReProError.daemonConnectionFailed("连接未建立")))
                return
            }
            // 使用与 ObjC 端匹配的方法签名
            proxy.resignApplication(withBundleIdentifier: bundleID) { success, errorMessage in
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(ReProError.signingFailed(errorMessage ?? "未知错误")))
                }
            }
        }
    }

    /// 获取健康状态
    func getHealth(completion: @escaping (Result<DaemonHealthStatus, Error>) -> Void) {
        getProxy { proxy in
            guard let proxy = proxy else {
                completion(.failure(ReProError.daemonConnectionFailed("连接未建立")))
                return
            }
            proxy.getHealthStatus { statusDict in
                let status = DaemonHealthStatus.fromDictionary(statusDict)
                completion(.success(status))
            }
        }
    }

    /// 重启守护进程
    func restartDaemon(completion: @escaping (Result<Void, Error>) -> Void) {
        getProxy { proxy in
            guard let proxy = proxy else {
                completion(.failure(ReProError.daemonConnectionFailed("连接未建立")))
                return
            }
            proxy.restart { success in
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(ReProError.permissionDenied))
                }
            }
        }
    }

    /// 安装 provisioning profile
    func installProfile(path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        getProxy { proxy in
            guard let proxy = proxy else {
                completion(.failure(ReProError.daemonConnectionFailed("连接未建立")))
                return
            }
            proxy.installProvisioningProfile(atPath: path) { success, errorMessage in
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(ReProError.signingFailed(errorMessage ?? "安装失败")))
                }
            }
        }
    }

    /// 刷新 Token 缓存
    func refreshTokens(count: Int, completion: @escaping (Result<Int, Error>) -> Void) {
        getProxy { proxy in
            guard let proxy = proxy else {
                completion(.failure(ReProError.daemonConnectionFailed("连接未建立")))
                return
            }
            proxy.preSignTokens(count: count) { signedCount in
                completion(.success(signedCount))
            }
        }
    }
}

// MARK: - XPC 协议定义（必须与 RZDaemon.h 中的 @protocol RZDaemonXPCProtocol 完全匹配）

@objc protocol RZDaemonProtocol {
    // 基础
    func pingWithReply(_ reply: @escaping (String) -> Void)

    // 认证（ObjC 端返回 NSDictionary + NSError，不能用 Swift Result）
    func login(withAppleID appleID: String,
              password: String,
              reply: @escaping ([String: Any]?, Error?) -> Void)

    // 应用管理（ObjC 端返回 NSArray<NSDictionary *>，不能直接传 Swift 自定义类型）
    func getInstalledApps(_ reply: @escaping ([[String: Any]]) -> Void)
    func importIPA(atPath path: String,
                   reply: @escaping ([String: Any]?, Error?) -> Void)
    // 注意：ObjC 选择器是 resignApplicationWithBundleIdentifier:reply:
    func resignApplication(withBundleIdentifier bundleID: String,
                           reply: @escaping (Bool, String?) -> Void)

    // 状态与健康检查
    func getHealthStatus(_ reply: @escaping ([String: Any]) -> Void)
    func restart(_ reply: @escaping (Bool) -> Void)

    // Profile 管理
    func installProvisioningProfile(atPath path: String,
                                    reply: @escaping (Bool, String?) -> Void)

    // Token 缓存
    func preSignTokens(count: Int,
                       reply: @escaping (Int) -> Void)

    // Anisette 状态
    func getAnisetteStatus(_ reply: @escaping (Bool) -> Void)
}

// MARK: - 扩展：字典转换

extension InstalledApp {
    static func fromDictionary(_ dict: [String: Any]) -> InstalledApp {
        InstalledApp(
            id: UUID(uuidString: dict["id"] as? String ?? UUID().uuidString) ?? UUID(),
            bundleIdentifier: dict["bundleIdentifier"] as? String ?? "",
            displayName: dict["displayName"] as? String ?? "Unknown",
            version: dict["version"] as? String ?? "",
            iconData: dict["iconData"] as? Data,
            certificateExpiryDate: (dict["certificateExpiryDate"] as? Double).map(Date.init(timeIntervalSince1970:)),
            isSigning: false
        )
    }
}

extension DaemonHealthStatus {
    static func fromDictionary(_ dict: [String: Any]) -> DaemonHealthStatus {
        DaemonHealthStatus(
            daemonRunning: dict["daemonRunning"] as? Bool ?? false,
            hasRootPrivileges: dict["hasRootPrivileges"] as? Bool ?? false,
            isSandboxed: dict["isSandboxed"] as? Bool ?? true,
            zsignPath: dict["zsignPath"] as? String,
            lastResignTime: (dict["lastResignTime"] as? Double).map(Date.init(timeIntervalSince1970:)),
            validTokenCount: dict["validTokenCount"] as? Int ?? 0,
            anisetteReady: dict["anisetteReady"] as? Bool ?? false,
            jailbreakType: JailbreakType(rawValue: dict["jailbreakType"] as? String ?? "unknown") ?? .unknown,
            uptimeSeconds: dict["uptimeSeconds"] as? TimeInterval
        )
    }
}
