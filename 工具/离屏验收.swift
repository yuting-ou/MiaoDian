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
		if CommandLine.arguments.dropFirst().first == "header" {
			renderHeaderProbe()
			return
		}
		if CommandLine.arguments.dropFirst().first == "symbols" {
			calibrateSymbolOptics()
			return
		}
		let width = CommandLine.arguments.count > 1
			? (Double(CommandLine.arguments[1]) ?? 584) : 584.0

		let monitor = BatteryMonitor()
		let historyRecorder = BatteryHistoryRecorder(monitor: monitor, defaults: .standard, backupDirectory: nil)
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

	// MARK: - 头部观感探针（体检徽章）

	/// 体检徽章只在 `checkup != nil` 时出现在头部右侧，而真机常处于"充满/无估计项可算"态，
	/// 实拍量不到它。这里直接摆一个 checkup 进头部单独渲染成 PNG——
	/// 头部自身不挂 CascadeIn（那是父视图加的），所以不像整块面板那样因未 appear 而全透明。
	/// 用法：bash 工具/离屏验收.sh header → /tmp/miaodian_header.png
	private static func renderHeaderProbe() {
		var snap = BatterySnapshot()
		snap.powerSource = .battery
		snap.stateOfChargePercent = 62
		snap.temperatureC = 31.5
		snap.cycleCount = 480
		snap.designCapacityMAh = 8694
		snap.maxCapacityMAh = 7888
		let root = AnyView(
			BatteryHeaderView(
				snapshot: snap,
				drainEstimate: DrainRateEstimate(percentPerHour: 7.5, estimatedMinutesRemaining: 490),
				lowBatteryThreshold: 20,
				checkup: BatteryCheckup(score: 68, verdict: "开始老化，注意保养", estimatedInputs: [])
			)
			.frame(width: 560)
			.padding(12)
			// 中性灰底：玻璃材质不做离屏合成，铺一层常数亮度底才看得清字与徽章
			.background(Color(white: 0.82))
		)
		let hosting = NSHostingView(rootView: root)
		hosting.frame = NSRect(x: 0, y: 0, width: 584, height: 200)
		hosting.layoutSubtreeIfNeeded()
		let fitting = hosting.fittingSize
		hosting.frame = NSRect(x: 0, y: 0, width: max(584, fitting.width), height: max(90, fitting.height))
		hosting.layoutSubtreeIfNeeded()
		guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
			  let data = rep.representation(using: .png, properties: [:]) else {
			print("无法创建位图上下文"); return
		}
		let out = URL(fileURLWithPath: "/tmp/miaodian_header.png")
		try? data.write(to: out)
		print(String(format: "已渲染 %@（%.0f x %.0f pt）", out.path, fitting.width, fitting.height))
	}

	// MARK: - 图标光学重心标定（真墨迹）

	/// 面板图标列"看起来的重心"标定。
	///
	/// **为什么不测 `alignmentRect`**：`alignmentRect` 与 `size` 都是**布局框**的度量，
	/// 拿它们相减只能证明"苹果把框对齐了"，回答不了"墨迹在哪"。
	/// 一列图标参差的是**墨迹**：同一个 16pt 框里，`cpu` 的方块几乎顶满，
	/// `clock` 的圆盘四周留白更多，于是视觉左缘排成锯齿。
	/// 所以这里把符号**光栅化后扫 alpha 求墨迹包围盒**（8× 超采样，能量到 1/8 pt），
	/// 报的是"墨迹中心 − 布局框中心"。与卡片声明高同一套纪律：**常量由量具给，不许凭感觉填**。
	///
	/// **口径边界（别把这张表当全面板清单）**：只量 `PanelText.secondary`（11pt）这一档，
	/// 也就是 `PopoverInfoRow`／`PopoverActionRow`／充电记录行用的图标列。
	/// 另有三处图标列走 9／9.5／12pt（事件时间轴、续航换算、洞察卡），
	/// 偏心量随字号线性缩放、且**不在同一张表里**——要给它们补偿必须按各自字号另量，
	/// 拿 11pt 的数填进去是假精度。
	/// 用法：bash 工具/离屏验收.sh symbols
	private static func calibrateSymbolOptics() {
		let size = PanelText.secondary   // 信息行/控制行图标都走这一档
		let scale = 8.0
		let symbols: [(name: String, where: String)] = [
			("hourglass", "充满还需/高耗电空态"), ("bolt.horizontal.circle.fill", "充电协议"),
			("speedometer", "当前档位"), ("square.grid.2x2", "可选档位"),
			("arrow.down.circle.fill", "输入功率"), ("bolt.circle.fill", "充电功率"),
			("cpu", "当前功耗"), ("cable.connector", "充电器/适配器"),
			("checkmark.seal.fill", "充电器(已识别)"), ("sparkles", "充电器(新)"),
			("arrow.triangle.2.circlepath", "循环次数"), ("heart.fill", "电池健康"),
			("chart.line.uptrend.xyaxis", "健康趋势"), ("thermometer.medium", "电池温度"),
			("bolt.ring.closed", "电流电压"), ("clock", "剩余可用时间"),
			("arrow.down.right.circle", "掉电速度"), ("desktopcomputer", "开机时长"),
			("moon.zzz.fill", "睡眠掉电"), ("bolt.fill", "充电记录/事件"),
			("checkmark.circle.fill", "无大户/事件空态"),
			("pause.circle", "系统暂缓充电"), ("bell.slash.fill", "通知权限"),
			("bolt.badge.clock", "充电记录行"),
			// 名册＝"走 11pt 图标列的符号"。eye.slash / gear / ellipsis.circle / power 已随
			// 控制行去图标而离开这一列（eye.slash 只剩布局编辑的小圆钮，不在列上），
			// 留着会让名册谎报覆盖面；新增走这一列的符号请往这里加一行
		]
		print(String(format: "== 图标光学重心（字号 %.1fpt · 图标列宽 %.0fpt · %.0f× 超采样扫墨迹）==",
					 size, PopoverLayout.iconColumnWidth, scale))
		print("  符号                        墨迹宽×高      dx(墨迹心−框心)   dy(上正)   用于")
		var maxAbsDx = 0.0, maxAbsDy = 0.0
		var wideSpread = 0.0
		var measured = 0, failed: [String] = []
		for entry in symbols {
			let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
			guard let img = NSImage(systemSymbolName: entry.name, accessibilityDescription: nil)?
				.withSymbolConfiguration(cfg) else {
				print("  \(entry.name)  ← 取不到符号")
				continue
			}
			let boxW = img.size.width, boxH = img.size.height
			let pxW = max(1, Int((boxW * scale).rounded()))
			let pxH = max(1, Int((boxH * scale).rounded()))
			guard let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
				bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
				colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
				let data = bmp.bitmapData else { failed.append(entry.name); continue }
			// 位图是按 rounded() 出来的整数像素，画图时被拉伸填满 ⇒ 一个像素不是恰好 1/scale pt。
			// 一律按**实际**像素数换算，否则 px/pt 混用会再叠 ≤0.06pt 的系统误差
			let ptPerPxX = boxW / Double(pxW), ptPerPxY = boxH / Double(pxH)
			for i in 0..<(pxH * bmp.bytesPerRow) { data[i] = 0 }
			NSGraphicsContext.saveGraphicsState()
			NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
			img.draw(in: NSRect(x: 0, y: 0, width: pxW, height: pxH), from: .zero,
					 operation: .sourceOver, fraction: 1.0, respectFlipped: true,
					 hints: [.interpolation: NSImageInterpolation.high.rawValue])
			NSGraphicsContext.restoreGraphicsState()
			var minX = pxW, maxX = -1, minY = pxH, maxY = -1
			let bpp = bmp.samplesPerPixel, bpr = bmp.bytesPerRow
			for y in 0..<pxH {
				for x in 0..<pxW where data[y * bpr + x * bpp + 3] > 24 {
					if x < minX { minX = x }; if x > maxX { maxX = x }
					if y < minY { minY = y }; if y > maxY { maxY = y }
				}
			}
			guard maxX >= minX else { print("  \(entry.name)  ← 无墨迹"); failed.append(entry.name); continue }
			measured += 1
			// 像素 x 覆盖连续区间 [x, x+1)，所以 minX..maxX 这段墨迹的**中心**是 (minX+maxX+1)/2，
			// 不是 (minX+maxX)/2。少那个 +1 会让每个 dx 恒偏 −0.5px（8× 下 −0.0625pt）——
			// 第一轮报的"21 个符号 dx=−0.06"就是这个底噪，不是苹果的偏心
			let inkW = Double(maxX - minX + 1) * ptPerPxX
			let inkH = Double(maxY - minY + 1) * ptPerPxY
			let dx = (Double(minX + maxX + 1) / 2) * ptPerPxX - boxW / 2
			let dy = boxH / 2 - (Double(minY + maxY + 1) / 2) * ptPerPxY
			maxAbsDx = max(maxAbsDx, abs(dx)); maxAbsDy = max(maxAbsDy, abs(dy))
			wideSpread = max(wideSpread, inkW)
			print(String(format: "  %-26@ %4.1f×%4.1f  %+6.2f  %+6.2f   %@",
						 entry.name, inkW, inkH, dx, dy, entry.where))
		}
		print(String(format: "  幅度：|dx| 最大 %.2fpt · |dy| 最大 %.2fpt · 最宽墨迹 %.1fpt（列宽 %.0fpt）",
					 maxAbsDx, maxAbsDy, wideSpread, PopoverLayout.iconColumnWidth))
		// 恒空自检：全部失败时上面那行会打印"最大 0.00pt"，读起来像"苹果已对齐"的结论。
		// 这类读数必须是红，不能是绿（本仓库纪律：判据恒空不许静默）
		print(String(format: "  覆盖：%d/%d 个符号量到", measured, symbols.count))
		if !failed.isEmpty { print("  ⚠️ 量不到（取不到符号／位图失败／无墨迹）：\(failed.joined(separator: " "))") }
		if measured < symbols.count / 2 {
			print("❌ 覆盖率不足一半（\(measured)/\(symbols.count)）——上面的幅度数不可用")
			exit(1)
		}
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
		let live = BatteryHistoryRecorder(monitor: BatteryMonitor(), defaults: .standard, backupDirectory: nil)
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

		// 高耗电应用卡（v2.9.21 空态改造）：空态只剩一行状态话，声明高必须跟着塌
		print("== 高耗电应用卡（空态 vs 铺卡，判据在 PanelCardVisibility.isEnergyAppsEmpty）==")
		let warm = measureCard(SignificantEnergySection(apps: [], isWarmingUp: true,
														weeklyTop: [], onRevealInFinder: { _ in }))
		let noBig = measureCard(SignificantEnergySection(apps: [], isWarmingUp: false,
														 weeklyTop: [], onRevealInFinder: { _ in }))
		print(String(format: "  空态：预热中 %.0fpt／无大户 %.0fpt · 登记 %.0fpt（差 %+.0fpt）",
					 warm, noBig, PanelCardHeights.energyAppsEmptyHeight,
					 max(warm, noBig) - PanelCardHeights.energyAppsEmptyHeight))
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

