#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
校验 Xcode project.pbxproj（NeXT old-style plist）语法是否合法。

用途：在推送 tag 触发 CI 之前本地先跑一遍，避免 xcodebuild 报
"The project is damaged and cannot be opened due to a parse error"。

用法：
    python Scripts/validate_pbxproj.py [RePro.xcodeproj/project.pbxproj]

退出码 0 表示语法合法。
"""

import sys
import os

# old-style plist 中可以不加引号的裸字符集合
BARE = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$/:.-")


class ParseError(Exception):
    pass


class Parser:
    def __init__(self, text):
        self.s = text
        self.i = 0
        self.n = len(text)

    def line_of(self, pos):
        return self.s.count("\n", 0, pos) + 1

    def error(self, msg):
        ln = self.line_of(self.i)
        ctx = self.s[max(0, self.i - 60):self.i + 60].replace("\n", "\\n")
        raise ParseError("第 %d 行: %s\n    上下文: ...%s..." % (ln, msg, ctx))

    def skip(self):
        """跳过空白与注释"""
        while self.i < self.n:
            c = self.s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif self.s.startswith("/*", self.i):
                end = self.s.find("*/", self.i + 2)
                if end < 0:
                    self.error("块注释未闭合")
                self.i = end + 2
            elif self.s.startswith("//", self.i):
                end = self.s.find("\n", self.i)
                self.i = self.n if end < 0 else end + 1
            else:
                return

    def parse_value(self):
        self.skip()
        if self.i >= self.n:
            self.error("意外结束")
        c = self.s[self.i]
        if c == "{":
            return self.parse_dict()
        if c == "(":
            return self.parse_array()
        if c == '"':
            return self.parse_quoted()
        if c == "<":
            end = self.s.find(">", self.i)
            if end < 0:
                self.error("二进制数据块未闭合")
            self.i = end + 1
            return "<data>"
        return self.parse_bare()

    def parse_quoted(self):
        self.i += 1  # 跳过起始引号
        out = []
        while self.i < self.n:
            c = self.s[self.i]
            if c == "\\":
                out.append(self.s[self.i:self.i + 2])
                self.i += 2
                continue
            if c == '"':
                self.i += 1
                return "".join(out)
            out.append(c)
            self.i += 1
        self.error("字符串未闭合")

    def parse_bare(self):
        start = self.i
        while self.i < self.n and self.s[self.i] in BARE:
            self.i += 1
        if self.i == start:
            self.error("非法字符 %r —— 该值含特殊字符（如 + 空格 等）必须用双引号包裹"
                       % self.s[self.i])
        return self.s[start:self.i]

    def parse_dict(self):
        self.i += 1  # {
        d = {}
        while True:
            self.skip()
            if self.i >= self.n:
                self.error("字典未闭合")
            if self.s[self.i] == "}":
                self.i += 1
                return d
            key = self.parse_quoted() if self.s[self.i] == '"' else self.parse_bare()
            self.skip()
            if self.i >= self.n or self.s[self.i] != "=":
                self.error("键 %r 之后缺少 '='" % key)
            self.i += 1
            val = self.parse_value()
            self.skip()
            if self.i >= self.n or self.s[self.i] != ";":
                self.error("键 %r 的值之后缺少 ';'" % key)
            self.i += 1
            d[key] = val

    def parse_array(self):
        self.i += 1  # (
        arr = []
        while True:
            self.skip()
            if self.i >= self.n:
                self.error("数组未闭合")
            if self.s[self.i] == ")":
                self.i += 1
                return arr
            arr.append(self.parse_value())
            self.skip()
            if self.i < self.n and self.s[self.i] == ",":
                self.i += 1
            elif self.i < self.n and self.s[self.i] == ")":
                continue
            else:
                self.error("数组元素之后缺少 ',' 或 ')'")

    def parse_root(self):
        self.skip()
        if self.s.startswith("// !$*", self.i):
            end = self.s.find("\n", self.i)
            self.i = end + 1 if end >= 0 else self.n
        root = self.parse_value()
        self.skip()
        if self.i != self.n:
            self.error("根对象之后存在多余内容")
        return root


def check_references(root, project_dir):
    """检查所有 PBXFileReference 指向的文件是否真实存在（顺带做完整性检查）"""
    objects = root.get("objects", {})
    refs, groups = {}, {}
    for oid, obj in objects.items():
        if not isinstance(obj, dict):
            continue
        isa = obj.get("isa")
        if isa == "PBXFileReference":
            refs[oid] = obj
        elif isa in ("PBXGroup", "PBXVariantGroup"):
            groups[oid] = obj

    missing = []
    proj = objects.get(root.get("rootObject"), {})
    main_group = proj.get("mainGroup")

    def walk(gid, prefix):
        g = groups.get(gid)
        if not g:
            return
        gp = g.get("path")
        base = os.path.join(prefix, gp) if gp else prefix
        for kid in g.get("children", []):
            if kid in groups:
                walk(kid, base)
            elif kid in refs:
                r = refs[kid]
                p = r.get("path")
                st = r.get("sourceTree")
                if not p or st in ("BUILT_PRODUCTS_DIR", "SDKROOT", "DEVELOPER_DIR"):
                    continue
                full = os.path.normpath(os.path.join(base, p))
                if not os.path.exists(os.path.join(project_dir, full)):
                    missing.append(full)

    if main_group:
        walk(main_group, ".")
    return missing


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "RePro.xcodeproj/project.pbxproj"
    if not os.path.exists(path):
        print("找不到文件: %s" % path)
        return 2

    text = open(path, encoding="utf-8").read()
    try:
        root = Parser(text).parse_root()
    except ParseError as e:
        print("语法错误:\n%s" % e)
        return 1

    n_obj = len(root.get("objects", {}))
    print("语法合法，共解析 %d 个对象" % n_obj)

    project_dir = os.path.dirname(os.path.dirname(os.path.abspath(path)))
    missing = check_references(root, project_dir)
    if missing:
        print("以下被引用的文件在磁盘上不存在 (%d):" % len(missing))
        for m in missing:
            print("  %s" % m)
        return 1
    print("所有文件引用均存在")
    return 0


if __name__ == "__main__":
    sys.exit(main())
