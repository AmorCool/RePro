#!/usr/bin/env python3
"""临时分析脚本：找出 Vendor 源码编译所需的最小 header search path 集合。

libplist 目录里有 String.h / Array.h / Data.h 等与系统头同名的文件，
在大小写不敏感的 macOS 文件系统上，一旦把该目录加进 -I，
`#include <string.h>` 会被错误解析为 libplist 的 String.h。
所以必须精确算出「哪些目录真的需要」，而不是简单地递归 **。
"""
import os
import re
import collections

ROOT = "Vendor/ReProvision"
SRC_EXTS = {".m", ".mm", ".c", ".cpp"}
HDR_EXTS = {".h", ".hpp"}
EXCLUDE_SOURCES = {"ldid.old.cpp"}

SEP = "/"


def norm(p):
    return p.replace(os.sep, SEP)


header_dirs = collections.defaultdict(list)
for dirpath, _, filenames in os.walk(ROOT):
    for name in filenames:
        if os.path.splitext(name)[1] in HDR_EXTS:
            header_dirs[name].append(norm(dirpath))

includes = collections.defaultdict(set)
for dirpath, _, filenames in os.walk(ROOT):
    for name in filenames:
        if name in EXCLUDE_SOURCES:
            continue
        if os.path.splitext(name)[1] not in SRC_EXTS:
            continue
        path = os.path.join(dirpath, name)
        with open(path, encoding="utf-8", errors="ignore") as handle:
            text = handle.read()
        for inc in re.findall(r'#\s*(?:include|import)\s+"([^"]+)"', text):
            includes[inc].add(norm(path))

needed_dirs = set()
unresolved = []
for inc, users in sorted(includes.items()):
    # 先看能否靠「相对于使用者所在目录」解析——这种不需要 -I
    if all(os.path.exists(os.path.join(os.path.dirname(u), inc)) for u in users):
        continue
    base = os.path.basename(inc)
    prefix = os.path.dirname(inc)
    candidates = header_dirs.get(base, [])
    if not candidates:
        unresolved.append((inc, sorted(users)[:3]))
        continue
    for cand in candidates:
        if prefix:
            if cand.endswith(SEP + prefix) or cand == prefix:
                needed_dirs.add(cand[: -(len(prefix) + 1)] or ".")
        else:
            needed_dirs.add(cand)

print("=== 需要加入 HEADER_SEARCH_PATHS 的目录 ===")
for d in sorted(needed_dirs):
    print("   ", d)
print()
print("=== Vendor 内找不到（应由 SDK / OpenSSL 提供）===")
for inc, users in unresolved:
    print("   ", inc, "<-", users)
print()
print("=== 与系统头同名的 Vendor 头（这些目录绝不能进 -I）===")
risky = ["string.h", "time.h", "date.h", "data.h", "array.h", "key.h", "node.h",
         "real.h", "structure.h", "integer.h", "boolean.h", "dictionary.h", "list.h"]
for name, dirs in sorted(header_dirs.items()):
    if name.lower() in risky:
        print("   ", name, "->", dirs)
