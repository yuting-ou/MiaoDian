import AppKit
import SwiftUI

// 离屏验收工具（仅开发用，不进构建产物）：把真面板视图装进 NSHostingView，
// 不显示到屏幕、不抢焦点，直接问它"你要多高"并把版式渲染成 PNG。
//
// 为什么需要它：面板高度是否超出可视区（菜单栏+Dock 之后）是这轮观感整改的关键未知量，
// 而实拍截图依赖显示器亮着——用户不在机器前时屏幕常熄，像素量不到；
// CGWindowList 的宽高数字又实测不可信（报过 526pt，实际 586pt）。
// 能力边界（实测，别误信）：
//   ✓ 能验：布局尺寸/是否超出可视区——fittingSize 由布局引擎直接给出，与显示器状态无关
//   ✗ 不能验：观感。离屏视图不进入窗口 → onAppear 不触发，而面板内容全部挂在
//     CascadeIn 逐层淡入上（未 appear 时透明度为 0），加上玻璃材质不做离屏合成，
//     渲染出来的 PNG 是空白。观感验收仍必须实拍（见 工具/壁纸实测.sh 与报告"待眼睛"清单）。
//
// 用法：bash 工具/离屏验收.sh [宽度pt]   → /tmp/miaodian_render.png + stdout 高度
// 用法：bash 工具/离屏验收.sh cards      → 「今日用电」卡的自然高标定（列配平常量的来源）
@main
struct OffscreenAcceptance {
	static func main() {
		if CommandLine.arguments.dropFirst().first == "cards" {
			calibrateDailySummaryCard()
			return
		}
		let width = CommandLine.arguments.count > 1
			? (Double(CommandLine.arguments[1]) ?? 584) : 584.0

		let monitor = BatteryMonitor()
		let historyRecorder = BatteryHistoryRecorder(monitor: monitor)
		let alertController = BatteryAlertController(
			monitor: monitor,
			configurationManager: ConfigurationManager.shared,
			historyRecorder: historyRecorder
		)
		// 持有引用：NSHostingView 只弱引用 ObservableObject
		_ = alertController

		let root = BatteryPopoverView(
			monitor: monitor,
			configurationManager: ConfigurationManager.shared,
			historyRecorder: historyRecorder,
			alertController: alertController
		)
		.frame(width: width)

		let hosting = NSHostingView(rootView: AnyView(root))
		hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
		hosting.layoutSubtreeIfNeeded()

		let fitting = hosting.fittingSize
		print("面板内容尺寸：\(fitting.width) x \(fitting.height) pt")
		if let screen = NSScreen.main {
			let visible = screen.visibleFrame
			// 面板顶边锚在 visibleFrame 上缘，可用高即窗口顶到可视区底
			print("屏幕 \(screen.frame.width)x\(screen.frame.height)，可视高 \(visible.height)pt → "
				+ (fitting.height <= visible.height ? "✓ 整块落在 Dock 之上" : "✗ 超出 \(String(format: "%.0f", fitting.height - visible.height))pt，底部被 Dock 压住"))
		}

		hosting.frame = NSRect(x: 0, y: 0, width: fitting.width, height: fitting.height)
		hosting.layoutSubtreeIfNeeded()
		guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
			print("无法创建位图上下文"); return
		}
		hosting.cacheDisplay(in: hosting.bounds, to: rep)
		guard let data = rep.representation(using: .png, properties: [:]) else {
			print("PNG 编码失败"); return
		}
		let out = URL(fileURLWithPath: "/tmp/miaodian_render.png")
		try? data.write(to: out)
		print("已渲染 \(out.path)（预期空白：见文件头「能力边界」，观感请走实拍）")
	}

	// MARK: - 「今日用电」卡自然高标定
	//
	// 为什么要有这一段：列配平吃的声明高度一旦靠"看着办"填，就会漂成民俗数字
	// （v2.9.11 第一版就干过这事——把 4 行×13pt 当成漏算量，实测才发现基线里早留过行位）。
	// 这里用四组受控夹具把 真实自然高 / 声明高 并排量出来，常量必须由这张表回填。
	// 夹具设计：说明行数只由「当日观测秒数」控制（≥30 分钟 → 占比句 + 驻留句各一条）；
	// 七天图只由「history 条数 ≥2」控制，故把历史日放在 2020 年——进了图、不进 7 日窗口。
	static func calibrateDailySummaryCard() {
		let columnWidth: CGFloat = 275   // (584 − 12×2 − 10) / 2，与面板列宽一致
		var empty = DailyUsage(dayKey: "2026-07-30", drainedPercent: 12, chargedPercent: 3)
		empty.acSeconds = 120
		empty.batterySeconds = 60        // 观测 180s < 30 分钟 → 说明行全沉默
		var talky = DailyUsage(dayKey: "2026-07-30", drainedPercent: 12, chargedPercent: 3)
		talky.acSeconds = 3600           // 醒着 1 小时在插电 → 占比句 + 驻留句
		let chartHistory = [
			DailyUsage(dayKey: "2020-01-01", drainedPercent: 20, chargedPercent: 10),
			DailyUsage(dayKey: "2020-01-02", drainedPercent: 20, chargedPercent: 10)
		]

		let cases: [(String, DailyUsage, [DailyUsage])] = [
			("A 无图 · 0 行", empty, []),
			("B 无图 · 2 行", talky, []),
			("C 有图 · 0 行", empty, chartHistory),
			("D 有图 · 2 行", talky, chartHistory)
		]
		print("== 「今日用电」卡：真实自然高 vs 声明高（列宽 \(Int(columnWidth))pt）==")
		var measured: [(String, CGFloat, CGFloat, Int)] = []
		for (label, usage, history) in cases {
			let card = DailySummarySection(
				usage: usage,
				chargeCount: 1,
				history: history,
				isCollapsed: false,
				onToggle: {}
			)
			.frame(width: columnWidth)
			let host = NSHostingView(rootView: AnyView(card))
			host.frame = NSRect(x: 0, y: 0, width: columnWidth, height: 400)
			host.layoutSubtreeIfNeeded()
			let real = host.fittingSize.height
			let declared = DwellTracking.dailySummaryHeight(usage: usage, history: history)
			let lines = DwellTracking.noteLines(todayUsage: usage, history: history).count
			measured.append((label, real, declared, lines))
			print(String(format: "  %@ 真实 %5.1fpt · 声明 %5.1fpt · 说明行 %d · 差 %+5.1fpt",
						 label, real, declared, lines, declared - real))
		}
		// 由 A/B/C 反推常量，再回代 D 看是否可加
		if measured.count == 4 {
			let lineUnit = (measured[1].1 - measured[0].1) / 2
			let chartDelta = measured[2].1 - measured[0].1
			let predicted = measured[0].1 + 2 * lineUnit + chartDelta
			print(String(format: "  实测推论：基线 %.1fpt · 每说明行 %.1fpt · 七天图 %.1fpt（D 预测 %.1f 实测 %.1f，残差 %+.1f）",
						 measured[0].1, lineUnit, chartDelta, predicted, measured[3].1, measured[3].1 - predicted))
			print(String(format: "  现行常量：基线 %.0f · 有图 +%.0f · 每行 %.0fpt（与实测推论不符时改常量，不是改说法）",
						 DwellTracking.dailySummaryBaseHeight,
						 DwellTracking.dailySummaryChartHeight,
						 DwellTracking.noteLineHeight))
		}

		// 真档案腿：用户此刻这张卡实际渲染哪几句、声明高多少。
		// 只看夹具会漏掉一类问题——生产文案最长那句、以及新加的有界说明给出什么天数
		let live = BatteryHistoryRecorder(monitor: BatteryMonitor())
		if let todayUsage = live.todayUsage {
			let lines = DwellTracking.noteLines(todayUsage: todayUsage, history: live.dailyHistory)
			print(String(format: "  真档案：说明行 %d 条 · 声明高 %.0fpt · 历史 %d 天",
						 lines.count,
						 DwellTracking.dailySummaryHeight(usage: todayUsage, history: live.dailyHistory),
						 live.dailyHistory.count))
			for line in lines {
				print("    · \(line)（折行单位 \(DwellTracking.noteHeightUnits(line))）")
			}
		} else {
			print("  真档案：今天还没有用电记录，跳过这一腿")
		}

		// 体检卡 / 洞察卡：同样是"声明高恒值 vs 内容随数据长缩"的怀疑对象，量出来才知道
		print("== 体检卡（含估计项那行是有条件的）==")
		let plain = BatteryCheckup(score: 88, verdict: "状态良好", estimatedInputs: [])
		let estimated = BatteryCheckup(score: 74, verdict: "略有老化",
									   estimatedInputs: ["循环", "温度", "驻留"])
		let checkupPlain = measureCard(BatteryCheckupSection(checkup: plain))
		let checkupEst = measureCard(BatteryCheckupSection(checkup: estimated))
		print(String(format: "  无估计项 真实 %.0f／声明 %.0f · 有估计项 真实 %.0f／声明 %.0f · 差 %.0fpt",
					 checkupPlain, PanelCardHeights.checkup(estimatedInputs: []),
					 checkupEst, PanelCardHeights.checkup(estimatedInputs: estimated.estimatedInputs),
					 checkupEst - checkupPlain))

		print("== 洞察卡（渲染 prefix(3)，声明按 count 算）==")
		// 用生产里真会出现的最长句子做样本
		let longMessage = "最近几天几乎全程插着电，偶尔用电池放到 50% 左右更利于电池保养"
		let shortMessage = "按你平时的作息，充到 80% 睡一晚通常就够用，不必非充满"
		let oneShort = measureCardSize(HabitInsightSection(insights: [
			ChargingHabitInsight(message: shortMessage, symbol: "bolt.fill")
		]))
		let oneLong = measureCardSize(HabitInsightSection(insights: [
			ChargingHabitInsight(message: longMessage, symbol: "bolt.fill")
		]))
		print(String(format: "  自然宽探针：短句 %.0f×%.0f · 长句 %.0f×%.0f（列宽上限 275）",
					 oneShort.width, oneShort.height, oneLong.width, oneLong.height))
		let three = measureCard(HabitInsightSection(insights: (0..<3).map { _ in
			ChargingHabitInsight(message: longMessage, symbol: "bolt.fill")
		}))
		let seven = measureCard(HabitInsightSection(insights: (0..<7).map { _ in
			ChargingHabitInsight(message: longMessage, symbol: "bolt.fill")
		}))
		print(String(format: "  1 条短句 %.0fpt · 1 条长句 %.0fpt（折行）· 3 条长句 %.0fpt · 7 条（仍只显 3）%.0fpt",
					 oneShort.height, oneLong.height, three, seven))
		print(String(format: "  登记表演示：1 条声明 %.0f／真实 %.0f · 3 条 %.0f／%.0f · 7 条 %.0f／%.0f（渲染仍只 3 条）",
					 PanelCardHeights.habitInsight(messages: [longMessage]), oneShort.height,
					 PanelCardHeights.habitInsight(messages: [longMessage, longMessage, longMessage]), three,
					 PanelCardHeights.habitInsight(messages: Array(repeating: longMessage, count: 7)), seven))
		let sixFive = String(repeating: "充", count: 65)
		let oneLine = measureCard(HabitInsightSection(insights: [ChargingHabitInsight(message: String(repeating: "充", count: 10), symbol: "bolt.fill")]))
		let fourLine = measureCard(HabitInsightSection(insights: [ChargingHabitInsight(message: sixFive, symbol: "bolt.fill")]))
		print(String(format: "  按行数建模：1 行句声明 %.0f／真实 %.0f · 4 行长句声明 %.0f／真实 %.0f",
					 PanelCardHeights.habitInsight(messages: [String(repeating: "充", count: 10)]), oneLine,
					 PanelCardHeights.habitInsight(messages: [sixFive]), fourLine))
		let giant = measureCard(HabitInsightSection(insights: [
			ChargingHabitInsight(message: String(repeating: "充", count: 90), symbol: "bolt.fill")
		]))
		print(String(format: "  探针：1 条 90 全角超长句 = %.0fpt", giant))
		// 行数与高度的关系要量出来，不能拿"夹具恰好都是 2 行"当普适真相
		func lines(_ n: Int) -> String { String(repeating: "充", count: n) }
		let l1 = measureCardSize(HabitInsightSection(insights: [ChargingHabitInsight(message: lines(10), symbol: "bolt.fill")]))
		let l3 = measureCardSize(HabitInsightSection(insights: (0..<3).map { _ in ChargingHabitInsight(message: lines(10), symbol: "bolt.fill") }))
		let mid = measureCardSize(HabitInsightSection(insights: [ChargingHabitInsight(message: lines(20), symbol: "bolt.fill")]))
		print(String(format: "  行数标定：1 条 1 行句 %.0fpt · 1 条 20 字 %.0fpt · 3 条 1 行句 %.0fpt · 3 条 2 行句 %.0fpt",
					 l1.height, mid.height, l3.height, three))
	}

	/// 单张卡在真实列宽下的自然高
	private static func measureCard(_ card: some View) -> CGFloat {
		let size = measureCardSize(card)
		return size.height
	}

	/// 同时打印自然宽：宽 >275 说明文字没折行而是横向溢出（那是观感缺陷，不是标定噪声）
	private static func measureCardSize(_ card: some View) -> NSSize {
		let host = NSHostingView(rootView: AnyView(card.frame(width: 275)))
		host.frame = NSRect(x: 0, y: 0, width: 275, height: 400)
		host.layoutSubtreeIfNeeded()
		return host.fittingSize
	}
}

