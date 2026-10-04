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
EXCLUDED_VIEW=()
while IFS= read -r f; do
	[ "$(basename "$f")" = "ChargeMonitorApp.swift" ] && continue
	# SwiftUIMacros(@State 等)需要 macro plugin; CLT-only 工具链(缺 Xcode)会全挂。
	# 单元测试目标是逻辑层(Models/Services/Utilities/Core 渲染器): UI 视图与
	# 面板控制器层动态排除——UI/ 全目录、import SwiftUI 的 Core/Settings 文件、
	# 以及含 macro 的文件都不进测试编译面。逻辑文件今后 import SwiftUI 需过测试门。
	#
	# 视图宿主排除（这两处都是"自己没进测试面，却引用被排掉的 UI/ 类型"）：
	# 判据是形状而不是文件名——NSHostingView(rootView:) 的实参类型若来自 UI/，
	# 整个文件必然编不过。漏排的形态是编译期报"cannot find type"，不是假绿，
	# 但它会把构建门堵死，所以这里逐个列明并在下方有断言核对（见 run_exclusion_audit）。
	case "$f" in
		*/UI/BatteryInfoFormatter.swift) ;;  # 逻辑格式化器(放错在 UI/), 白名单进测试面
		*/UI/*) continue ;;                  # 其余视图层与 macro 文件互耦, 全排
		*/Core/ChargeCurveWindowController.swift)
			EXCLUDED_VIEW+=("Core/ChargeCurveWindowController.swift"); continue ;;
		*/Core/MenuBarPanelController.swift)
			EXCLUDED_VIEW+=("Core/MenuBarPanelController.swift"); continue ;;
	esac
	# 宏宿主判据：SwiftUI 属性包装器/宏。SDK 27 起 @State 等改为宏实现，
	# CLT-only 工具链（缺 SwiftUIMacros 插件）编不动 ⇒ 这类文件必须排除。
	#
	# 三条踩过的坑，写在这里防止改回去（2026-10-04，架构师审计订正过其中两条）：
	# ① 边界**绝不能用 \b**。本机 PATH 里的 grep 是 WorkBuddy 注入的 toybox 0.8.13
	#    shim（/Applications/WorkBuddy.app/.../brokered-bin/grep），它**不认 \b**：
	#    实测同输入 '@State\b' 下 /usr/bin/grep 匹配、PATH grep 不匹配；且
	#    '@ObservedObject\b' 在 shim 下返回 0 而 '@ObservedObject' 返回 5。
	#    ⇒ 整条判据恒假 ⇒ 宏宿主静默漏排 ⇒ 编译门被堵死。写 ([[:space:]]|$) 两边都认。
	# ② 宏判据必须剔注释行——AppServices.swift 的**注释里**写着"不再挂在 App 结构的
	#    @StateObject 上"，不剔会把纯逻辑文件误排除。误排除不报错，只是悄悄少一批
	#    断言（本项目最恨的静默失效）。
	# ③ 名单里 @ObservedObject/@Bindable **不是宏**（27.0 SDK 的 swiftinterface 里
	#    `macro ObservedObject` 计数为 0），留着无害但别当"补漏"讲——真正的漏排原因是 ①。
	#    反过来别把非 SwiftUI 的 @Observable 拿掉：它是本项目 7 个 recorder 的宿主标记。
	_CODE_LINES="$(grep -v '^[[:space:]]*//' "$f")"
	if printf '%s\n' "$_CODE_LINES" | grep -qE '@(State|StateObject|AppStorage|SceneStorage|FocusedValue|EnvironmentObject|Environment|Observable|ObservedObject|Bindable)([[:space:]]|$)'; then
		EXCLUDED_MACRO+=("$f")  # 宏宿主编译不了, 排除但必须显式回显, 防静默侵蚀
		continue
	fi
	SOURCES+=("$f")
done < <(find "$SRC" -name '*.swift' | sort)

