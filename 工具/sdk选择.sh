# 共享片段：只被 source（build.sh / 测试/预览/run_preview.sh），不单独执行；
# 内部用到数组，宿主须为 bash 或 zsh（两脚本均是）。
# SDK 能力探测（供 build.sh 与 测试/预览/run_preview.sh source 共用，bash/zsh 通用写法）
#
# 为什么探测而不猜路径名：SDK 27 起 SwiftUI 的属性包装器（@State 等）改为宏实现，
# 编译 UI 层必须有 SwiftUIMacros 宏插件；CLT 27 的工具链不带它（实测：插件目录只有
# libSwiftMacros/libObservationMacros，显式 -load-plugin-library 也补不上 SwiftUIMacros
# 模块），而完整 Xcode 带。同时 SDK 26.x 的 SwiftUI 仍是 property wrapper 实现，不需要
# 插件。这三件事的组合随环境翻盘（装 Xcode／未来的 CLT 补回插件／机器上留了哪个旧 SDK），
# 所以按"是否 CommandLineTools 路径"判断会猜错两种情况：
#   ① 干净的 CLT 27（没有 26.5 遗留）→ 旧逻辑走默认 SDK，UI 层带着宏错误崩在编译中途；
#   ② 未来的 CLT 带了插件 → 旧逻辑继续钉 26.5，白白丢掉新 SDK 的编译信号。
# 直接问编译器最省事：拿 @State 最小探针试编，编得过的那个 SDK 才是可用的。
#
# 约定：调用方先设 DEPLOYMENT_TARGET；source 后得到数组 SDK_ARGS 与字符串 SDK_NOTE；
# 一个都编不过时打印可执行指引并 exit 1（绝不让必挂的配置往下走）。

PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROBE_DIR"' EXIT
printf 'import SwiftUI\n\nstruct Probe: View {\n\t@State private var count = 0\n\tvar body: some View { Text("\\(count)") }\n}\n' > "$PROBE_DIR/probe.swift"

sdk_version() {  # $1 = SDK 路径 → 版本号（取不到打 ?）
	plutil -extract Version raw "$1/SDKSettings.plist" 2>/dev/null || echo '?'
}

_probe_passes() {  # $1 = SDK 路径（空串 = 默认 SDK）；@State 宏编得过即返回 0
	_args=()
	[ -n "$1" ] && _args=(-sdk "$1")
	swiftc -typecheck -parse-as-library \
		-swift-version 5 -default-isolation MainActor \
		-target "arm64-apple-macosx$DEPLOYMENT_TARGET" \
		"${_args[@]}" "$PROBE_DIR/probe.swift" >/dev/null 2>&1
}

DEVSDK_DIR="$(xcode-select -p)/SDKs"
SDK_ARGS=()
SDK_NOTE=""
if _probe_passes ""; then
	SDK_NOTE="默认（macOS $(sdk_version "$(xcrun --show-sdk-path --sdk macosx)")）：SwiftUI 宏可用"
else
	# 版本从新到旧试各版本化 SDK（MacOSX.sdk 是指向最新的符号链接，无版本号故排除）
	for _ver in $(ls "$DEVSDK_DIR" 2>/dev/null | sed -n 's/^MacOSX\([0-9][0-9.]*\)\.sdk$/\1/p' | sort -rn -t. -k1,1 -k2,2 || true); do
		if _probe_passes "$DEVSDK_DIR/MacOSX$_ver.sdk"; then
			SDK_ARGS=(-sdk "$DEVSDK_DIR/MacOSX$_ver.sdk")
			SDK_NOTE="MacOSX$_ver.sdk（钉旧 SDK：默认 SDK 的 SwiftUI 宏在本机工具链上编不过）"
			break
		fi
	done
fi

if [ -z "$SDK_NOTE" ]; then
	echo "错误：本机工具链无法编译 SwiftUI（@State 宏探测在默认 SDK 与下列 SDK 上全失败）：" >&2
	_CANDS="$(ls "$DEVSDK_DIR" 2>/dev/null | grep -E '^MacOSX[0-9][0-9.]*\.sdk$' | sed 's/^/      /' || true)"
	if [ -n "$_CANDS" ]; then
		echo "$_CANDS" >&2
	else
		echo "      （$DEVSDK_DIR 下没有可回落的版本化 SDK）" >&2
	fi
	echo "  修法（任一即可）：" >&2
	echo "    1. 安装完整 Xcode（自带 SwiftUIMacros 插件）后重跑；" >&2
	echo "    2. 装带 26.x SDK 的 Command Line Tools（26.x 的 SwiftUI 仍是 property wrapper，不依赖宏插件）。" >&2
	echo "  手工复现：swiftc -typecheck -parse-as-library $PROBE_DIR/probe.swift" >&2
	exit 1
fi
