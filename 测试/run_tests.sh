#!/bin/zsh
# 妙电 单元测试：与主程序共用同一批源文件编译，测的是真代码
# 用法：bash 测试/run_tests.sh
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ChargeMonitor/ChargeMonitor"
OUT="$ROOT/.build-tests"
# 测试跑在当前机器上（arm64），部署目标与主程序保持一致，可用性检查同源
DEPLOYMENT_TARGET="15.0"

mkdir -p "$OUT"

# 收集除 @main 入口外的全部源文件（入口与测试的 main.swift 冲突）
SOURCES=()
while IFS= read -r f; do
	[ "$(basename "$f")" = "ChargeMonitorApp.swift" ] && continue
	# SwiftUIMacros(@State 等)需要 macro plugin; CLT-only 工具链(缺 Xcode)会全挂。
	# 单元测试目标是逻辑层(Models/Services/Utilities/Core 渲染器): UI 视图与
	# 面板控制器层动态排除——UI/ 全目录、import SwiftUI 的 Core/Settings 文件、
	# 以及含 macro 的文件都不进测试编译面。逻辑文件今后 import SwiftUI 需过测试门。
	case "$f" in
		*/UI/BatteryInfoFormatter.swift) ;;  # 逻辑格式化器(放错在 UI/), 白名单进测试面
		*/UI/*) continue ;;                  # 其余视图层与 macro 文件互耦, 全排
		*/Core/ChargeCurveWindowController.swift) continue ;;  # 窗口控制器, 引用 UI/ 的 Host 视图
	esac
	grep -qE '@(State|StateObject|AppStorage|SceneStorage|FocusedValue|EnvironmentObject)\b' "$f" && continue
	SOURCES+=("$f")
done < <(find "$SRC" -name '*.swift' | sort)

echo "==> 编译测试（源文件 ${#SOURCES[@]} 个 + 测试用例）..."
swiftc \
	-swift-version 5 \
	-default-isolation MainActor \
	-target "arm64-apple-macosx$DEPLOYMENT_TARGET" \
	"${SOURCES[@]}" \
	"$ROOT/测试/main.swift" \
	-o "$OUT/tests"

echo "==> 运行测试..."
# 桌面沙盒(MiMo Desktop)seatbelt 禁 exec 用户目录自编译产物(Operation not permitted),
# 该环境下降级为编译层验证: swiftc -typecheck 全测试面等价于上面的 -o 已通过。
# 终端等无沙盒环境走完整链路: 编译 + 运行断言。
rc=0
"$OUT/tests" 2>/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then
	echo "==> 测试通过（完整链路）"
elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
	# 沙盒禁 exec(EPERM→126): 编译已通过(-o 成功), 测试运行结构性不可用, 不渲染成通过
	echo "==> [降级] 沙盒禁 exec 自编译产物: 编译层已验证(swiftc -o 全过), 断言层未跑"
	echo "==> 在无沙盒终端跑本脚本可执行完整断言"
else
	echo "==> 测试失败: $rc 条断言未过"
	exit "$rc"
fi
