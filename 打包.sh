#!/bin/zsh
# 生成可分发 DMG 安装包：构建 → 摆放应用与 /Applications 快捷方式 → 压缩
# 用法：bash 打包.sh（自动先跑 build.sh，保证 DMG 里是最新构建）
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/输出"
APP="$OUT/妙电.app"
VOLNAME="妙电"

# 先构建，保证打进 DMG 的是最新产物（测试门全过才会走到这）
bash "$ROOT/build.sh"

VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([0-9.]*\);/\1/p' "$ROOT/ChargeMonitor/ChargeMonitor.xcodeproj/project.pbxproj" | head -1)"
if [ -z "$VERSION" ]; then
	echo "错误：无法读取版本号" >&2
	exit 1
fi
DMG="$OUT/妙电-$VERSION.dmg"
rm -f "$DMG"

echo "==> 准备临时目录..."
STAGE="$(mktemp -d)"
RW="$OUT/.打包-临时.dmg"
trap 'rm -rf "$STAGE" "$RW"; hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT

cp -R "$APP" "$STAGE/妙电.app"
ln -s /Applications "$STAGE/Applications"

echo "==> 生成可写 DMG 并布置窗口..."
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | sed -n 's/^\(\/dev\/[^[:space:]]*\).*/\1/p' | head -1)"
if [ -z "$MOUNT" ]; then
	echo "错误：DMG 挂载失败" >&2
	exit 1
fi

# 用 Finder 布置图标位置与大小（经典拖拽安装布局）；失败不致命，退回默认布局
osascript <<APPLESCRIPT || echo "警告：图标布局失败，使用默认布局"
tell application "Finder"
	tell disk "$VOLNAME"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 120, 720, 440}
		set arrangement of icon view options of container window to not arranged
		set icon size of icon view options of container window to 96
		set position of item "妙电.app" to {170, 160}
		set position of item "Applications" to {350, 160}
		close
	end tell
end tell
APPLESCRIPT

hdiutil detach "$MOUNT" -quiet

echo "==> 压缩为分发格式..."
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

echo "==> 完成：$DMG"
ls -lh "$DMG" | awk '{print "大小：" $5}'