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
EXCLUDED_MACRO=()
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
	if grep -qE '@(State|StateObject|AppStorage|SceneStorage|FocusedValue|EnvironmentObject|Environment|Observable)\b' "$f"; then
		EXCLUDED_MACRO+=("$f")  # 宏宿主编译不了, 排除但必须显式回显, 防静默侵蚀
		continue
	fi
	SOURCES+=("$f")
done < <(find "$SRC" -name '*.swift' | sort)

if [ ${#EXCLUDED_MACRO[@]} -gt 0 ]; then
	echo "==> 宏宿主排除 ${#EXCLUDED_MACRO[@]} 个（清单如下，逻辑层新增宏宿主=架构越界信号）"
	printf '    %s\n' "${EXCLUDED_MACRO[@]}"
fi

# 出口守卫：UI/ 整体不进测试编译面，所以"面板只能经出口取串"这条断言在测试面里
# 结构上无法兑现（v2.9.10 曾误以为兑现了）。改在这里按源文件查：视图层若自己调
# 文案生产者、或干脆不再经出口，构建直接失败。
LEAK="$(grep -rl 'plugShareLine(' "$SRC/UI" 2>/dev/null || true)"
if [ -n "$LEAK" ]; then
	echo "==> 出口守卫失败：UI 层自己取了说明文案（应只经 DwellTracking.noteLines）"
	printf '    %s\n' $LEAK
	exit 1
fi
BYPASS="$(grep -rl 'summaryLines(' "$SRC/UI" 2>/dev/null || true)"
if [ -n "$BYPASS" ]; then
	echo "==> 出口守卫失败：UI 层绕开 noteLines 直取驻留行（高度会与渲染脱钩）"
	printf '    %s\n' $BYPASS
	exit 1
fi
if ! grep -q 'DwellTracking.noteLines' "$SRC/UI/DailySummarySection.swift" 2>/dev/null; then
	echo "==> 出口守卫失败：今日用电卡不再经 noteLines，说明行与声明高度失去同源"
	exit 1
fi
echo "==> 出口守卫：说明文案只经 noteLines（UI 层已按源文件核对）"
# 上限两侧共用：渲染侧必须经 PanelCardHeights.visibleInsightLines 取上限。
# UI/ 不进测试面，"两侧共用一个常量"这种主张只能按源文件查（v2.9.14 审查抓到我没做这点）。
if ! grep -q 'prefix(PanelCardHeights.visibleInsightLines)' "$SRC/UI/TrendAndCalendarSections.swift" 2>/dev/null; then
	echo "==> 上限守卫失败：洞察卡渲染侧不再经 visibleInsightLines 取上限（配平与渲染会分叉）"
	exit 1
fi
# 只查洞察卡所在文件：另一处 prefix(3) 属于高耗电应用卡，是另一个上限（见其 min(3,...) 项）
STRAY="$(grep -n 'prefix(3)' "$SRC/UI/TrendAndCalendarSections.swift" 2>/dev/null || true)"
if [ -n "$STRAY" ]; then
	echo "==> 上限守卫失败：洞察卡渲染侧写死 prefix(3)，与登记表上限脱钩"
	printf '    %s\n' $STRAY
	exit 1
fi
echo "==> 上限守卫：洞察渲染上限与配平同源（UI 层已按源文件核对）"

# 动效门守卫：头部墙钟动画是**登记表**，不是"越多越好"——
# 期望值写死：5 处 TimelineView（呼吸点／波面／弧端流光／热脉冲／低电呼吸），
# 其中 3 处（充电通道：呼吸点／波面／弧端流光）必须经 holdsDecorativeAnimation 停帧；
# 警示通道那 2 处刻意**不**进门（节奏本身就是信息，见 PanelMotionGate 的说明）。
# 所以"门控数 = 动画数"这种相等式是错的：它会把该豁免的两处也逼进门里。
# 计数用 grep -o | wc -l：grep -c 数的是行（一行两处会漏），且无匹配时退出码 1
# ——那会让 "[ x -lt 1 ]" 整型比较报错、if 判假、守卫反而打印"通过"（第一轮就假绿过一次）。
HEADER_UI="$SRC/UI/BatteryHeaderView.swift"
TICKS="$(grep -o 'TimelineView(' "$HEADER_UI" 2>/dev/null | wc -l | tr -d '[:space:]')"
GATES="$(grep -o 'PanelMotionGate.holdsDecorativeAnimation(isScrolling: scrollActivity.isScrolling)' "$HEADER_UI" 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "${TICKS:-0}" != "5" ] || [ "${GATES:-0}" != "3" ]; then
	echo "==> 动效门守卫失败：头部墙钟动画 $TICKS 处（期望 5）、滚动门控 $GATES 处（期望 3=充电三处；警示两处必须豁免）"
	exit 1
fi
echo "==> 动效门守卫：头部墙钟动画 5 处、其中充电 3 处经滚动门控（警示 2 处按规矩豁免）"

# 单一出口守卫：v2.9.16 收口的 #20 起源于"同一判断抄了两遍"——面板传全 8 条来源、
# 资格侧只传 5 条，于是"面板出着洞察卡、资格集判无数据"，那张卡没落进 rows，
# 被 PanelFlow.normalize 追加到行表尾 → 甩在面板最底独占整行，连「极简」都赶不走它。
# 参数表已改成全部必填（漏传=编译错误），这条守卫管的是另一半：**不许再抄一遍组装形状**——
# 面板与设置两侧必须各自出现对 HabitInsights 的真实调用（不是注释里提一句名字）。
# 注：模式必须转义 `.`，否则注释里的"（HabitInsights）"也算命中（审查 round2 实测到这条假绿）。
LEAKY_INSIGHT="$(grep -rl 'chargingInsights(' "$SRC" 2>/dev/null \
	| grep -v 'Utilities/UsagePatternAnalyzer.swift$' | grep -v 'Utilities/HabitInsightAssembly.swift$' || true)"
if [ -n "$LEAKY_INSIGHT" ]; then
	echo "==> 单一出口守卫失败：有人绕过 HabitInsights 自己拼洞察参数表（新增来源时这条会漏）"
	printf '    %s\n' $LEAKY_INSIGHT
	exit 1
fi
if ! grep -qE 'HabitInsights\.assemble\(HabitInsightInputs\(' "$SRC/UI/BatteryPopoverView.swift" 2>/dev/null; then
	echo "==> 单一出口守卫失败：面板洞察卡不再经 HabitInsights.assemble，资格与内容会脱钩"
	exit 1
fi
if ! grep -qE 'facts\.hasHabitInsight *= *HabitInsights\.hasAny\(' "$SRC/Settings/SettingsView.swift" 2>/dev/null; then
	echo "==> 单一出口守卫失败：设置侧资格不再把 facts 交给 HabitInsights.hasAny，会与面板内容重新分叉"
	exit 1
fi
echo "==> 单一出口守卫：洞察组装只经 HabitInsights（面板与设置同调一处，且必须是真调用）"

# 测试面用默认 SDK（不钉旧）：逻辑层排除了宏宿主与 UI，不需要 SwiftUIMacros 插件，
# 因此这份信号反映的正是本机最新 SDK 下逻辑层的真实编译状态——与 build.sh 为 UI 层
# 钉的旧 SDK 是两条独立证据，回显版本免得把两者的结论混着读。
TEST_SDK_PATH="$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || true)"
TEST_SDK_VERSION="$(plutil -extract Version raw "$TEST_SDK_PATH/SDKSettings.plist" 2>/dev/null || echo '?')"
echo "==> 编译测试（源文件 ${#SOURCES[@]} 个 + 测试用例；SDK：默认 macOS $TEST_SDK_VERSION）..."
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
