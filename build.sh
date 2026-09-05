#!/bin/zsh
# 妙电（ChargeMonitor 汉化版）构建脚本
# 无需完整 Xcode，仅需 Command Line Tools；产物为 universal binary（arm64 + x86_64）
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/ChargeMonitor/ChargeMonitor"
OUT="$ROOT/输出"
APP="$OUT/妙电.app"
# 部署目标保持 15.0：液态玻璃（glassEffect 为 macOS 26 API）用 #available 双路径，
# 26 走玻璃、15–25 保留原 PopoverCard 质感降级——妙电已开源，覆盖面是资产
DEPLOYMENT_TARGET="15.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 版本号单一来源：Xcode 工程的 MARKETING_VERSION
VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([0-9.]*\);/\1/p' "$ROOT/ChargeMonitor/ChargeMonitor.xcodeproj/project.pbxproj" | head -1)"
if [ -z "$VERSION" ]; then
	echo "错误：无法从 project.pbxproj 读取 MARKETING_VERSION" >&2
	exit 1
fi
echo "==> 版本：$VERSION"

# 动态收集源文件，新增/重命名无需手改清单（bash/zsh 通用写法）
SOURCES=()
while IFS= read -r f; do
	SOURCES+=("$f")
done < <(find "$SRC" -name '*.swift' | sort)
if [ ${#SOURCES[@]} -eq 0 ]; then
	echo "错误：未在 $SRC 找到任何 Swift 源文件" >&2
	exit 1
fi
echo "==> 源文件：${#SOURCES[@]} 个"

echo "==> 测试门：先编译并运行单元测试（与主程序共用源文件，测的是真代码）..."
bash "$ROOT/测试/run_tests.sh"

echo "==> 编译 Swift 源码（universal：arm64 + x86_64）..."
SLICES=()
for ARCH in arm64 x86_64; do
	SLICE="$OUT/.妙电-slice-$ARCH"
	swiftc -O \
		-parse-as-library \
		-swift-version 5 \
		-default-isolation MainActor \
		-target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
		"${SOURCES[@]}" \
		-o "$SLICE"
	SLICES+=("$SLICE")
done
lipo -create -output "$APP/Contents/MacOS/ChargeMonitor" "${SLICES[@]}"
rm -f "${SLICES[@]}"

echo "==> 生成 Info.plist..."
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>ChargeMonitor</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>fun.crashsystem.ChargeMonitor</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>妙电</string>
	<key>CFBundleDisplayName</key>
	<string>妙电</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>${DEPLOYMENT_TARGET}</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

if [ -f "$ROOT/AppIcon.icns" ]; then
	cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 临时签名（本机运行）..."
codesign --force --deep -s - "$APP"

echo "==> 完成：$APP"
