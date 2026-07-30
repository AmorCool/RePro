import Foundation
import UniformTypeIdentifiers

// MARK: - IPA 处理工具类

class IPAProcessor {

    /// 解压 IPA 到临时目录
    static func extract(ipaPath: String) throws -> URL {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("repro_extract_\(UUID().uuidString)")

        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 使用 unzip 解压
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qo", ipaPath, "-d", tempDir.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ReProError.invalidIPA
        }

        return tempDir
    }

    /// 从解压目录获取 Payload/xxx.app 路径
    static func appBundlePath(fromExtractedDir dir: URL) throws -> URL {
        let payloadDir = dir.appendingPathComponent("Payload")

        guard FileManager.default.fileExists(atPath: payloadDir.path) else {
            throw ReProError.invalidIPA
        }

        // 查找 .app 目录
        let contents = try FileManager.default.contentsOfDirectory(at: payloadDir,
                                                                  includingPropertiesForKeys: nil)
        guard let appDir = contents.first(where: { $0.pathExtension == "app" }) else {
            throw ReProError.invalidIPA
        }

        return appDir
    }

    /// 打包 .app 目录为 IPA
    static func pack(appPath: URL, outputPath: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = [
            "-q", "-r",
            outputPath.path,
            "Payload/\(appPath.lastPathComponent)"
        ]
        process.currentDirectoryURL = appPath.deletingLastPathComponent().deletingLastPathComponent()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ReProError.signingFailed("打包 IPA 失败")
        }
    }

    /// 读取 App 的 Info.plist
    static func readInfoPlist(fromAppBundle appPath: URL) -> [String: Any]? {
        let plistPath = appPath.appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                        options: [],
                                                                        format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    /// 读取 embedded.mobileprovision 数据
    static func readEmbeddedProfile(fromAppBundle appPath: URL) -> Data? {
        let profilePath = appPath.appendingPathComponent("embedded.mobileprovision")
        return FileManager.default.contents(atPath: profilePath)
    }

    /// 获取应用图标
    static func appIcon(fromAppBundle appPath: URL) -> UIImage? {
        guard let info = readInfoPlist(fromAppBundle: appPath),
              let icons = info["CFBundleIcons"] as? [String: Any],
              let primaryIcons = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let iconFiles = primaryIcons["CFBundleIconFiles"] as? [String],
              let iconName = iconFiles.first else {
            return nil
        }

        // 尝试 @2x/@3x 变体
        for scale in ["@3x", "@2x", ""] {
            let fullPath = appPath.appendingPathComponent("\(iconName)\(scale).png")
            if let data = FileManager.default.contents(atPath: fullPath.path) {
                return UIImage(data: data)
            }
        }
        return nil
    }

    /// 清理临时目录
    static func cleanup(tempDir: URL) {
        try? FileManager.default.removeItem(at: tempDir)
    }
}
