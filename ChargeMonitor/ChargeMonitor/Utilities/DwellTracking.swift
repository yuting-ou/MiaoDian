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
	nonisolated static func dayKeys(
		endingOn today: Date,
		count: Int,
		calendar: Calendar = .current,
		ascending: Bool = false
	) -> [String] {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		var keys: [String] = []
		var date = calendar.startOfDay(for: today)
		for _ in 0..<max(0, count) {
			keys.append(formatter.string(from: date))
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

	/// 保养响应对比：recentKeys 窗口日均 vs priorKeys 窗口日均。
	/// 两侧有效样本各 ≥ 2 才给结论；否则 nil（避免单日噪声当效果）。
	nonisolated static func careResponseComparison(
		history: [DailyUsage],
		recentKeys: [String],
		priorKeys: [String],
		minDaysPerWindow: Int = 2
	) -> CareWindowComparison? {
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
		}
		return lines
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
