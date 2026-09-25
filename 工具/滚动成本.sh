#!/bin/zsh
# 滚动成本量具：编真源码 + 驱动真窗口真 ScrollView 按帧节奏滚动，打印每帧主线程忙时
# 用法：bash 工具/滚动成本.sh [静置秒=10] [每种节奏步数=40]
#      bash 工具/滚动成本.sh idle [yes|no]  → 只量「面板开着不滚」的重排级联
set -e

# 备份重定向到临时目录：量具进程一律不许碰用户"主档损坏时的抢救源"
export MIAODIAN_BACKUP_DIR=/tmp/miaodian_scrollcost_backup
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ChargeMonitor/ChargeMonitor"
DEPLOYMENT_TARGET="15.0"
. "$ROOT/工具/sdk选择.sh"   # UI 层要 SwiftUIMacros，与 build.sh 同一套探测

SOURCES=()
while IFS= read -r f; do
	[ "$(basename "$f")" = "ChargeMonitorApp.swift" ] && continue          # 与工具的 @main 冲突
	[ "$(basename "$f")" = "MenuBarPanelController.swift" ] && continue     # 宿主窗口控制器，量具自建窗口
	SOURCES+=("$f")
done < <(find "$SRC" -name '*.swift' | sort)

APP=/tmp/miaodian_scrollcost.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
# UNUserNotificationCenter 要求有效 bundle 上下文（裸二进制会抛 NSException，实测）
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleExecutable</key><string>scrollcost</string>
	<key>CFBundleIdentifier</key><string>fun.crashsystem.MiaoDianScrollCost</string>
	<key>CFBundleName</key><string>MiaoDianScrollCost</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.0.1</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

echo "==> 编译滚动成本量具（${#SOURCES[@]} 个源文件；SDK：$SDK_NOTE）..."
swiftc -O -parse-as-library -swift-version 5 -default-isolation MainActor \
	-target "arm64-apple-macosx$DEPLOYMENT_TARGET" "${SDK_ARGS[@]}" \
	"${SOURCES[@]}" "$ROOT/工具/滚动成本.swift" -o "$APP/Contents/MacOS/scrollcost"
codesign --force -s - "$APP" >/dev/null

# 卡片集要和用户手里一致，否则量的是空面板的滚动（和离屏验收同法，只写临时域）
defaults export fun.crashsystem.ChargeMonitor /tmp/scrollcost-prefs.plist 2>/dev/null \
	&& defaults import fun.crashsystem.MiaoDianScrollCost /tmp/scrollcost-prefs.plist \
	&& rm -f /tmp/scrollcost-prefs.plist \
	&& echo "==> 已导入真实偏好（临时 plist 随即删除，不留全量偏好副本）" \
	|| echo "==> 无主应用偏好可导入，量的是空态面板"

echo "==> 运行（窗口在屏幕外 -6000，不上屏、不抢焦点）..."
"$APP/Contents/MacOS/scrollcost" "$@"
