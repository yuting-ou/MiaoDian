#!/bin/zsh
# 离屏验收：编真源码 + 离屏渲染工具，打印面板 fittingSize 并出 PNG（不显示窗口、不抢焦点）
# 用法：bash 工具/离屏验收.sh [宽度pt]
set -e

# 备份重定向到临时目录：量具进程一律不许碰用户"主档损坏时的抢救源"
export MIAODIAN_BACKUP_DIR=/tmp/miaodian_offscreen_backup
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ChargeMonitor/ChargeMonitor"
DEPLOYMENT_TARGET="15.0"
. "$ROOT/工具/sdk选择.sh"   # 与 build.sh 同一套 SDK 能力探测（UI 层要宏插件）

SOURCES=()
while IFS= read -r f; do
	[ "$(basename "$f")" = "ChargeMonitorApp.swift" ] && continue          # 与工具的 @main 冲突
	[ "$(basename "$f")" = "MenuBarPanelController.swift" ] && continue     # 宿主窗口控制器，离屏不需要
	SOURCES+=("$f")
done < <(find "$SRC" -name '*.swift' | sort)

APP=/tmp/miaodian_offscreen.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
# UNUserNotificationCenter 要求有效 bundle 上下文（裸二进制会抛 NSException，实测）：
# 与预览 harness 同路——装进临时 .app、独立 bundle id、ad-hoc 签名后再跑
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleExecutable</key><string>offscreen</string>
	<key>CFBundleIdentifier</key><string>fun.crashsystem.MiaoDianOffscreen</string>
	<key>CFBundleName</key><string>MiaoDianOffscreen</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.0.1</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

echo "==> 编译离屏验收（${#SOURCES[@]} 个源文件；SDK：$SDK_NOTE）..."
swiftc -O -parse-as-library -swift-version 5 -default-isolation MainActor \
	-target "arm64-apple-macosx$DEPLOYMENT_TARGET" "${SDK_ARGS[@]}" \
	"${SOURCES[@]}" "$ROOT/工具/离屏验收.swift" -o "$APP/Contents/MacOS/offscreen"
codesign --force -s - "$APP" >/dev/null

# 导入真实偏好快照到离屏专用域：不导就只有一张空面板（实测 478pt），量不到真实高度；
# 与预览 harness 同法——写只落在临时域，绝不动 fun.crashsystem.ChargeMonitor
defaults export fun.crashsystem.ChargeMonitor /tmp/offscreen-prefs.plist 2>/dev/null \
	&& defaults import fun.crashsystem.MiaoDianOffscreen /tmp/offscreen-prefs.plist \
	&& echo "==> 已导入真实偏好（卡片集与用户一致）" \
	|| echo "==> 无主应用偏好可导入，量的是空态高度"

echo "==> 运行（离屏渲染，不上屏、不抢焦点）..."
"$APP/Contents/MacOS/offscreen" "$@"