if [ ${#EXCLUDED_MACRO[@]} -gt 0 ]; then
	echo "==> 宏宿主排除 ${#EXCLUDED_MACRO[@]} 个（清单如下，逻辑层新增宏宿主=架构越界信号）"
	printf '    %s\n' "${EXCLUDED_MACRO[@]}"
fi

if [ ${#EXCLUDED_VIEW[@]} -gt 0 ]; then
	echo "==> 视图宿主排除 ${#EXCLUDED_VIEW[@]} 个（引用 UI/ 类型，形状判据见 run_exclusion_audit）"
	printf '    %s\n' "${EXCLUDED_VIEW[@]}"
fi

# 排除清单自检：排除是**手写名单**，新增 Core/Settings 文件若引用了被排掉的类型
# 会静默漏排、把构建门堵死（2026-10-04 实际发生过，形态是 swiftc 报 cannot find type）。
# 架构师审计指出两类形态：
#   ① 视图宿主——Core/ 下用 NSHostingView(rootView:) 承载 UI/ 类型；
#   ② 符号引用——Settings/ 等非 UI 文件直接引用 UI/ 里的符号（实测
#      SettingsView 用了 UI/BatteryHeaderView.swift 里的 PanelText）。
# 只钉 ① 会漏掉 ②，所以两条都在这里按"文件在不在测试面"核对，而不是只按名字硬编。
# 已知边界（如实声明）：真"新增"一个 UI 符号并让非 UI 文件引用它，本自检看不见——
# 那种漏排会以 cannot find type 报红，只是报错位置不友好。这里守的是既有三条接线。
run_exclusion_audit() {
	local LEAK=() f rel
	while IFS= read -r f; do
		rel="${f#$SRC/}"
		case " ${EXCLUDED_VIEW[*]:-} " in
			*" $rel "*) continue ;;  # 已在排除名单里，符合预期
		esac
		LEAK+=("$rel")
	done < <(grep -rl 'NSHostingView(' "$SRC" 2>/dev/null | sort || true)
	local REAL=()
	for rel in "${LEAK[@]:-}"; do
		case "$rel" in
			UI/*) ;;                       # UI/ 本就全排
			*) [ -n "$rel" ] && REAL+=("$rel") ;;
		esac
	done
	if [ ${#REAL[@]} -gt 0 ]; then
		echo "==> 排除清单自检失败：这些文件用 NSHostingView 承载视图却没被排除（会编译失败）：" >&2
		printf '    %s\n' "${REAL[@]}" >&2
		echo "    修法：加入上方 case 的视图宿主排除分支，并说明它引用哪个 UI/ 类型" >&2
		return 1
	fi
	# 形态②：非 UI 文件在**代码**（非注释）里引用 UI/ 声明的符号。
	# 必须剔注释行——实测 Utilities/CardDragEngine.swift、Utilities/PanelCardHeights.swift
	# 只是在头部注释里提到 "随 BatteryPopoverView 生命周期"，代码零引用；不剔就会把
	# 一大批能正常编过的逻辑文件判成泄漏，判据立刻退化成"永远红"或"永远不查"。
	# 只认 UI/ 目录的**顶层声明**；嵌套与 private 类型拿不到，宁可漏也不误报。
	#
	# 性能：逐文件逐符号双层 grep 是 82×N 次进程，跑 2 分钟收不住、会被 CI 超时杀掉
	# （2026-10-04 实测 exit 137）。改成两次扫描求交：候选文件 grep -o 一次取出全部
	# 大写开头的标识符去重，再与 UI/ 符号表做一次 awk 求交。
	#
	# 第二条工具链坑（2026-10-04 踩的，**当时归因错了、后经复测定案**）：
	# 这里曾写成"toybox grep 不接受多个文件参数"——**那是错的**。复测证据：
	#   grep -h 'func ' a.swift b.swift            → 10（toybox）
	#   /usr/bin/grep -h 'func ' a.swift b.swift   → 10（一致）
	# 多文件参数本身没问题。真正让判据恒空的是**管道里文件列表为空**：当时写成
	#   grep -rhv PAT "$(find … | tr '\n' ' ')"
	# 而那条 find 在同一管道里被 head 截断/路径写错，展开成空列表 ⇒ grep 无文件可读 ⇒ 恒 0 行。
	# 教训比结论重要：**判据恒空时先打印文件数与命中数，别急着归咎工具**。
	# 现在用 find | xargs -0，且下面有 N_LINES < 100 的行数自检兜底。
	local CAND UI_SYMS SYM N_LINES
	CAND="$(mktemp)"
	find "$SRC" -name '*.swift' -not -path '*/UI/*' -not -name 'ChargeMonitorApp.swift' -print0 \
		| xargs -0 grep -hv '^[[:space:]]*//' 2>/dev/null > "$CAND.lines" || true
	N_LINES="$(wc -l < "$CAND.lines" | tr -d ' ')"
	if [ "${N_LINES:-0}" -lt 100 ]; then
		echo "==> 排除清单自检失败：候选文件扫描只得到 $N_LINES 行（应至少数百）——" >&2
		echo "    多半是 grep 的多文件参数在本机 toybox 下不工作（返回 0 行），判据会恒空。" >&2
		echo "    修法：保持 find | xargs -0 管道，不要改回 grep PAT \$(find ...)。" >&2
		rm -f "$CAND" "$CAND.lines"
		return 1
	fi
	# 候选集要扣掉**已排除的文件**——它们引用 UI/ 符号是合法的（本来就编不过、已排）。
	# 实测剩下的两处正是这种：MenuBarPanelController 与 ChargeCurveWindowController
	# 引用 BatteryPopoverView / ChargeCurveWindowHost，两个文件都在 EXCLUDED_VIEW 里。
	# 判据的职责是"抓漏排"，不是"抓已排"。
	grep -oE '[A-Z][A-Za-z0-9_]+' "$CAND.lines" 2>/dev/null | sort -u > "$CAND" || true
	# 逐个剔除已排除文件里的标识符（单文件读，避开 toybox 的多文件参数限制）
	if [ ${#EXCLUDED_VIEW[@]} -gt 0 ]; then
		for v in "${EXCLUDED_VIEW[@]}"; do
			if [ -f "$SRC/$v" ]; then
				grep -hv '^[[:space:]]*//' "$SRC/$v" 2>/dev/null \
					| grep -oE '[A-Z][A-Za-z0-9_]+' | sort -u > "$CAND.ex" || true
				grep -vxF -f "$CAND.ex" "$CAND" > "$CAND.keep" 2>/dev/null || cp "$CAND" "$CAND.keep"
				mv "$CAND.keep" "$CAND"
				rm -f "$CAND.ex"
			fi
		done
	fi
	# 扣掉 BatteryInfoFormatter.swift：它是"逻辑格式化器放错在 UI/"，被显式放进测试面
	# （见文件头的 case 分支），它声明的符号被 Utilities/BatteryReportBuilder.swift
	# 引用是**合法**的；不扣这条判据会永远红。
	UI_SYMS="$(find "$SRC/UI" -name '*.swift' -not -name 'BatteryInfoFormatter.swift' -print0 \
		| xargs -0 grep -hoE '^(struct|enum|final class|class|actor|protocol) [A-Z][A-Za-z0-9_]+' 2>/dev/null \
		| awk '{print $2}' | sort -u || true)"
	if [ -z "$UI_SYMS" ]; then
		echo "==> 排除清单自检失败：UI/ 符号表为空——多文件 grep 在本机不可用，判据会恒空。" >&2
		rm -f "$CAND" "$CAND.lines"
		return 1
	fi
	# UI_SYMS 是**多行字符串**，绝不能直接当 awk 的文件参数——那会把每个符号名
	# 当成一个文件名（实测报 "awk: can't open file BatteryCheckupSection"）。
	# 落盘后再求交。SYM 记符号名（不含文件），报告里点明形态即可。
	printf '%s\n' "$UI_SYMS" > "$CAND.syms"
	SYM=""
	if [ -s "$CAND" ]; then
		SYM="$(awk 'NR==FNR{u[$0]=1;next} ($0 in u){print}' "$CAND.syms" "$CAND" 2>/dev/null || true)"
	fi
	rm -f "$CAND" "$CAND.lines" "$CAND.syms"
	if [ -n "$SYM" ]; then
		echo "==> 排除清单自检（形态②）发现非 UI 文件在代码里引用 UI/ 符号：" >&2
		printf '    %s\n' $SYM >&2
		echo "    这类符号由 UI/ 声明，其宿主在 SDK 27 下会因缺 SwiftUIMacros 插件编译失败。" >&2
		echo "    修法：把对应宿主文件加入排除名单；若确实编得过，把该接线登记进白名单并注明理由。" >&2
		return 1
	fi
	echo "==> 排除清单自检：NSHostingView 宿主与 UI 符号跨层引用均已核对（漏排会在此变红）"
}

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
	# 计数只证明"有 5 处动画、3 处门控"，**不证明它们配对正确**——把门控挪到别处、
	# 或者 3 处门控全挤在同一分支而另外两处动画裸奔，计数照样是 5/3。
	# 配对判据：每处 TimelineView 往上 20 行内必须能看到 holdsDecorativeAnimation
	#（它们是 if/else 配对：门控在 if 分支、TimelineView 在 else 分支，跨度约 7 行）。
	# 期望恰好 3 处带门控、2 处豁免（警示通道：热脉冲/低电呼吸，节奏本身就是信息）。
	PAIRED="$(awk '
		{ lines[NR]=$0 }
		END {
			for (n=1; n<=NR; n++) {
				if (lines[n] ~ /TimelineView\(/) {
					c=0
					for (m=n-20; m<n; m++) if (m>0 && lines[m] ~ /holdsDecorativeAnimation/) c=1
					if (c) gated++
				}
			}
			print gated+0
		}' "$HEADER_UI" 2>/dev/null)"
	if [ "${PAIRED:-0}" != "3" ]; then
		echo "==> 动效门守卫失败：$TICKS 处动画里只有 ${PAIRED:-0} 处上方有滚动门控（期望 3）——" >&2
		echo "    计数 5/3 只证明数量对，不证明配对正确；充电三处必须各有门控停帧，警示两处必须豁免。" >&2
		exit 1
	fi
	echo "==> 动效门守卫：头部墙钟动画 5 处、其中充电 3 处经滚动门控（警示 2 处按规矩豁免）；配对已核对（3 处带门控）"

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
	# 这里原来用 `grep -rE PAT "$SRC/UI" "$SRC/Settings"`（多文件参数）。
	# 2026-10-04 我一度判定它"恒假、形同虚设"——**那是误判**：注入
	# `weight: .bold` 实测旧写法命中 1、新写法也命中 1，多文件参数工作正常。
	# 保留 find | xargs 写法是为了与形态②统一（可读性），不是行为修复。
	BOLD="$(find "$SRC/UI" "$SRC/Settings" -name '*.swift' -print0 \
		| xargs -0 grep -hE 'weight: \.bold' 2>/dev/null \
		| grep -vE '^[[:space:]]*//' | wc -l | tr -d '[:space:]')"
	if [ "${BOLD:-0}" != "0" ]; then
		echo "==> 字阶守卫失败：面板/设置里还有 $BOLD 处 .bold（字重预算只到 semibold，且仅限区块标题/头部主数字/表格值列/按钮标题）"
		find "$SRC/UI" "$SRC/Settings" -name '*.swift' -print0 \
			| xargs -0 grep -nE 'weight: \.bold' 2>/dev/null | grep -vE ':[[:space:]]*//' | sed 's/^/    /'
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
run_exclusion_audit
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

# 字阶守卫的专属变异（2026-10-04）：这条守卫的期望值是**0**（"面板/设置里不许有 .bold"），
# 而期望 0 的计数守卫最危险——判据一旦恒假就永远绿，且没有任何报错。
# 探针：在源码副本的 UI/ 文件里注入一条真实存在的 .bold 写法
# （.font(.system(size: 12, weight: .bold))，与项目里 weight: .semibold 同一形态），
# 字阶守卫必须红，且红的信息必须是字阶守卫自己的。
BOLD_PROBE="$(mktemp -d)"
trap 'rm -rf "$BOLD_PROBE"' EXIT
cp -R "$SRC" "$BOLD_PROBE/src"
printf '\n.probe(font: .system(size: 12, weight: .bold))\n' >> "$BOLD_PROBE/src/UI/DailySummarySection.swift"
# 注意输出去向：字阶守卫的错误信息走 **stdout**（同脚本里多数守卫用 >&2，但这一个用 echo
# 不带重定向）。所以这里必须 2>&1 一起收，只取 stderr 会误判成"红错了信息"。
BOLD_GOT_RED=0
BOLD_OUT="$( SRC="$BOLD_PROBE/src"; run_source_guards 2>&1 )" || BOLD_GOT_RED=1
if [ "$BOLD_GOT_RED" -ne 1 ]; then
	echo "==> 元守卫失败：注入 .bold 后字阶守卫仍然全过——期望 0 的计数守卫恒假了，本次「全绿」不作数" >&2
	printf '    探针实际输出：%s\n' "$BOLD_OUT" >&2
	exit 1
fi
if ! printf '%s\n' "$BOLD_OUT" | grep -q "字阶守卫失败"; then
	echo "==> 元守卫失败：注入 .bold 后守卫红了，但红的不是字阶守卫（错误信息不匹配）" >&2
	printf '    实际输出：%s\n' "$BOLD_OUT" >&2
	exit 1
fi
rm -rf "$BOLD_PROBE"
trap - EXIT
echo "==> 元守卫：注入 .bold → 字阶守卫以预期信息变红（期望 0 的守卫不是恒假）"

# 动效门守卫的专属变异（2026-10-04）：本轮给它补了**配对验证**（计数只证明数量，
# 不证明门控与动画一一对应）。所以探针必须构造"计数全对、配对错"的形态——
# 把第 3 处门控搬到一个与任何 TimelineView 都不相邻的 struct 里，计数仍是 5/3，
# 旧版守卫会全绿。动效门必须以自己的信息变红。
MOTION_PROBE="$(mktemp -d)"
trap 'rm -rf "$MOTION_PROBE"' EXIT
cp -R "$SRC" "$MOTION_PROBE/src"
python3 - "$MOTION_PROBE/src/UI/BatteryHeaderView.swift" <<'MUTATE_MOTION'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
lines = p.read_text(encoding="utf-8").splitlines(keepends=True)
tgt = [i for i, l in enumerate(lines) if "PanelMotionGate.holdsDecorativeAnimation" in l]
if len(tgt) != 3:
    sys.exit("变异没打上：期望恰好 3 处门控，实际 %d 处" % len(tgt))
gate = lines[tgt[2]]
expr = gate.split("if ", 1)[1].rstrip().rstrip("{").rstrip()
del lines[tgt[2]]
lines += ["\n", "struct __GateParking {\n", "\tlet x: Bool = %s\n" % expr, "}\n"]
p.write_text("".join(lines), encoding="utf-8")
MUTATE_MOTION
MOTION_GOT_RED=0
MOTION_OUT="$( SRC="$MOTION_PROBE/src"; run_source_guards 2>&1 )" || MOTION_GOT_RED=1
if [ "$MOTION_GOT_RED" -ne 1 ]; then
	echo "==> 元守卫失败：门控被挪到不与动画相邻处后动效门守卫仍然全过——配对判据没在工作" >&2
	printf '    探针实际输出：%s\n' "$MOTION_OUT" >&2
	exit 1
fi
if ! printf '%s\n' "$MOTION_OUT" | grep -q "动效门守卫失败"; then
	echo "==> 元守卫失败：门控被挪走后守卫红了，但红的不是动效门守卫（错误信息不匹配）" >&2
	printf '    实际输出：%s\n' "$MOTION_OUT" >&2
	exit 1
fi
rm -rf "$MOTION_PROBE"
trap - EXIT
echo "==> 元守卫：门控挪位（计数 5/3 全对但配对错） → 动效门守卫以预期信息变红"


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
