import Foundation

/// C3 驻留效果追踪（纯函数）：把已有 DailyUsage 高电量驻留数据聚成
/// 「本周合计/日均」与「提醒响应前后对比」。扩展日摘要既有行，不新建卡片。
/// 诚实边界：样本不足不下结论（第一次透镜）；效果类指标两周后再看趋势。
nonisolated enum DwellTracking {
	nonisolated struct WeekDwell: Equatable, Sendable {
		let totalMinutes: Int
		let averageMinutesPerDay: Int
		let daysWithSample: Int
	}

	nonisolated struct CareWindowComparison: Equatable, Sendable {
		let recentAvgMinutes: Int
		let priorAvgMinutes: Int
		/// recent - prior；负数=驻留下降（保养有效方向）
		let deltaMinutes: Int
	}

	/// 有效驻留日门槛：dwell80PlusMinutes 非 nil（内部已有半小时采样门）
	nonisolated static let minDaysForWeekConclusion = 3

	/// 生成截止 today 的连续 dayKey 列表（新→旧或旧→新由 ascending 决定）
	/// dayKey 字符串必须跟随注入 calendar 的时区（与 UsageCalendarLayout.dayKey 同源）；
	/// DateFormatter 默认吃系统时区，与 calendar.timeZone 不一致时会把窗口键打错一天。
	nonisolated static func dayKeys(
		endingOn today: Date,
		count: Int,
		calendar: Calendar = .current,
		ascending: Bool = false
	) -> [String] {
		var keys: [String] = []
		var date = calendar.startOfDay(for: today)
		for _ in 0..<max(0, count) {
			keys.append(UsageCalendarLayout.dayKey(date, calendar: calendar))
			guard let prev = calendar.date(byAdding: .day, value: -1, to: date) else { break }
			date = prev
		}
		return ascending ? keys.reversed() : keys
	}

	/// 指定 dayKey 集合上的驻留聚合；有效样本日 < 门槛则 nil（面板不显示周结论）
	nonisolated static func weekAggregate(
		history: [DailyUsage],
		dayKeys keys: [String],
		minDays: Int = minDaysForWeekConclusion
	) -> WeekDwell? {
		let keySet = Set(keys)
		var totalSeconds = 0.0
		var sampleDays = 0
		for day in history where keySet.contains(day.dayKey) {
			guard let minutes = day.dwell80PlusMinutes else { continue }
			totalSeconds += Double(minutes) * 60
			sampleDays += 1
		}
		guard sampleDays >= minDays else { return nil }
		let totalMinutes = Int(totalSeconds / 60)
		return WeekDwell(
			totalMinutes: totalMinutes,
			averageMinutesPerDay: totalMinutes / sampleDays,
			daysWithSample: sampleDays
		)
	}

	/// 两窗口的驻留口径必须一致才谈「变化」。高电量驻留秒数与时长同一个写入者、同一个
	/// 归因门（v2.9.4 前只认 ≤30 秒的帧、v2.9.2 前完全不含睡眠段），所以「近 7 日 vs
	/// 前 7 日」一旦跨过升级日，就会把记账口径的扩大说成用户习惯变差或变好。
	/// 这里不接受"旧档 nil 自成一桶"：两批 nil 日之间还可能隔着 v2.9.2，只有都带上
	/// 同一个归因窗口标记的日子才可比（v2.9.5 起建行才写该标记）。
	nonisolated static func windowsComparable(
		history: [DailyUsage],
		recentKeys: [String],
		priorKeys: [String]
	) -> Bool {
		let keys = Set(recentKeys).union(priorKeys)
		var gaps: Set<Double> = []
		for day in history where keys.contains(day.dayKey) && day.dwell80PlusMinutes != nil {
			guard let gap = day.attributionGapSeconds else { return false }
			gaps.insert(gap)
		}
		return gaps.count == 1
	}

	/// 保养响应对比：recentKeys 窗口日均 vs priorKeys 窗口日均。
	/// 两侧有效样本各 ≥ 2 才给结论；否则 nil（避免单日噪声当效果）。
	/// 跨归因窗口口径的日子直接不给对比——口径变化不是用户行为变化。
	/// 升降对比的样本门槛：两侧各至少这几天有效样本才给结论。**门槛与"该不该解释"同源**，
	/// 否则会出现"倒计时结束了却仍不出结论"的假承诺（pendingComparableDays 用同一个值把关）
	nonisolated static let comparisonMinDays = 2

	nonisolated static func careResponseComparison(
		history: [DailyUsage],
		recentKeys: [String],
		priorKeys: [String],
		minDaysPerWindow: Int = comparisonMinDays
	) -> CareWindowComparison? {
		guard windowsComparable(history: history, recentKeys: recentKeys, priorKeys: priorKeys) else { return nil }
		guard
			let recent = weekAggregate(history: history, dayKeys: recentKeys, minDays: minDaysPerWindow),
			let prior = weekAggregate(history: history, dayKeys: priorKeys, minDays: minDaysPerWindow)
		else { return nil }
		return CareWindowComparison(
			recentAvgMinutes: recent.averageMinutesPerDay,
			priorAvgMinutes: prior.averageMinutesPerDay,
			deltaMinutes: recent.averageMinutesPerDay - prior.averageMinutesPerDay
		)
	}

	/// 「为什么没有升降结论」的有界说明（§7.4：撤掉结论不许留纯沉默）。
	/// 只在缺口**确由归因口径分桶**造成时给天数——样本本来就凑不够的那种不算，
	/// 因为那不是"再等几天就有"的缺口。返回 nil = 保持原空态。
	nonisolated static func pendingComparableDays(
		history: [DailyUsage],
		recentKeys: [String],
		priorKeys: [String],
		today: Date = Date(),
		calendar: Calendar = .current
	) -> Int? {
		guard !windowsComparable(history: history, recentKeys: recentKeys, priorKeys: priorKeys) else { return nil }
		let keys = Set(recentKeys).union(priorKeys)
		let inWindow = history.filter { keys.contains($0.dayKey) && $0.dwell80PlusMinutes != nil }
		// 未来日子会带的口径 = 全历史里最新一天的归因窗口；一天都没有就不许诺
		// （写成 compactMap 而非多行 filter 链：新 SDK 上 filter 有 Predicate 重载，跨行闭包会解析歧义）
		let marked = history.compactMap { d -> (String, Double)? in
			guard let gap = d.attributionGapSeconds else { return nil }
			return (d.dayKey, gap)
		}
		guard let target = marked.max(by: { $0.0 < $1.0 })?.1 else { return nil }
		let blocking = inWindow.filter { $0.attributionGapSeconds != target }
		guard !blocking.isEmpty else { return nil }
		// 只有"其余条件都已就绪、只差旧档熬出窗口"才值得给倒计时：样本本来就凑不够时，
		// 这句会变成一个兑现不了的 ETA（与强度侧 pendingSameBucketDays 同一纪律）
		guard weekAggregate(history: history, dayKeys: recentKeys, minDays: comparisonMinDays) != nil,
			  weekAggregate(history: history, dayKeys: priorKeys, minDays: comparisonMinDays) != nil
		else { return nil }
		// 某日要熬到 age > span−1 才离开「recent ∪ prior」并集窗口；视野盖不住就不解释
		let horizon = dayKeys(endingOn: today, count: recentKeys.count + priorKeys.count, calendar: calendar)
		var wait = 0
		for day in blocking {
			guard let age = horizon.firstIndex(of: day.dayKey) else { return nil }
			wait = max(wait, horizon.count - age)
		}
		return wait > 0 ? wait : nil
	}

	/// 面板文案：周聚合一行；对比一行；数据不足返回空数组（空态=沉默，不吓人）。
	/// 不用 DurationFormatter（其 MainActor 隔离）——这里保持 nonisolated 可测。
	nonisolated static func summaryLines(
		todayUsage: DailyUsage,
		history: [DailyUsage],
		today: Date = Date(),
		calendar: Calendar = .current
	) -> [String] {
		var lines: [String] = []
		if let todayMinutes = todayUsage.dwell80PlusMinutes {
			lines.append("高电量（80%+）驻留 \(formatMinutes(todayMinutes))")
		}
		let recent7 = dayKeys(endingOn: today, count: 7, calendar: calendar)
		if let week = weekAggregate(history: history, dayKeys: recent7) {
			lines.append("近7日驻留合计 \(formatMinutes(week.totalMinutes)) · 日均 \(formatMinutes(week.averageMinutesPerDay))")
		}
		let prior7 = dayKeys(
			endingOn: calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: today)) ?? today,
			count: 7,
			calendar: calendar
		)
		if let cmp = careResponseComparison(history: history, recentKeys: recent7, priorKeys: prior7) {
			let delta = cmp.deltaMinutes
			if delta < 0 {
				lines.append("较前7日日均少 \(formatMinutes(abs(delta)))（驻留下降）")
			} else if delta > 0 {
				lines.append("较前7日日均多 \(formatMinutes(delta))（驻留上升）")
			} else {
				lines.append("与前7日日均持平")
			}
		} else if let wait = pendingComparableDays(history: history, recentKeys: recent7, priorKeys: prior7, today: today, calendar: calendar) {
			// 升降句被归因口径挡住了：说清几天后两边可比。措辞刻意只承诺"可比"，
			// 不承诺"届时一定有升降结论"——后者还要用户的用电行为配合（§1 只提示不干预）
			lines.append("驻留升降约 \(wait) 天后可比")
		}
		return lines
	}

	/// 「今日用电」卡说明行全集（唯一出口）：插电占比 + 驻留各行。
	/// 卡片渲染与两列配平高度都从这一条取——多一行必然多带一份高度，
	/// 不会再出现"内容长出来了、声明高度还是旧的"那种配平失真。
	nonisolated static func noteLines(
		todayUsage: DailyUsage,
		history: [DailyUsage],
		today: Date = Date(),
		calendar: Calendar = .current
	) -> [String] {
		var lines: [String] = []
		if let share = todayUsage.acShare {
			lines.append(EnergyAggregation.plugShareLine(share))
		}
		lines.append(contentsOf: summaryLines(todayUsage: todayUsage, history: history, today: today, calendar: calendar))
		return lines
	}

	/// 说明行的单行高度。**不是估的**：`bash 工具/离屏验收.sh cards` 离屏量真卡，
	/// 0/2 行两组差值 / 2 = 12.0pt（size-9 行高 11 + 上行距 1）
	nonisolated static let noteLineHeight: CGFloat = 12
	/// 无七天图时的卡体自然高（头部 + 三格统计），同样由 cards 模式量出：54pt
	nonisolated static let dailySummaryBaseHeight: CGFloat = 54
	/// 七天柱图带来的高度差：实测 42pt（柱框 26 + 日期标签 + 间距）
	nonisolated static let dailySummaryChartHeight: CGFloat = 42

	/// 说明行可用文字宽：面板 584 − 左右内边距 12×2 − 两列间距 10 = 550，每列 275，
	/// 再扣卡片自身水平内边距 10×2 → 255pt；字号 9（折行换算见 PanelTextMetrics）
	nonisolated static let noteTextWidth: CGFloat = 255
	nonisolated static let noteFontSize: CGFloat = 9

	/// 一条说明文案在列宽里占几个「行高」：CJK 记 1、半角记 0.52 的全角当量除以每行预算后向上取整。
	/// 折行守卫就落在这里——以后加文案不必改高度，长度自己换算成行高单位
	nonisolated static func noteHeightUnits(_ text: String) -> Int {
		PanelTextMetrics.visualLines(text: text, availableWidth: noteTextWidth, fontSize: noteFontSize)
	}

	/// 「今日用电」卡展开高度：基础（有无七天柱图）+ 每条说明行按折行后的行高单位计费。
	nonisolated static func dailySummaryHeight(
		usage: DailyUsage,
		history: [DailyUsage],
		today: Date = Date(),
		calendar: Calendar = .current
	) -> CGFloat {
		let base = dailySummaryBaseHeight + (history.count >= 2 ? dailySummaryChartHeight : 0)
		let units = noteLines(todayUsage: usage, history: history, today: today, calendar: calendar)
			.reduce(0) { $0 + noteHeightUnits($1) }
		return base + noteLineHeight * CGFloat(units)
	}

	nonisolated static func formatMinutes(_ minutes: Int) -> String {
		if minutes < 60 { return "\(minutes) 分钟" }
		let h = minutes / 60
		let m = minutes % 60
		return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分钟"
	}

	/// C3→洞察：近 7 日 vs 前 7 日驻留对比。样本不足或变化不明显 → nil（不刷屏）。
	nonisolated static func trackingInsight(
		history: [DailyUsage],
		today: Date = Date(),
		calendar: Calendar = .current
	) -> ChargingHabitInsight? {
		let recent7 = dayKeys(endingOn: today, count: 7, calendar: calendar)
		guard let priorStart = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: today)) else {
			return nil
		}
		let prior7 = dayKeys(endingOn: priorStart, count: 7, calendar: calendar)
		guard let cmp = careResponseComparison(history: history, recentKeys: recent7, priorKeys: prior7) else {
			return nil
		}
		let delta = cmp.deltaMinutes
		if delta <= -15 {
			return ChargingHabitInsight(
				message: "近7日高电量驻留日均比前7日少 \(formatMinutes(abs(delta)))，方向正确",
				symbol: "leaf.fill"
			)
		}
		if delta >= 15 && cmp.recentAvgMinutes >= 90 {
			return ChargingHabitInsight(
				message: "近7日高电量驻留日均约 \(formatMinutes(cmp.recentAvgMinutes))，偏高——可试设置里的场景预设「办公 80%」",
				symbol: "battery.100percent"
			)
		}
		return nil
	}

	/// 周报附句：有对比结论才返回，避免周报在数据不足时瞎编
	nonisolated static func weeklyDigestLine(
		history: [DailyUsage],
		due: Date,
		calendar: Calendar = .current
	) -> String? {
		guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: due)?.start else { return nil }
		// 周报在周日发出：聚合「本周一～due 日」与「上一同长度窗」
		let recentKeys = dayKeys(endingOn: due, count: 7, calendar: calendar)
		let priorAnchor = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: due)) ?? due
		let priorKeys = dayKeys(endingOn: priorAnchor, count: 7, calendar: calendar)
		_ = weekStart
		guard let cmp = careResponseComparison(history: history, recentKeys: recentKeys, priorKeys: priorKeys) else {
			return nil
		}
		if cmp.deltaMinutes < 0 {
			return "高电量驻留日均比前一周少 \(formatMinutes(abs(cmp.deltaMinutes)))"
		}
		if cmp.deltaMinutes > 0 {
			return "高电量驻留日均比前一周多 \(formatMinutes(cmp.deltaMinutes))"
		}
		return "高电量驻留日均与前一周持平"
	}
}
