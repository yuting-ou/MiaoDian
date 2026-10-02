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

# 源文件级守卫：UI/ 不进测试编译面，这些主张只能在源码文本上兑现。
# 收成一个函数是为了能在**变异副本**上复跑一次——见文件末尾的元守卫。
run_source_guards() {
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

	# 淡变白名单守卫（轮17）：面板一次数据发布的 ~830 轮布局来自"在飞的值淡变"——
	# 一条 .animation(_:value:) 在动，宿主就按帧重跑整树布局（同进程配对实测 830 轮/358ms → 2 轮/82ms）。
	# 所以"哪些行淡变"是性能口径，不是审美细节。UI/ 不进测试编译面，接线只能按源文件查：
	# ① 视图层必须真的按标记取动画（删掉这处 = 标记变成死字段，性能回归没人报警）；
	# ② 每拍重算的读数登记数写死 6 条（多一条=白损观感，少一条=级联回来）；
	# ③ 两条迷你曲线副标题（每拍刷新）不许再挂 value 动画。
	# 计数一律 grep -o | wc -l（grep -c 数行、一行两处会漏），模式里的点全部转义，
	# 并且**剔掉以 // 开头的行**——否则有人把真调用删掉、留一行写着同样内容的注释，守卫照样绿
	# （v2.9.16 审查实测过这条假绿）。
	ROW_UI="$SRC/UI/Components/PopoverComponents.swift"
	ROW_CALLS="$(grep -E '\.animation\(item\.animatesOnChange \? \.easeInOut\(duration: PanelMotion\.valueFadeSeconds\) : nil, value: item\.value\)' "$ROW_UI" 2>/dev/null | grep -vE '^[[:space:]]*//' | wc -l | tr -d '[:space:]')"
	if [ "${ROW_CALLS:-0}" != "1" ]; then
		echo "==> 淡变守卫失败：信息行没有真的按 item.animatesOnChange 取动画（命中 $ROW_CALLS 处，期望 1 处代码；标记成了死字段则级联无人挡）"
		exit 1
	fi
	CHART_TICKS="$(grep -o 'value: currentText' "$SRC/UI/MiniChartSections.swift" 2>/dev/null | wc -l | tr -d '[:space:]')"
	if [ "${CHART_TICKS:-0}" != "0" ]; then
		echo "==> 淡变守卫失败：迷你曲线副标题重新挂了 value 动画 $CHART_TICKS 处（该值每 2 秒就变）"
		exit 1
	fi
	echo "==> 淡变守卫：视图层按标记取动画、曲线副标题零 value 动画（登记表条数改由测试断言钉，见「淡变登记表完备性」）"

	# 字阶守卫（轮19）：字阶与字重预算是**写死的设计纪律**，不是"越多越好"——
	# 层次由字号/颜色/位置承担，字重是最后手段。两条硬线：
	# ① 面板与设置窗里不许出现 .bold（圆角设计本身有辨识度，bold 只是噪音）；
	# ② 信息行的值必须走 PanelText.primary（那 19 行是全屏最显眼的文字，曾整批 semibold）。
	# 计数一律 grep -o | wc -l，并剔掉注释行（v2.9.16 假绿教训）。
	BOLD="$(grep -rE 'weight: \.bold' "$SRC/UI" "$SRC/Settings" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | wc -l | tr -d '[:space:]')"
	if [ "${BOLD:-0}" != "0" ]; then
		echo "==> 字阶守卫失败：面板/设置里还有 $BOLD 处 .bold（字重预算只到 semibold，且仅限区块标题/头部主数字/表格值列/按钮标题）"
		grep -rnE 'weight: \.bold' "$SRC/UI" "$SRC/Settings" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | sed 's/^/    /'
		exit 1
	fi
	ROW_CALL="$(grep -E 'size: PanelText\.primary, weight: \.regular' "$SRC/UI/Components/PopoverComponents.swift" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | wc -l | tr -d '[:space:]')"
	if [ "${ROW_CALL:-0}" != "1" ]; then
		echo "==> 字阶守卫失败：信息行的值没有真的走 PanelText.primary/regular（命中 $ROW_CALL 处，期望 1 处代码；删掉留注释同样算失败）"
		exit 1
	fi
	echo "==> 字阶守卫：无 .bold、信息行值走 PanelText.primary/regular（字重预算写死）"

	# 空态守卫（轮19）：卡片全被藏掉时，卡片区原来整块塌成 0 高度——面板变成「头部 + 一片虚空
	# + 控制行」，像坏了一样。空态视图 + 判据都必须还在，且判据必须是 cardIDs 而不是 segments
	# （单列路径下 segments 恒为 []，拿它当判据会把单列卡片列表整个换成空态——这个 bug 我犯过）。
	if ! grep -q 'emptyCardsState' "$SRC/UI/BatteryPopoverView.swift" 2>/dev/null; then
		echo "==> 空态守卫失败：没有空态视图了（无卡片时面板会剩一片虚空）"
		exit 1
	fi
	EMPTY_COND="$(grep -E 'if cardIDs\.isEmpty, !isEditingLayout' "$SRC/UI/BatteryPopoverView.swift" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | wc -l | tr -d '[:space:]')"
	if [ "${EMPTY_COND:-0}" != "1" ]; then
		echo "==> 空态守卫失败：空态判据被改坏（命中 $EMPTY_COND 处，期望 1 处；必须按 cardIDs 判，按 segments 判会误伤单列）"
		exit 1
	fi
	echo "==> 空态守卫：无卡片有空态、判据按 cardIDs（不误伤单列）"

	# 存储决策守卫：门面的 init 必须**经 resolvedByteStore** 决定历史存储。
	# 起因：这里曾写 `store ?? InMemoryHistoryByteStore()`，把"关备份"和"不落盘"耦合成一个默认值，
	# 三个量具的历史一起变空（离屏面板 1017→477pt、真档案腿整条跳过）。
	# 行为断言只能测 resolvedByteStore 自己，测不到 init 有没有调它——那半只能在源码上查。
	DECISION="$(grep -c 'Self\.resolvedByteStore(override: store, defaults: defaults)' "$SRC/Services/BatteryHistoryRecorder.swift" 2>/dev/null | tr -d '[:space:]')"
	# 剔注释行：这条守卫自己在注释里写了旧写法，不剔就会自我触发（正是 v2.9.16 那条假绿的镜像形态）
	LEGACY="$(grep -E 'store \?\? InMemoryHistoryByteStore\(\)' "$SRC/Services/BatteryHistoryRecorder.swift" 2>/dev/null | grep -vE '^[[:space:]]*//' | wc -l | tr -d '[:space:]')"
	if [ "${DECISION:-0}" != "1" ] || [ "${LEGACY:-0}" != "0" ]; then
		echo "==> 存储决策守卫失败：init 没有经 resolvedByteStore 决策（命中 $DECISION 处，期望 1；旧写法残留 $LEGACY 处，期望 0）"
		echo "    这条守的是「关备份」不许顺手把历史也清空——量具与单测都靠它拿到真历史"
		exit 1
	fi
	echo "==> 存储决策守卫：历史存储只经 resolvedByteStore（关备份≠不落盘）"

	# clock 接线守卫：门面必须把**同一个** clock 传给全部 7 个域。
	# 行为断言说服不了这件事——少传一个域，那个域继续吃真实 Date()，测试却在推进假钟，
	# 断言就按运气红绿（本项目最恨的那种）。这条只能按源码核对。
	# 剔注释行照 v2.9.16 那条假绿教训：注释里写过模式名，不剔会自我触发。
	CLOCK_HITS="$(grep -E 'persistence: persistence.*clock: clock' "$SRC/Services/BatteryHistoryRecorder.swift" 2>/dev/null | grep -vE '^[[:space:]]*//' | wc -l | tr -d '[:space:]')"
	if [ "${CLOCK_HITS:-0}" != "7" ]; then
		echo "==> clock 接线守卫失败：门面只给 $CLOCK_HITS 个域传了 clock（期望 7）——漏传的域会吃真实时间，顺序断言看运气绿" >&2
		exit 1
	fi
	echo "==> clock 接线守卫：7 个域同一个钟（漏传即吃真实时间，断言会看运气）"

	# 保养状态回写守卫（轮21）：evaluator 给的**三个**状态必须全部回到 Controller。
	# 起因此前真漏过一个：didObserveSystemHoldAtLine / hasSilencedCareForSystemHold 回写了，
	# didNotifyChargeCare 漏了——拔电或 SOC 掉到重置线以下时 evaluator 把它清零，Controller
	# 不提交，旧的 true 就一直挡在 guard 前，"提醒过一次就再也提醒不了"。
	# 难点是"限定方法体 + 顺序"：全文件 grep 会被别处的同名赋值骗过，注释也会被算成实现。
	# 做法：先用 awk 按花括号深度切出 evaluateChargeCare 的真实方法体（跳过注释行），
	# 再在**这段里**比"回写行号 < guard 行号"。
	CARE_FILE="$SRC/Services/BatteryAlertController.swift"
	CARE_BODY="$(awk '
		/^[[:space:]]*\/\// { next }                       # 注释行不当代码
		/private func evaluateChargeCare\(/ { inbody=1 }   # 方法入口
		inbody {
			print
			n += gsub(/\{/, "{"); n -= gsub(/\}/, "}")
			if (n <= 0 && seen) { exit }
			if (n > 0) { seen=1 }
		}
	' "$CARE_FILE" 2>/dev/null)"
	WRITE_LINE="$(printf '%s\n' "$CARE_BODY" | grep -nE 'didNotifyChargeCare = result\.state\.didNotifyChargeCare' | head -1 | cut -d: -f1)"
	GUARD_LINE="$(printf '%s\n' "$CARE_BODY" | grep -nE 'guard result\.shouldSend' | head -1 | cut -d: -f1)"
	if [ -z "$WRITE_LINE" ] || [ -z "$GUARD_LINE" ]; then
		echo "==> 保养状态回写守卫失败：evaluateChargeCare 方法体里找不到状态回写或 shouldSend 守卫（切片失败？）" >&2
		printf '    切到的方法体前 6 行：\n%s\n' "$(printf '%s\n' "$CARE_BODY" | head -6)"
		exit 1
	fi
	if [ "$WRITE_LINE" -ge "$GUARD_LINE" ]; then
		echo "==> 保养状态回写守卫失败：didNotifyChargeCare 的回写（方法体内第 $WRITE_LINE 行）不在 guard result.shouldSend（第 $GUARD_LINE 行）之前" >&2
		echo "    evaluator 的清零会被提前 return 吞掉 ⇒ 提醒过一次就再也提醒不了" >&2
		exit 1
	fi
	echo "==> 保养状态回写守卫：三个状态全回写、回写早于 shouldSend 分支（漏一个即静默失效）"

	# 边沿判定出口守卫（轮22）：充满/低电量/高温三条边沿提醒的判定已抽进
	# ThresholdAlertEvaluators（纯逻辑、可测）。若有人把判定条件抄回外壳方法体
	# （绕开 evaluator），判定层断言照绿、生产却走了没被测的那份——v2.9.16 同族病。
	# 钉法：外壳必须各调一次自己的 evaluator。
	# ① 剔掉以 // 开头的行再数：整行注释掉真调用（v2.9.16 原始假绿形态）时计数必须掉到 0；
	# ② grep -o|wc -l：无匹配时 grep -c 的"打 0 又退出 1"会造出双 0 让守卫假绿（第一轮就踩过）；
	# ③ 已知边界：守卫只承诺"调用形状恰好一次"——若有人保留真调用又另抄一份判定走抄的那份，
	#    形状守卫看不见，那是行为断言与读码的地界（探针与注释都在此声明，不冒充全知）。
	EDGE_FILE="$SRC/Services/BatteryAlertController.swift"
	for E in FullChargeAlertEvaluator LowBatteryAlertEvaluator HighTemperatureAlertEvaluator; do
		N="$(grep -v '^[[:space:]]*//' "$EDGE_FILE" | grep -oF "${E}.evaluate(" | wc -l | tr -d ' ')"
		if [ "$N" -ne 1 ]; then
			echo "==> 边沿判定出口守卫失败：$E 的外壳调用 $N 处（期望 1）——判定被抄回壳里、注释掉或调用丢失" >&2
			exit 1
		fi
	done
	echo "==> 边沿判定出口守卫：三条边沿提醒外壳各调一次自己的 evaluator（判定不抄第二遍）"
}

# 真源码上跑一遍：守卫不过即构建失败（与拆分前行为一致）
run_source_guards

# 元守卫：证明上面那些守卫**真的在工作**。
#
# 为什么需要它：源文件级守卫的失效方式全是"假绿"——模式写错、文件路径挪了、
# 计数退化成 grep -c 数行、把真调用删掉只留一行同内容的注释……本项目已经踩过两次
# （v2.9.10 以为兑现了出口断言、v2.9.16 注释顶替真调用）。守卫自己不说话的时候，
# "全绿"什么都不证明。
#
# 做法：把源码复制一份，制造一处**必然触发守卫**的变异，再跑同一组守卫——
# 它必须红。红不了就说明守卫没在工作，直接构建失败。
# 变异挑的是历史事故的原始形态：把信息行的真调用换成一句内容相同的注释。
GUARD_PROBE="$(mktemp -d)"
trap 'rm -rf "$GUARD_PROBE"' EXIT
cp -R "$SRC" "$GUARD_PROBE/src"
MUTANT="$GUARD_PROBE/src/UI/Components/PopoverComponents.swift"
python3 - "$MUTANT" <<'MUTATE'
import pathlib, sys, re
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
# 真调用 → 注释（正是 v2.9.16 那条假绿的形态：文本还在，行为没了）
mutated, n = re.subn(
    r"^(\t*)\.animation\(item\.animatesOnChange \? \.easeInOut\(duration: PanelMotion\.valueFadeSeconds\) : nil, value: item\.value\)$",
    r"\1// .animation(item.animatesOnChange ? .easeInOut(duration: PanelMotion.valueFadeSeconds) : nil, value: item.value)",
    s, count=1, flags=re.M)
if n != 1:
    sys.exit("变异没打上：找不到信息行动画那处真调用")
p.write_text(mutated, encoding="utf-8")
MUTATE
if ( SRC="$GUARD_PROBE/src"; run_source_guards ) >/dev/null 2>&1; then
	echo "==> 元守卫失败：注入变异后源文件级守卫仍然全过——守卫没在工作，本次「全绿」不作数" >&2
	echo "    变异：把信息行的淡变调用换成同内容注释（PopoverComponents.swift）" >&2
	exit 1
fi
rm -rf "$GUARD_PROBE"
trap - EXIT
echo "==> 元守卫：注入变异后守卫确实会红（守卫在工作，不是假绿）"

# 保养回写守卫的专属变异（轮21）：上面的变异只锻炼淡变守卫，证明不了这条新守卫会红。
# 这里在**源码副本**里删掉 evaluateChargeCare 的状态回写行（正是"漏接线"这个 bug 的原始形态），
# 守卫必须红、且错误信息必须是保养回写守卫自己的——红不了或红错了都说明守卫没在工作。
CARE_PROBE="$(mktemp -d)"
trap 'rm -rf "$CARE_PROBE"' EXIT
cp -R "$SRC" "$CARE_PROBE/src"
python3 - "$CARE_PROBE/src/Services/BatteryAlertController.swift" <<'MUTATE_CARE'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
lines = p.read_text(encoding="utf-8").splitlines(keepends=True)
# 只删真调用：整行剥空白后必须逐字等于回写语句；注释行（// 开头）天然不匹配
hits = [i for i, l in enumerate(lines) if l.strip() == "didNotifyChargeCare = result.state.didNotifyChargeCare"]
if len(hits) != 1:
    sys.exit("变异没打上：期望恰好 1 处状态回写行，实际 %d 处" % len(hits))
del lines[hits[0]]
p.write_text("".join(lines), encoding="utf-8")
MUTATE_CARE
CARE_GOT_RED=0
CARE_OUT="$( SRC="$CARE_PROBE/src"; run_source_guards 2>&1 >/dev/null )" || CARE_GOT_RED=1
if [ "$CARE_GOT_RED" -ne 1 ]; then
	echo "==> 元守卫失败：删掉保养状态回写后守卫仍然全过——保养回写守卫没在工作，本次「全绿」不作数" >&2
	exit 1
fi
if ! printf '%s\n' "$CARE_OUT" | grep -q "保养状态回写守卫失败"; then
	echo "==> 元守卫失败：删掉回写后守卫红了，但红的不是保养回写守卫（错误信息不匹配）" >&2
	printf '    实际输出：%s\n' "$CARE_OUT" >&2
	exit 1
fi
rm -rf "$CARE_PROBE"
trap - EXIT
echo "==> 元守卫：删除保养状态回写 → 保养回写守卫以预期信息变红（漏接线必红）"

# 边沿判定出口守卫的专属变异（轮22，审查抓的缺口）：上面的两个探针都不触碰
# X.evaluate( 调用，证明不了新守卫会红。变异用 v2.9.16 的原始假绿形态——
# 把真调用整行注释掉、留一行内容相同的注释；守卫剔注释后计数必须掉到 0，
# 红、且红的信息必须是边沿出口守卫自己的。
EDGE_PROBE="$(mktemp -d)"
trap 'rm -rf "$EDGE_PROBE"' EXIT
cp -R "$SRC" "$EDGE_PROBE/src"
python3 - "$EDGE_PROBE/src/Services/BatteryAlertController.swift" <<'MUTATE_EDGE'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
mutated, n = re.subn(
    r"^(\t*)let result = FullChargeAlertEvaluator\.evaluate\(\.init\($",
    r"\1// let result = FullChargeAlertEvaluator.evaluate(.init(",
    s, count=1, flags=re.M)
if n != 1:
    sys.exit("变异没打上：找不到充满外壳的 evaluate 调用")
p.write_text(mutated, encoding="utf-8")
MUTATE_EDGE
EDGE_GOT_RED=0
EDGE_OUT="$( SRC="$EDGE_PROBE/src"; run_source_guards 2>&1 >/dev/null )" || EDGE_GOT_RED=1
if [ "$EDGE_GOT_RED" -ne 1 ]; then
	echo "==> 元守卫失败：注释掉充满外壳的 evaluate 调用后守卫仍然全过——边沿出口守卫没在工作" >&2
	exit 1
fi
if ! printf '%s\n' "$EDGE_OUT" | grep -q "边沿判定出口守卫失败"; then
	echo "==> 元守卫失败：注释掉调用后守卫红了，但红的不是边沿出口守卫（错误信息不匹配）" >&2
	printf '    实际输出：%s\n' "$EDGE_OUT" >&2
	exit 1
fi
rm -rf "$EDGE_PROBE"
trap - EXIT
echo "==> 元守卫：注释顶替真调用 → 边沿出口守卫以预期信息变红（判定不抄第二遍是实门）"


# 测试面用默认 SDK（不钉旧）：逻辑层排除了宏宿主与 UI，不需要 SwiftUIMacros 插件，
# 因此这份信号反映的正是本机最新 SDK 下逻辑层的真实编译状态——与 build.sh 为 UI 层
# 钉的旧 SDK 是两条独立证据，回显版本免得把两者的结论混着读。
TEST_SDK_PATH="$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || true)"
TEST_SDK_VERSION="$(plutil -extract Version raw "$TEST_SDK_PATH/SDKSettings.plist" 2>/dev/null || echo '?')"
echo "==> 编译测试（源文件 ${#SOURCES[@]} 个 + 测试用例；SDK：默认 macOS $TEST_SDK_VERSION）..."
# 先清旧二进制再编：swiftc -o 只在成功时覆盖，编译失败时上次的好二进制还留在原地，
# 不清就会拿旧代码跑出"全绿"（编译失败被静默放过——假绿比红更糟）。
# 退出码同样要查：此前 swiftc 失败后脚本照旧往下走，二进制缺失时 exec 的 127
# 会被"沙盒降级"分支接住，以 exit 0 收场——CI 也会绿（2026-10-03 轮22 修）。
# 注意只修了"编译失败"这条腿；"编译成功但沙盒禁 exec→断言未跑"那条腿的 126
# 分支仍在（那是禁 exec 环境的诚实降级口径，build.sh 以它为门，不能改 exit 1）。
rm -f "$OUT/tests"
COMPILE_LOG="$OUT/compile.log"
COMPILE_RC=0
swiftc \
	-swift-version 5 \
	-default-isolation MainActor \
	-target "arm64-apple-macosx$DEPLOYMENT_TARGET" \
	"${SOURCES[@]}" \
	"$ROOT/测试/main.swift" \
	-o "$OUT/tests" \
	2> "$COMPILE_LOG" || COMPILE_RC=$?
if [ -s "$COMPILE_LOG" ]; then cat "$COMPILE_LOG" >&2; fi
if [ "$COMPILE_RC" -ne 0 ]; then
	echo "==> 编译失败（rc=$COMPILE_RC）：测试面没跑，不许拿旧二进制或「降级」字样顶替" >&2
	exit 1
fi
# 警告门：账本 2026-09-05 就记了"门检 grep 必须含 warning: 且计数 0"，但这条规则
# 从未落进任何脚本——轮20 起测试面带着 3 条 var 警告被历轮记成"零警告"。
# 从这里起编译零警告是硬门，不再靠眼睛。
if grep -q "warning:" "$COMPILE_LOG"; then
	echo "==> 编译警告门失败：测试面编译输出含 warning（全绿零警告是门禁，不是口号）" >&2
	exit 1
fi

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
