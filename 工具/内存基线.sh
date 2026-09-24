#!/bin/zsh
# 内存基线：妙电进程 RSS 的**可复跑口径**。
#
# 为什么要有这个脚本：2026-09-24 我拿两个不同条件下量的单点 RSS（30MB vs 80MB）当"版本回归"，
# 白起一轮疑点。同口径 A/B 一测，v2.9.12 与 v2.9.13 分别是 79/70 与 79/71MB——差在噪声里。
# 教训：单点 RSS 不可跨条件比较（面板开过、刚解码完、系统回收都会动它）。
#
# 口径：冷启动（先杀旧进程）→ 面板不开 → 在 t+0.5min 与 t+2min 各采一次。
# 用法：bash 工具/内存基线.sh                 # 量 /Applications 里那个
#      bash 工具/内存基线.sh /path/MiaoDian.app /path/old.dmg   # 前者与 dmg 内版本 A/B
set -e
TARGET="${1:-/Applications/妙电.app}"
DMG="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

sample() {  # $1 label, $2 pid
	local rss
	rss=$(ps -o rss= -p "$2" | tr -d ' ')
	echo "  $1: RSS $((rss / 1024))MB"
}

run_case() {  # $1 label, $2 app path
	local pid ver
	pkill -TERM -x ChargeMonitor 2>/dev/null || true
	sleep 2
	open "$2"
	sleep 25
	pid=$(pgrep -x ChargeMonitor | head -1)
	[ -z "$pid" ] && { echo "$1: 进程没起来"; return 1; }
	ver=$(plutil -extract CFBundleShortVersionString raw -o - "$2/Contents/Info.plist")
	echo "$1 (v$ver)"
	sample "t+0.5min" "$pid"
	sleep 90
	sample "t+2min " "$pid"
}

if [ -n "$DMG" ]; then
	AB=$(mktemp -d /tmp/miaodian-ab.XXXX)
	rm -rf "$AB/妙电.app"
	MNT=$(hdiutil attach "$DMG" -nobrowse -readonly | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
	ditto "$MNT/妙电.app" "$AB/妙电.app"
	# A/B 之后再量一次原目标，用来判断这台机器的漂移幅度
	run_case "A 被测   " "$TARGET" || true
	run_case "B 对照   " "$AB/妙电.app" || true
	run_case "C 复测A  " "$TARGET" || true
	hdiutil detach "$MNT" -quiet || true
	rm -rf "$AB"
else
	run_case "冷启动基线" "$TARGET" || true
fi
echo "口径：冷启动 + 面板不开 + 定点采样；跨条件比单点数字不算证据。"
