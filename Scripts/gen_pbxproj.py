#!/usr/bin/env python3
"""重新生成 ReSign.xcodeproj/project.pbxproj。

为什么要用脚本生成而不是手工维护：
  之前手工维护的 pbxproj 出现了四类致命损坏——
    1. Sources 阶段 59 个 Vendor 条目全部引用同一个 UUID；
    2. PBXBuildFile 和它的 fileRef 共用同一个 UUID；
    3. 残留了已删除 daemon target 的配置与 TargetAttribute；
    4. 出现了 'G' 这种非十六进制字符的 UUID。
  这些问题靠打补丁改不干净，改成扫描磁盘、确定性生成，才能保证结构永远自洽。

用法：
    python Scripts/gen_pbxproj.py          # 生成
    python Scripts/validate_pbxproj.py     # 校验
"""
import hashlib
import os
import sys

SEP = "/"
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT = os.path.join(PROJECT_ROOT, "RePro.xcodeproj", "project.pbxproj")

# ---------------------------------------------------------------------------
# 工程基本信息
# ---------------------------------------------------------------------------
TARGET_NAME = "ReSign"
BUNDLE_ID = "com.reprovision.repro"
MARKETING_VERSION = "1.1.135"
CURRENT_PROJECT_VERSION = "57"
DEPLOYMENT_TARGET = "16.0"
BRIDGING_HEADER = "App/Sources/Bridge/ReSign-Bridging-Header.h"
ENTITLEMENTS = "Resources/entitlements-base.plist"
# 使用实际 Info.plist 文件（而非 Xcode 自动生成），以便包含
# SBAppUsesLocalNotifications 等非标准键（test2/ReProvision-Reborn 已验证必需）。
INFOPLIST_FILE = "App/Info.plist"

# ldid.old.cpp 是 ldid 的旧版副本，原项目 iOS target 同样没有编译它。
EXCLUDED_SOURCES = {"ldid.old.cpp"}

# libplist / libcnary 里有 String.h、Array.h、Node.h、list.h 等与系统头同名的文件。
# macOS 文件系统大小写不敏感，一旦把这些目录放进 HEADER_SEARCH_PATHS，
# `#include <string.h>` 就会被解析成 libplist 的 String.h 而编译失败。
# 所以这里只列出 Scripts/_analyze_headers.py 算出来的最小必要集合。
VENDOR_HEADER_DIRS = [
    "Vendor/ReProvision",  # 提供 <corecrypto/...>
    "Vendor/ReProvision/Application Database",
    "Vendor/ReProvision/Resources",
    "Vendor/ReProvision/Support",
    "Vendor/ReProvision/libProvision",
    "Vendor/ReProvision/libProvision/Apple Services",
    "Vendor/ReProvision/libProvision/Provisioning",
    "Vendor/ReProvision/libProvision/SAMKeychain",
    "Vendor/ReProvision/libProvision/SSZipArchive",
    "Vendor/ReProvision/libProvision/SSZipArchive/minizip",
    "Vendor/ReProvision/libProvision/Signing",
    "Vendor/ReProvision/libProvision/ldid",
    # ChOma（opa334/ChOma，MIT 许可，commit 5eca76384237fec26c6bfb8e236ebe4a6b7982fa）。
    # 源码直接 vendored 进仓库随 App 一起编译，不做 dlopen、也不在 CI 里单独 make：
    #   1) MIT 许可允许静态链接，没有 GPL 问题；
    #   2) src/*.c 只依赖 iOS SDK 自带头（CommonCrypto / CoreFoundation / mach-o），零外部依赖；
    #   3) CI 少一个构建步骤就少一处失败点。
    # 它唯一与现有代码同名的头是 Base64.h（libplist 里有个 base64.h），而 libplist 目录
    # 本来就不在这个列表里，且两边都用引号包含（同目录优先），不会互相串。
    "Vendor/ChOma",
    "App/Sources/Bridge",
    # 本地通知模块（移植自 test2 源码）：桥接头 #import "RPVNotificationManager.h"
    # 需要能在这里找到它，HookUtil.h 也由 RPVNotificationManager.m 同目录引用。
    "App/Sources/Notifications",
]

