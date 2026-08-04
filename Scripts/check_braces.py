# 临时校验脚本：检查 ObjC 文件指定方法区间的花括号配平
import re
import sys

path = sys.argv[1]
start = int(sys.argv[2]) if len(sys.argv) > 2 else 1
end = int(sys.argv[3]) if len(sys.argv) > 3 else 10**9

src = open(path, encoding='utf-8').read()
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
str_re = re.compile(r'@"(?:[^"\\]|\\.)*"')

depth = 0
for i, ln in enumerate(src.split('\n'), 1):
    ln2 = str_re.sub('""', ln)
    ln2 = re.sub(r'//.*$', '', ln2)
    for ch in ln2:
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
    if start <= i <= end:
        print(f'L{i:5d} depth={depth:3d} | {ln.strip()[:90]}')
print(f'=== 区间 [{start},{end}] 结束 depth = {depth} ===')
sys.exit(0 if depth == 0 else 1)
