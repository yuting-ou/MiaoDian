#!/bin/zsh
# 三壁纸可读性一键实测（仅开发工具）：浅/深/花各设壁纸→程序化开面板→CGWindowList 读面板边界→测三区对比度→存档。
# 用法：bash 工具/壁纸实测.sh   （需屏幕点亮；结束后自动恢复原壁纸）
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/glass/after"
mkdir -p "$OUT"
APP="/Applications/妙电.app/Contents/MacOS/ChargeMonitor"

ORIG=$(osascript -e 'tell application "System Events" to tell desktop 1 to get picture' 2>/dev/null || echo "")

run_case() {
	local name=$1 wp=$2
	osascript -e "tell application \"System Events\" to tell every desktop to set picture to \"$wp\""
	sleep 2
	pkill -TERM -x ChargeMonitor 2>/dev/null || true
	sleep 1
	(MIAODIAN_DEBUG_OPEN_PANEL=1 "$APP" > /dev/null 2>&1 &)
	sleep 5
	# 面板边界（点，左上原点）→ 像素 ×2；不依赖日志，CGWindowList 直读
	local bounds px py
	bounds=$(/tmp/panelbounds) || { echo "== $name 面板未找到 =="; return; }
	px=$(( ${bounds%% *} * 2 ))
	py=$(echo "$bounds" | awk '{print $2 * 2}')
	screencapture -x "/tmp/wp_$name.png"
	cp "/tmp/wp_$name.png" "$OUT/panel-wp-$name.png"
	echo "== $name 面板像素锚点 ($px,$py) =="
	/tmp/contrast "/tmp/wp_$name.png" $((px+60)) $((py+488)) 1028 540 | sed 's/^/  充电协议卡: /'
	/tmp/contrast "/tmp/wp_$name.png" $((px+240)) $((py+80)) 600 200 | sed 's/^/  头部大数字: /'
	/tmp/contrast "/tmp/wp_$name.png" $((px+60)) $((py+1400)) 1028 480 | sed 's/^/  电源事件区: /'
}

run_case light /tmp/wp_light.png
run_case dark /tmp/wp_dark.png
run_case colorful /tmp/wp_colorful.png

if [ -n "$ORIG" ]; then
	osascript -e "tell application \"System Events\" to tell every desktop to set picture to \"$ORIG\""
	echo "已恢复原壁纸"
fi
pkill -TERM -x ChargeMonitor 2>/dev/null || true
sleep 1
open /Applications/妙电.app
echo "完成：截图在 $OUT/"