# SDK 里的系统库。libMobileGestalt 提供 MGCopyAnswer（RPVAccountChecker），
# AuthKit 提供 AKDevice（EEAppleServices），libz 提供 minizip 需要的 zlib。
SDK_FRAMEWORKS = [
    ("Security.framework", "System/Library/Frameworks/Security.framework", "wrapper.framework"),
    ("MobileCoreServices.framework", "System/Library/Frameworks/MobileCoreServices.framework", "wrapper.framework"),
    # 本地通知（RPVNotificationManager）。clang modules 一般会自动链接，
    # 这里显式列出，避免某些 SDK 组合下 autolink 失效导致符号缺失。
    ("UserNotifications.framework", "System/Library/Frameworks/UserNotifications.framework", "wrapper.framework"),
    ("libMobileGestalt.tbd", "usr/lib/libMobileGestalt.tbd", "sourcecode.text-based-dylib-definition"),
    ("libz.tbd", "usr/lib/libz.tbd", "sourcecode.text-based-dylib-definition"),
]
# AuthKit 的 tbd 系统 SDK 不带，随仓库自带一份。
LOCAL_FRAMEWORKS = [("AuthKit.tbd", "Vendor/AuthKit.tbd", "sourcecode.text-based-dylib-definition")]

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".m": "sourcecode.c.objc",
    ".mm": "sourcecode.cpp.objcpp",
    ".c": "sourcecode.c.c",
    ".cpp": "sourcecode.cpp.cpp",
    ".h": "sourcecode.c.h",
    ".hpp": "sourcecode.cpp.h",
    ".plist": "text.plist.xml",
    ".strings": "text.plist.strings",
    ".pem": "text",
    ".png": "image.png",
    ".xcassets": "folder.assetcatalog",
    ".tbd": "sourcecode.text-based-dylib-definition",
}
COMPILED_EXTS = {".swift", ".m", ".mm", ".c", ".cpp"}


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------
_used_ids = {}


def uid(kind, key):
    """由 kind+key 确定性推导 24 位十六进制 UUID，保证每次生成结果一致。"""
    digest = hashlib.md5(("%s::%s" % (kind, key)).encode("utf-8")).hexdigest().upper()
    value = digest[:24]
    if value in _used_ids and _used_ids[value] != (kind, key):
        raise SystemExit("UUID 冲突: %s 与 %s" % (_used_ids[value], (kind, key)))
    _used_ids[value] = (kind, key)
    return value


def q(text):
    """按 pbxproj 的老式 plist 规则决定是否加引号。"""
    if text == "":
        return '""'
    safe = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./")
    if all(ch in safe for ch in text):
        return text
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def file_type(path):
    return FILE_TYPES.get(os.path.splitext(path)[1], "text")


def walk(rel_root, exts=None, skip_dirs=()):
    """按路径排序收集文件，保证生成结果稳定。"""
    out = []
    abs_root = os.path.join(PROJECT_ROOT, rel_root)
    for dirpath, dirnames, filenames in os.walk(abs_root):
        dirnames[:] = sorted(d for d in dirnames if d not in skip_dirs)
        for name in sorted(filenames):
            ext = os.path.splitext(name)[1]
            if exts is not None and ext not in exts:
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), PROJECT_ROOT)
            out.append(rel.replace(os.sep, SEP))
    return sorted(out)


