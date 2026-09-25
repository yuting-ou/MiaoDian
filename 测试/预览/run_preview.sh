#!/bin/zsh
# 液态玻璃预览 harness：编译真源码 + 预览入口，产出可截图的半透明窗口应用。
# 独立 bundle ID（fun.crashsystem.MiaoDianPreview）：UserDefaults 与主应用隔离。
# ⚠ **历史备份目录不吃 bundle id**（硬编码在 App Support/ChargeMonitor），所以这个脚本必须
#   export MIAODIAN_BACKUP_DIR 把备份改道到临时目录（见 BatteryHistoryRecorder.backupDirectoryForTooling）。
#   只改本 harness 自己那台 recorder 的构造不够——面板渲染会经 GlassStyle 触发 AppServices.shared，
#   它内部还有一台走默认路径的 recorder。
# 再把真实偏好快照 import 进来，渲染有数据的面板。
# 用法：bash 测试/预览/run_preview.sh && open /tmp/miaodian_preview/妙电预览.app
# 验收完：pkill -x preview && defaults delete fun.crashsystem.MiaoDianPreview
set -e

# 预览进程一律不许碰用户"主档损坏时的抢救源"：把备份重定向到临时目录
export MIAODIAN_BACKUP_DIR=/tmp/miaodian_preview_backup

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/ChargeMonitor/ChargeMonitor"
OUT="/tmp/miaodian_preview"
APP="$OUT/妙电预览.app"
BUNDLE_ID="fun.crashsystem.MiaoDianPreview"
DEPLOYMENT_TARGET="15.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# 与测试 harness 同款收集：排除 @main 入口（与预览 main.swift 冲突）
SOURCES=()
while IFS= read -r f; do
	[ "$(basename "$f")" = "ChargeMonitorApp.swift" ] && continue
	SOURCES+=("$f")
done < <(find "$SRC" -name '*.swift' | sort)

echo "==> 编译预览（源文件 ${#SOURCES[@]} 个 + 预览入口）..."
# SDK 与主构建同源探测（预览编的是真 UI 源码，宏插件缺失同样必挂），见 工具/sdk选择.sh
. "$ROOT/工具/sdk选择.sh"
echo "    SDK：$SDK_NOTE"
swiftc \
	-swift-version 5 \
	-default-isolation MainActor \
	-target "arm64-apple-macosx$DEPLOYMENT_TARGET" \
	"${SDK_ARGS[@]}" \
	"${SOURCES[@]}" \
	"$ROOT/测试/预览/main.swift" \
	-o "$APP/Contents/MacOS/preview"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>preview</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>妙电预览</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.0.1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 真实偏好快照导入预览域：面板渲染有数据；预览进程的写入只落在预览自己的域
defaults export fun.crashsystem.ChargeMonitor "$OUT/prefs-snapshot.plist" 2>/dev/null \
	&& defaults import "$BUNDLE_ID" "$OUT/prefs-snapshot.plist" \
	|| echo "（无主应用偏好可导入，预览将显示冷启动空态）"

# UNUserNotificationCenter 要求有效 bundle 上下文，ad-hoc 签名与主应用同路
codesign --force -s - "$APP"

echo "==> 产物：$APP —— open 后截图验收，完事 pkill -x preview && defaults delete $BUNDLE_ID"
