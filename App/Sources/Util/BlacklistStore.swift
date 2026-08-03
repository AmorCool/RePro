import Foundation
import Combine

// MARK: - 小黑屋（黑名单）存储

/// 小黑屋的持久化层。
///
/// 这是纯 UI/偏好状态，与守护进程无关，因此直接用 UserDefaults 存即可。
/// 存的是 `bundleID -> 来源` 的字典（来源取值见 `BlacklistSource` 的 rawValue），
/// 这样既能 O(1) 判断某个应用是否被拉黑，又能在小黑屋列表里标注它来自哪个原始列表。
///
/// ObjC 侧（`RPVApplicationSigning.resignApplications:`）会直接读同一个
/// UserDefaults 键来跳过黑名单应用，因此键名必须固定且一致。
final class BlacklistStore: ObservableObject {
    static let shared = BlacklistStore()

    /// UserDefaults 键名。ObjC 侧 `RPVApplicationSigning.m` 用同样的键读取。
    static let userDefaultsKey = "reproBlacklist"

    /// 内容变化通知（持久化后广播），供 SigningViewModel 等跨视图订阅重新分区。
    static let didChangeNotification = Notification.Name("reproBlacklistDidChange")

    /// 黑名单内容：`bundleID -> 来源 rawValue`("installed" / "other")
    @Published private(set) var entries: [String: String] = [:]

    private init() {
        load()
    }

    private func load() {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.userDefaultsKey) as? [String: String] {
            entries = dict
        }
    }

    private func persist() {
        UserDefaults.standard.set(entries, forKey: Self.userDefaultsKey)
        UserDefaults.standard.synchronize()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - 公开接口

    func isBlacklisted(_ bundleID: String) -> Bool {
        entries[bundleID] != nil
    }

    /// 把应用加入小黑屋。source 记录它来自哪个原始列表。
    func add(_ bundleID: String, source: BlacklistSource) {
        guard !bundleID.isEmpty else { return }
        let key = bundleID
        if entries[key] == source.rawValue { return }  // 已存在且来源一致，无需改动
        entries[key] = source.rawValue
        persist()
    }

    func remove(_ bundleID: String) {
        guard entries.removeValue(forKey: bundleID) != nil else { return }
        persist()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
    }

    /// 返回某个 bundleID 的来源；不在黑名单里时返回 nil。
    func source(for bundleID: String) -> BlacklistSource? {
        guard let raw = entries[bundleID] else { return nil }
        return BlacklistSource(rawValue: raw)
    }

    /// 黑名单中应用的 bundleID 列表（用于 小黑屋 Section 渲染）。
    var bundleIDs: [String] {
        Array(entries.keys)
    }
}