# ---------------------------------------------------------------------------
# 收集文件
# ---------------------------------------------------------------------------
def collect():
    swift = walk("App/Sources", exts={".swift"})
    bridge_src = ["App/Sources/Bridge/RPVBridge.m",
                  "App/Sources/Bridge/RPVSigningdNotify.m",
                  # 本地通知：HookUtil.c 自带 fishhook 重写，零外部依赖；
                  # RPVNotificationManager.m 里的 constructor Hook 依赖它。
                  "App/Sources/Notifications/HookUtil.c",
                  "App/Sources/Notifications/RPVNotificationManager.m"]
    bridge_hdr = ["App/Sources/Bridge/RPVBridge.h", BRIDGING_HEADER,
                  "App/Sources/Notifications/HookUtil.h",
                  "App/Sources/Notifications/RPVNotificationManager.h"]

    vendor_all = walk("Vendor/ReProvision", exts={".m", ".mm", ".c", ".cpp", ".h", ".hpp"})
    # ChOma 全量参与编译。官方 Makefile 就支持 TARGET=ios 全量构建，
    # 裁剪反而容易漏符号导致链接失败，所以整包编进来。
    vendor_all = sorted(vendor_all + walk("Vendor/ChOma", exts={".c", ".h"}))
    vendor_src = [p for p in vendor_all
                  if os.path.splitext(p)[1] in COMPILED_EXTS
                  and os.path.basename(p) not in EXCLUDED_SOURCES]
    vendor_hdr = [p for p in vendor_all if os.path.splitext(p)[1] in (".h", ".hpp")]
    # ldid.old.cpp 仍作为 fileRef 保留在工程里便于查阅，只是不参与编译
    vendor_extra = [p for p in vendor_all if os.path.basename(p) in EXCLUDED_SOURCES]

    # EESigning.mm 通过 NSBundle mainBundle 读取 apple-ios.pem 等证书，
    # 所以这几个 pem 必须打进 App bundle，不能只放到 deb 的 /usr/share。
    certs = walk("Resources/Certificates", exts={".pem"})

    localizations = []
    res_dir = os.path.join(PROJECT_ROOT, "App", "Sources", "Resources")
    for name in sorted(os.listdir(res_dir)):
        if name.endswith(".lproj") and os.path.isfile(os.path.join(res_dir, name, "Localizable.strings")):
            localizations.append(name[:-len(".lproj")])
    if not localizations:
        raise SystemExit("没有找到任何 *.lproj/Localizable.strings")

    return {
        "swift": swift,
        "bridge_src": bridge_src,
        "bridge_hdr": bridge_hdr,
        "vendor_src": vendor_src,
        "vendor_hdr": vendor_hdr,
        "vendor_extra": vendor_extra,
        "certs": certs,
        "assets": ["App/Sources/App/Assets.xcassets"],
        "entitlements": [ENTITLEMENTS],
        "localizations": localizations,
    }


# ---------------------------------------------------------------------------
# 分组树
# ---------------------------------------------------------------------------
class Group(object):
    def __init__(self, name, path=None):
        self.name = name
        self.path = path
        self.children_groups = {}
        self.children_files = []

    def child(self, name):
        if name not in self.children_groups:
            self.children_groups[name] = Group(name, name)
        return self.children_groups[name]


def add_to_tree(root, rel_path, file_uid):
    parts = rel_path.split(SEP)
    node = root
    for part in parts[:-1]:
        node = node.child(part)
    node.children_files.append((parts[-1], file_uid))


def emit_groups(node, path_key, lines, extra_children=None):
    """深度优先输出 PBXGroup，返回自己的 UUID。"""
    group_uid = uid("group", path_key)
    child_entries = []
    for name in sorted(node.children_groups):
        child = node.children_groups[name]
        child_key = path_key + SEP + name if path_key else name
        child_uid = emit_groups(child, child_key, lines)
        child_entries.append((name, child_uid))
    for name, file_uid in sorted(node.children_files):
        child_entries.append((name, file_uid))
    if extra_children:
        child_entries.extend(extra_children)

    lines.append("\t\t%s /* %s */ = {" % (group_uid, node.name))
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    for name, child_uid in child_entries:
        lines.append("\t\t\t\t%s /* %s */," % (child_uid, name))
    lines.append("\t\t\t);")
    if node.path:
        lines.append("\t\t\tpath = %s;" % q(node.path))
    else:
        lines.append("\t\t\tname = %s;" % q(node.name))
    lines.append('\t\t\tsourceTree = "<group>";')
    lines.append("\t\t};")
    return group_uid


