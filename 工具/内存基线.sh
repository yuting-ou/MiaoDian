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
#      bash 工具/内存基线.sh gate [app路径] [上限MB=95]          # 门禁模式：超线即 exit 1
#
# 门禁为什么不接进 build.sh 而接进发版流程：run_case 会 `pkill -TERM ChargeMonitor` 再 `open`
# 被测包——把它放进每次构建的前置门，等于每次编译都把用户正在跑的妙电杀掉重启一遍。
# 这个副作用不该由"我改了行代码"触发，只该由"我要发版"触发。故 gate 模式挂在必跑的
# 发版链（打包.sh / 发版清单）上，而非 build.sh 的测试门前。
set -e
MODE="${1:-measure}"
if [ "$MODE" = "gate" ]; then
	TARGET="${2:-/Applications/妙电.app}"
	LIMIT_MB="${3:-95}"
	[ -d "$TARGET" ] || { echo "gate: 找不到被测包 ${TARGET}"; exit 1; }
	pkill -TERM -x ChargeMonitor 2>/dev/null || true
	sleep 2
	open "$TARGET"
	sleep 25
	GATE_PID=$(pgrep -x ChargeMonitor | head -1)
	[ -z "$GATE_PID" ] && { echo "gate: 进程没起来"; exit 1; }
	GATE_VER=$(plutil -extract CFBundleShortVersionString raw -o - "$TARGET/Contents/Info.plist")
	FAIL=0
	for STAMP in 0.5 2; do
		if [ "$STAMP" = "0.5" ]; then WAIT=5; else WAIT=90; fi
		sleep "$WAIT"
		GATE_RSS=$(( $(ps -o rss= -p "$GATE_PID" | tr -d ' ') / 1024 ))
		if [ "$GATE_RSS" -gt "$LIMIT_MB" ]; then
			echo "  ✗ t+${STAMP}min RSS ${GATE_RSS}MB > 上限 ${LIMIT_MB}MB（v${GATE_VER}）"
			FAIL=1
		else
			echo "  ✓ t+${STAMP}min RSS ${GATE_RSS}MB ≤ 上限 ${LIMIT_MB}MB（v${GATE_VER}）"
		fi
	done
	if [ "$FAIL" -eq 0 ]; then echo "gate 通过：${TARGET}"; fi
	echo "口径：冷启动 + 面板不开 + 定点采样；连跑三次取最好状态那条才算基线（机器状态会漂）。"
	exit "$FAIL"
fi
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
