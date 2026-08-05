#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║ ReSign v1.1.170 真机验证脚本：确认 profile 是否真的落进「真实」        ║
# ║ /var/Managed Preferences/mobile（RootHide 下唯一能验证修复是否有效的   ║
# ║ 办法）。请在 iPhone 上用 SSH（真实 rootfs 上下文）运行本脚本。          ║
# ║                                                                      ║
# ║ 用法：                                                                ║
# ║   1) 在 App 里「触发一次描述文件安装 / 重签」之前，跑： ./diag.sh before║
# ║   2) 去 App 触发安装（重签某个 App 即可），等 5~10 秒                    ║
# ║   3) 再跑： ./diag.sh after  —— 对比前后差异                            ║
# ╚══════════════════════════════════════════════════════════════════════╝

MPDIR="/var/Managed Preferences/mobile"
IPC="/var/mobile/Library/RePro"
RESULT="$IPC/profile-install-result"
PENDING="$IPC/pending-install.mobileprovision"
PROFILE_SRC="$IPC/profile-to-install.mobileprovision"

echo "===== ReSign 真实 rootfs 验证 ($1) @ $(date) ====="

echo
echo "[1] 真实 /var/Managed Preferences/mobile 下的 .mobileprovision 数量："
if [ -d "$MPDIR" ]; then
    ls -la "$MPDIR"/*.mobileprovision 2>/dev/null | wc -l
    echo "    （最近修改的 5 个，按时间倒序）"
    ls -lt "$MPDIR"/*.mobileprovision 2>/dev/null | head -5
else
    echo "    !! 目录不存在：$MPDIR"
fi

echo
echo "[2] /var/mobile/Library/RePro 是否真实可见（不是 overlay）："
echo "    pending-install.mobileprovision 存在？ -> $([ -f "$PENDING" ] && echo YES || echo NO)"
echo "    profile-to-install.mobileprovision 存在？ -> $([ -f "$PROFILE_SRC" ] && echo YES || echo NO)"
echo "    目录内容："
ls -la "$IPC" 2>/dev/null

echo
echo "[3] daemon 安装结果文件（$RESULT）："
if [ -f "$RESULT" ]; then
    echo "    >>> $(cat "$RESULT")"
else
    echo "    （无结果文件，daemon 还没回写 / 未触发）"
fi

echo
echo "[4] profiledaemon 是否已被 launchd 加载："
launchctl list 2>/dev/null | grep -i reprovision || echo "    （无 reprovision 相关条目，可能未加载）"

echo
echo "[5] 最近 daemon 日志（profiledaemon 关键字）："
log show --predicate 'processImagePath contains "repro-profiledaemon"' --last 2m 2>/dev/null | tail -20 \
  || echo "    （log show 不可用，试试：tail -f /var/log/syslog 或 crash_reporter）"

echo
echo "===== 判定 ====="
echo "修复成功 = [1] 数量在 after 比 before 增加（或稳定文件名覆盖旧档），且 [2] pending 文件真实可见。"
echo "若 [1] 没增加 但 [2] 里 pending 也 NO：说明 /var/mobile 被 overlay，jbroot daemon 写的 stage 文件真实侧看不见 → 修复需改机制。"
echo "若 [1] 没增加 且 [2] pending=YES：说明 /bin/cp 没成功落盘（看 [3] 结果文件里的 ERR）。"
