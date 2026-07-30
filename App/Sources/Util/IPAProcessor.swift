import Foundation
import UniformTypeIdentifiers
import UIKit
import Darwin

// MARK: - IPA 处理工具类

class IPAProcessor {

    /// 通过 posix_spawn 执行外部命令（iOS 上 Process 不可用），返回退出码
    private static func runCommand(_ executable: String, args: [String], workingDirectory: String? = nil) -> Int32 {
        var pid: pid_t = 0

        // 保存并切换工作目录（posix_spawn_file_actions_t 在当前 SDK 不可默认构造，
        // 改用 FileManager.changeCurrentDirectoryPath + 同步 waitpid 保证线程安全）
        let savedCWD = FileManager.default.currentDirectoryPath
        if let wd = workingDirectory {
            FileManager.default.changeCurrentDirectoryPath(wd)
        }
        defer {
            if workingDirectory != nil {
                FileManager.default.changeCurrentDirectoryPath(savedCWD)
            }
        }

        let argv: [UnsafeMutablePointer<CChar>?] = args.map { $0.withCString(strdup) } + [nil]
        defer { for p in argv { free(p) } }
        let status = argv.withUnsafeBufferPointer { buf in
            posix_spawn(&pid, executable, nil, nil,
                        UnsafeMutablePointer(mutating: buf.baseAddress), nil)
        }
        if status == 0 {
            var st: Int32 = 0
            waitpid(pid, &st, 0)
            return (st >> 8) & 0xff  // WEXITSTATUS 等价实现
        }
        return status
    }

    /// 解压 IPA 到临时目录
    static func extract(ipaPath: String) throws -> URL {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("repro_extract_\(UUID().uuidString)")

        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 使用 unzip 解压（iOS 无 Process，改用 posix_spawn）
        let status = runCommand("/usr/bin/unzip", args: ["unzip", "-qo", ipaPath, "-d", tempDir.path])
        guard status == 0 else {
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
        // zip 在 Payload 的父目录中执行，将 "Payload/xxx.app" 加入归档
        let workDir = appPath.deletingLastPathComponent().deletingLastPathComponent().path
        let status = runCommand("/usr/bin/zip", args: [
            "zip", "-q", "-r",
            outputPath.path,
            "Payload/\(appPath.lastPathComponent)"
        ], workingDirectory: workDir)

        guard status == 0 else {
            throw ReProError.signingFailed("打包 IPA 失败")
        }
    }

    /// 读取 App 的 Info.plist
    static func readInfoPlist(fromAppBundle appPath: URL) -> [String: Any]? {
        let plistPath = appPath.appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath.path),
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
        return FileManager.default.contents(atPath: profilePath.path)
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
