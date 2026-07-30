import Foundation

// MARK: - 越狱环境检测

enum JailbreakDetect {

    /// 当前越狱环境类型
    static func current() -> JailbreakType {
        if isRootHide() { return .roothide }
        if isDopamine() { return .dopamine }
        if isRootful() { return .rootful }
        return .unknown
    }

    /// 是否为 RootHide 环境
    private static func isRootHide() -> Bool {
        // 方法1: 检测 .jbroot 符号链接
        let jbrootLink = Bundle.main.bundlePath + "/.jbroot"
        if FileManager.default.fileExistsAtPath(jbrootLink) {
            return true
        }
        // 方法2: 检测 RootHide 特有路径
        return FileManager.default.fileExistsAtPath("/var/jb/.roothide_version")
    }

    /// 是否为 Dopamine 环境
    private static func isDopamine() -> Bool {
        // Dopamine 的标志文件
        return FileManager.default.fileExistsAtPath("/var/jb/dopamine") ||
               FileManager.default.fileExistsAtPath("/var/jb/basebin/package.deb")
    }

    /// 是否为 rootful 越狱
    private static func isRootful() -> Bool {
        // rootful 越狱可以直接访问 /Applications 且不是沙盒
        return FileManager.default.isWritableFile(atPath: "/Applications") &&
               !FileManager.default.fileExistsAtPath("/var/jb")
    }

    /// 获取 jbroot 路径（仅 RootHide）
    static func jbrootPath() -> String? {
        let link = Bundle.main.bundlePath + "/.jbroot"
        guard FileManager.default.fileExistsAtPath(link) else { return nil }
        let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: link)
        // .jbroot 是符号链接，需要解析其指向的真实路径
        let fullResolved = (try? URL(fileURLWithPath: link).resolvingSymlinksInPath().path) ?? resolved
        guard FileManager.default.fileExistsAtPath(fullResolved?.appendingPathComponent("usr/local/bin").fullResolved ?? "") else { return nil }
        return fullResolved
    }

    /// 获取当前 dpkg 安装的包类型
    static func packageType() -> PackageType {
        let fm = FileManager.default
        // 检测是否通过 dpkg 安装
        if fm.fileExistsAtPath("/var/lib/dpkg/info/com.reprovision.list") ||
           fm.fileExistsAtPath("/var/jb/var/lib/dpkg/info/jp.soh.reprovision.list") {
            return .dpkg
        }
        // 检测是否为 sideload（TestFlight / Sideloadly）
        if Bundle.main.appStoreReceiptURL != nil {
            return .sideload
        }
        return .development
    }

    enum PackageType {
        case dpkg       // 通过 dpkg 安装（Cydia/Sileo）
        case sideload    // 侧载安装
        case development // Xcode 开发调试
    }
}