# ---------------------------------------------------------------------------
# 生成
# ---------------------------------------------------------------------------
def build():
    files = collect()

    compiled = files["swift"] + files["bridge_src"] + files["vendor_src"]
    plain_refs = (files["bridge_hdr"] + files["vendor_hdr"] + files["vendor_extra"]
                  + files["certs"] + files["assets"] + files["entitlements"])

    out = []
    out.append("// !$*UTF8*$!")
    out.append("{")
    out.append("\tarchiveVersion = 1;")
    out.append("\tclasses = {")
    out.append("\t};")
    out.append("\tobjectVersion = 56;")
    out.append("\tobjects = {")
    out.append("")

    # ---------------- PBXBuildFile ----------------
    out.append("/* Begin PBXBuildFile section */")
    for path in compiled:
        out.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                   % (uid("buildfile", path), os.path.basename(path),
                      uid("fileref", path), os.path.basename(path)))
    resource_paths = files["assets"] + files["certs"]
    for path in resource_paths:
        out.append("\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                   % (uid("buildfile", path), os.path.basename(path),
                      uid("fileref", path), os.path.basename(path)))
    out.append("\t\t%s /* Localizable.strings in Resources */ = {isa = PBXBuildFile; fileRef = %s /* Localizable.strings */; };"
               % (uid("buildfile", "Localizable.strings"), uid("variantgroup", "Localizable.strings")))
    for name, path, _ in SDK_FRAMEWORKS + LOCAL_FRAMEWORKS:
        out.append("\t\t%s /* %s in Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                   % (uid("buildfile", "fw:" + name), name, uid("fileref", "fw:" + name), name))
    out.append("/* End PBXBuildFile section */")
    out.append("")

    # ---------------- PBXFileReference ----------------
    out.append("/* Begin PBXFileReference section */")
    out.append('\t\t%s /* ReSign.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ReSign.app; sourceTree = BUILT_PRODUCTS_DIR; };'
               % uid("product", "ReSign.app"))
    for path in sorted(set(compiled + plain_refs)):
        out.append("\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = \"<group>\"; };"
                   % (uid("fileref", path), os.path.basename(path), file_type(path), q(os.path.basename(path))))
    for loc in files["localizations"]:
        rel = "%s.lproj/Localizable.strings" % loc
        out.append("\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = %s; path = %s; sourceTree = \"<group>\"; };"
                   % (uid("fileref", "loc:" + loc), loc, q(loc), q(rel)))
    for name, path, ftype in SDK_FRAMEWORKS:
        out.append("\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; name = %s; path = %s; sourceTree = SDKROOT; };"
                   % (uid("fileref", "fw:" + name), name, ftype, q(name), q(path)))
    for name, path, ftype in LOCAL_FRAMEWORKS:
        out.append("\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; name = %s; path = %s; sourceTree = SOURCE_ROOT; };"
                   % (uid("fileref", "fw:" + name), name, ftype, q(name), q(path)))
    out.append("/* End PBXFileReference section */")
    out.append("")

    # ---------------- PBXVariantGroup ----------------
    out.append("/* Begin PBXVariantGroup section */")
    out.append("\t\t%s /* Localizable.strings */ = {" % uid("variantgroup", "Localizable.strings"))
    out.append("\t\t\tisa = PBXVariantGroup;")
    out.append("\t\t\tchildren = (")
    for loc in files["localizations"]:
        out.append("\t\t\t\t%s /* %s */," % (uid("fileref", "loc:" + loc), loc))
    out.append("\t\t\t);")
    out.append("\t\t\tname = Localizable.strings;")
    out.append('\t\t\tsourceTree = "<group>";')
    out.append("\t\t};")
    out.append("/* End PBXVariantGroup section */")
    out.append("")

    # ---------------- PBXFrameworksBuildPhase ----------------
    out.append("/* Begin PBXFrameworksBuildPhase section */")
    out.append("\t\t%s /* Frameworks */ = {" % uid("phase", "frameworks"))
    out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for name, _, _ in SDK_FRAMEWORKS + LOCAL_FRAMEWORKS:
        out.append("\t\t\t\t%s /* %s in Frameworks */," % (uid("buildfile", "fw:" + name), name))
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXFrameworksBuildPhase section */")
    out.append("")

    # ---------------- PBXGroup ----------------
    root = Group("ReSign")
    for path in sorted(set(compiled + plain_refs)):
        add_to_tree(root, path, uid("fileref", path))
    # Localizable.strings 以 variant group 的形式挂在 App/Sources/Resources 下
    res_group = root.child("App").child("Sources").child("Resources")

    group_lines = []
    # 先单独输出 Resources 组（带 variant group 子节点）
    variant_child = [("Localizable.strings", uid("variantgroup", "Localizable.strings"))]

    def emit_root(node, path_key, lines):
        group_uid = uid("group", path_key)
        entries = []
        for name in sorted(node.children_groups):
            child = node.children_groups[name]
            child_key = path_key + SEP + name if path_key else name
            if child is res_group:
                child_uid = emit_groups(child, child_key, lines, extra_children=variant_child)
            else:
                child_uid = emit_root_or_group(child, child_key, lines)
            entries.append((name, child_uid))
        for name, file_uid in sorted(node.children_files):
            entries.append((name, file_uid))
        return group_uid, entries

    def emit_root_or_group(node, path_key, lines):
        if node is res_group:
            return emit_groups(node, path_key, lines, extra_children=variant_child)
        group_uid = uid("group", path_key)
        entries = []
        for name in sorted(node.children_groups):
            child = node.children_groups[name]
            child_key = path_key + SEP + name if path_key else name
            entries.append((name, emit_root_or_group(child, child_key, lines)))
        for name, file_uid in sorted(node.children_files):
            entries.append((name, file_uid))
        lines.append("\t\t%s /* %s */ = {" % (group_uid, node.name))
        lines.append("\t\t\tisa = PBXGroup;")
        lines.append("\t\t\tchildren = (")
        for name, child_uid in entries:
            lines.append("\t\t\t\t%s /* %s */," % (child_uid, name))
        lines.append("\t\t\t);")
        lines.append("\t\t\tpath = %s;" % q(node.path))
        lines.append('\t\t\tsourceTree = "<group>";')
        lines.append("\t\t};")
        return group_uid

    top_entries = []
    for name in sorted(root.children_groups):
        child = root.children_groups[name]
        top_entries.append((name, emit_root_or_group(child, name, group_lines)))
    for name, file_uid in sorted(root.children_files):
        top_entries.append((name, file_uid))

    # Frameworks 组
    fw_group_uid = uid("group", "Frameworks")
    group_lines.append("\t\t%s /* Frameworks */ = {" % fw_group_uid)
    group_lines.append("\t\t\tisa = PBXGroup;")
    group_lines.append("\t\t\tchildren = (")
    for name, _, _ in SDK_FRAMEWORKS + LOCAL_FRAMEWORKS:
        group_lines.append("\t\t\t\t%s /* %s */," % (uid("fileref", "fw:" + name), name))
    group_lines.append("\t\t\t);")
    group_lines.append("\t\t\tname = Frameworks;")
    group_lines.append('\t\t\tsourceTree = "<group>";')
    group_lines.append("\t\t};")

    # Products 组
    products_uid = uid("group", "Products")
    group_lines.append("\t\t%s /* Products */ = {" % products_uid)
    group_lines.append("\t\t\tisa = PBXGroup;")
    group_lines.append("\t\t\tchildren = (")
    group_lines.append("\t\t\t\t%s /* ReSign.app */," % uid("product", "ReSign.app"))
    group_lines.append("\t\t\t);")
    group_lines.append("\t\t\tname = Products;")
    group_lines.append('\t\t\tsourceTree = "<group>";')
    group_lines.append("\t\t};")

    # 主组
    main_uid = uid("group", "__main__")
    group_lines.append("\t\t%s = {" % main_uid)
    group_lines.append("\t\t\tisa = PBXGroup;")
    group_lines.append("\t\t\tchildren = (")
    for name, child_uid in top_entries:
        group_lines.append("\t\t\t\t%s /* %s */," % (child_uid, name))
    group_lines.append("\t\t\t\t%s /* Frameworks */," % fw_group_uid)
    group_lines.append("\t\t\t\t%s /* Products */," % products_uid)
    group_lines.append("\t\t\t);")
    group_lines.append('\t\t\tsourceTree = "<group>";')
    group_lines.append("\t\t};")

    out.append("/* Begin PBXGroup section */")
    out.extend(group_lines)
    out.append("/* End PBXGroup section */")
    out.append("")

    # ---------------- PBXNativeTarget ----------------
    target_uid = uid("target", TARGET_NAME)
    out.append("/* Begin PBXNativeTarget section */")
    out.append("\t\t%s /* %s */ = {" % (target_uid, TARGET_NAME))
    out.append("\t\t\tisa = PBXNativeTarget;")
    out.append('\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget "%s" */;'
               % (uid("configlist", "target"), TARGET_NAME))
    out.append("\t\t\tbuildPhases = (")
    out.append("\t\t\t\t%s /* Sources */," % uid("phase", "sources"))
    out.append("\t\t\t\t%s /* Frameworks */," % uid("phase", "frameworks"))
    out.append("\t\t\t\t%s /* Resources */," % uid("phase", "resources"))
    out.append("\t\t\t);")
    out.append("\t\t\tbuildRules = (")
    out.append("\t\t\t);")
    out.append("\t\t\tdependencies = (")
    out.append("\t\t\t);")
    out.append("\t\t\tname = %s;" % TARGET_NAME)
    out.append("\t\t\tproductName = %s;" % TARGET_NAME)
    out.append("\t\t\tproductReference = %s /* ReSign.app */;" % uid("product", "ReSign.app"))
    out.append('\t\t\tproductType = "com.apple.product-type.application";')
    out.append("\t\t};")
    out.append("/* End PBXNativeTarget section */")
    out.append("")

    # ---------------- PBXProject ----------------
    out.append("/* Begin PBXProject section */")
    out.append("\t\t%s /* Project object */ = {" % uid("project", "root"))
    out.append("\t\t\tisa = PBXProject;")
    out.append("\t\t\tattributes = {")
    out.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    out.append("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    out.append("\t\t\t\tLastUpgradeCheck = 1500;")
    out.append("\t\t\t\tTargetAttributes = {")
    out.append("\t\t\t\t\t%s = {" % target_uid)
    out.append("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    out.append("\t\t\t\t\t};")
    out.append("\t\t\t\t};")
    out.append("\t\t\t};")
    out.append('\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject "%s" */;'
               % (uid("configlist", "project"), TARGET_NAME))
    out.append('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    out.append('\t\t\tdevelopmentRegion = "zh-Hans";')
    out.append("\t\t\thasScannedForEncodings = 0;")
    out.append("\t\t\tknownRegions = (")
    out.append("\t\t\t\tBase,")
    for loc in files["localizations"]:
        out.append("\t\t\t\t%s," % q(loc))
    out.append("\t\t\t);")
    out.append("\t\t\tmainGroup = %s;" % main_uid)
    out.append("\t\t\tproductRefGroup = %s /* Products */;" % products_uid)
    out.append('\t\t\tprojectDirPath = "";')
    out.append('\t\t\tprojectRoot = "";')
    out.append("\t\t\ttargets = (")
    out.append("\t\t\t\t%s /* %s */," % (target_uid, TARGET_NAME))
    out.append("\t\t\t);")
    out.append("\t\t};")
    out.append("/* End PBXProject section */")
    out.append("")

    # ---------------- PBXResourcesBuildPhase ----------------
    out.append("/* Begin PBXResourcesBuildPhase section */")
    out.append("\t\t%s /* Resources */ = {" % uid("phase", "resources"))
    out.append("\t\t\tisa = PBXResourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append("\t\t\t\t%s /* Localizable.strings in Resources */," % uid("buildfile", "Localizable.strings"))
    for path in resource_paths:
        out.append("\t\t\t\t%s /* %s in Resources */," % (uid("buildfile", path), os.path.basename(path)))
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXResourcesBuildPhase section */")
    out.append("")

    # ---------------- PBXSourcesBuildPhase ----------------
    out.append("/* Begin PBXSourcesBuildPhase section */")
    out.append("\t\t%s /* Sources */ = {" % uid("phase", "sources"))
    out.append("\t\t\tisa = PBXSourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for path in compiled:
        out.append("\t\t\t\t%s /* %s in Sources */," % (uid("buildfile", path), os.path.basename(path)))
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXSourcesBuildPhase section */")
    out.append("")

    # ---------------- XCBuildConfiguration ----------------
    header_paths = ['"$(inherited)"'] + ['"$(SRCROOT)/%s"' % d for d in VENDOR_HEADER_DIRS] \
                   + ['"$(OPENSSL_ROOT)/include"']

    def project_settings(debug):
        s = [
            ("ALWAYS_SEARCH_USER_PATHS", "NO"),
            ("CLANG_ANALYZER_NONNULL", "YES"),
            ("CLANG_CXX_LANGUAGE_STANDARD", '"gnu++14"'),
            ("CLANG_CXX_LIBRARY", '"libc++"'),
            ("CLANG_ENABLE_MODULES", "YES"),
            ("CLANG_ENABLE_OBJC_ARC", "YES"),
            ("CLANG_ENABLE_OBJC_WEAK", "YES"),
            ("CLANG_WARN_BOOL_CONVERSION", "YES"),
            ("CLANG_WARN_CONSTANT_CONVERSION", "YES"),
            ("CLANG_WARN_DIRECT_OBJC_ISA_USAGE", "YES_ERROR"),
            ("CLANG_WARN_EMPTY_BODY", "YES"),
            ("CLANG_WARN_ENUM_CONVERSION", "YES"),
            ("CLANG_WARN_INT_CONVERSION", "YES"),
            ("CLANG_WARN_OBJC_ROOT_CLASS", "YES_ERROR"),
            # Vendor 是十年前的老代码，把这些历史告警降级，避免淹没真正的错误
            ("CLANG_WARN_STRICT_PROTOTYPES", "NO"),
            ("CLANG_WARN_DOCUMENTATION_COMMENTS", "NO"),
            ("CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS", "NO"),
            ("CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF", "NO"),
            ("CLANG_WARN_UNGUARDED_AVAILABILITY", "NO"),
            ("GCC_C_LANGUAGE_STANDARD", "gnu11"),
            ("GCC_NO_COMMON_BLOCKS", "YES"),
            ("GCC_TREAT_WARNINGS_AS_ERRORS", "NO"),
            ("GCC_WARN_ABOUT_RETURN_TYPE", "YES_ERROR"),
            ("GCC_WARN_UNDECLARED_SELECTOR", "YES"),
            ("GCC_WARN_UNUSED_FUNCTION", "NO"),
            ("GCC_WARN_UNUSED_VARIABLE", "NO"),
            ("IPHONEOS_DEPLOYMENT_TARGET", DEPLOYMENT_TARGET),
            ("SDKROOT", "iphoneos"),
            # OpenSSL：EEProvisioning.mm / EESigning.mm / ldid.cpp 都要用。
            # CI 会把交叉编译好的 OpenSSL 放在 /tmp/openssl-ios；
            # 本地构建可以在 xcodebuild 命令行覆盖 OPENSSL_ROOT。
            ("OPENSSL_ROOT", "/tmp/openssl-ios"),
        ]
        if debug:
            s += [
                ("DEBUG_INFORMATION_FORMAT", "dwarf"),
                ("ENABLE_TESTABILITY", "YES"),
                ('GCC_PREPROCESSOR_DEFINITIONS', '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)'),
                ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
                ("ONLY_ACTIVE_ARCH", "YES"),
                ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
                ("SWIFT_OPTIMIZATION_LEVEL", '"-Onone"'),
            ]
        else:
            s += [
                ("COPY_PHASE_STRIP", "NO"),
                ("DEBUG_INFORMATION_FORMAT", '"dwarf-with-dsym"'),
                ("ENABLE_NS_ASSERTIONS", "NO"),
                ("MTL_ENABLE_DEBUG_INFO", "NO"),
                ("MTL_FAST_MATH", "YES"),
                ("SWIFT_COMPILATION_MODE", "wholemodule"),
                ("SWIFT_OPTIMIZATION_LEVEL", '"-O"'),
                ("VALIDATE_PRODUCT", "YES"),
            ]
        return s

    def target_settings(debug):
        s = [
            ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
            ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
            ("CODE_SIGN_ENTITLEMENTS", ENTITLEMENTS),
            ("CODE_SIGN_IDENTITY", '"-"'),
            ("CODE_SIGN_STYLE", "Manual"),
            ("CURRENT_PROJECT_VERSION", CURRENT_PROJECT_VERSION),
            ("DEVELOPMENT_TEAM", '""'),
            ("ENABLE_BITCODE", "NO"),
            ("GENERATE_INFOPLIST_FILE", "NO"),
            ("INFOPLIST_FILE", '"$(SRCROOT)/%s"' % INFOPLIST_FILE),
            ("HEADER_SEARCH_PATHS", "(\n%s\n\t\t\t\t)" % "\n".join("\t\t\t\t\t%s," % p for p in header_paths)),
            ("LD_RUNPATH_SEARCH_PATHS", '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)'),
            ("LIBRARY_SEARCH_PATHS", '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"$(OPENSSL_ROOT)/lib",\n\t\t\t\t)'),
            ("MARKETING_VERSION", MARKETING_VERSION),
            # corecrypto 的头文件在非内部 SDK 下必须关掉 transparent union，
            # 否则 ccsrp.m 编译不过（与原项目 iOS target 设置一致）。
            ("OTHER_CFLAGS", '"-DCORECRYPTO_DONOT_USE_TRANSPARENT_UNION=1"'),
            ("OTHER_LDFLAGS", '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"-lssl",\n\t\t\t\t\t"-lcrypto",\n\t\t\t\t)'),
            ("PRODUCT_BUNDLE_IDENTIFIER", BUNDLE_ID),
            ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
            ("SUPPORTED_PLATFORMS", "iphoneos"),
            ("SUPPORTS_MACCATALYST", "NO"),
            ("SWIFT_EMIT_LOC_STRINGS", "YES"),
            ("SWIFT_OBJC_BRIDGING_HEADER", q(BRIDGING_HEADER)),
            ("SWIFT_VERSION", "5.0"),
            ("TARGETED_DEVICE_FAMILY", '"1,2"'),
        ]
        return s

    def emit_config(cfg_uid, name, settings):
        out.append("\t\t%s /* %s */ = {" % (cfg_uid, name))
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        for key, value in settings:
            out.append("\t\t\t\t%s = %s;" % (key, value))
        out.append("\t\t\t};")
        out.append("\t\t\tname = %s;" % name)
        out.append("\t\t};")

    out.append("/* Begin XCBuildConfiguration section */")
    emit_config(uid("config", "project-debug"), "Debug", project_settings(True))
    emit_config(uid("config", "project-release"), "Release", project_settings(False))
    emit_config(uid("config", "target-debug"), "Debug", target_settings(True))
    emit_config(uid("config", "target-release"), "Release", target_settings(False))
    out.append("/* End XCBuildConfiguration section */")
    out.append("")

    # ---------------- XCConfigurationList ----------------
    out.append("/* Begin XCConfigurationList section */")
    for key, label, debug_uid, release_uid in [
        ("project", 'Build configuration list for PBXProject "%s"' % TARGET_NAME,
         uid("config", "project-debug"), uid("config", "project-release")),
        ("target", 'Build configuration list for PBXNativeTarget "%s"' % TARGET_NAME,
         uid("config", "target-debug"), uid("config", "target-release")),
    ]:
        out.append("\t\t%s /* %s */ = {" % (uid("configlist", key), label))
        out.append("\t\t\tisa = XCConfigurationList;")
        out.append("\t\t\tbuildConfigurations = (")
        out.append("\t\t\t\t%s /* Debug */," % debug_uid)
        out.append("\t\t\t\t%s /* Release */," % release_uid)
        out.append("\t\t\t);")
        out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
        out.append("\t\t\tdefaultConfigurationName = Release;")
        out.append("\t\t};")
    out.append("/* End XCConfigurationList section */")

    out.append("\t};")
    out.append("\trootObject = %s /* Project object */;" % uid("project", "root"))
    out.append("}")
    out.append("")

    return "\n".join(out), files, compiled


def main():
    text, files, compiled = build()
    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print("已生成 %s" % os.path.relpath(OUTPUT, PROJECT_ROOT))
    print("  Swift 源文件      : %d" % len(files["swift"]))
    print("  桥接层源文件      : %d" % len(files["bridge_src"]))
    print("  Vendor 源文件     : %d" % len(files["vendor_src"]))
    print("  参与编译总数      : %d" % len(compiled))
    print("  本地化            : %s" % ", ".join(files["localizations"]))
    print("  打包证书          : %d" % len(files["certs"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
