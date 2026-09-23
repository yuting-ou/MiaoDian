import Foundation

/// E3 能耗聚合（纯函数）：把 DailyUsage 聚成日/周/月窗口统计。
/// 诚实边界：
/// - 日均按「有效样本日」摊，不用日历天数——缺记录的天不冒充「用了 0 电」
/// - 不承诺月级电量曲线（细粒度 SOC 仅近 24h，属 HourlyDrainStats / socSamples）
/// - 样本不足 → 日均/对比为 nil，调用方应沉默
nonisolated enum EnergyAggregation {
	/// 面板「醒着插电占比」那行的唯一出口。文案必须住在逻辑层而不是 View 里：
	/// UI 不进测试面，写在 View 里的字面量测试引用不到，长度守卫就只能重打一遍同样的
	/// 字符串（改长改词都不会红，等于没守卫）——v2.9.9 的对抗审查正是抓到这里。
	nonisolated static func plugShareLine(_ share: Double) -> String {
		String(format: "醒着 %.0f%% 的时间插着电源", share * 100)
	}

	nonisolated struct WindowStats: Equatable, Sendable {
		let dataDays: Int
		let totalDrainedPercent: Int
		let totalChargedPercent: Int
		let avgDrainedPerDataDay: Double?
		// 醒着口径的时长（睡眠补记已减掉）：与 DailyUsage.acShare 同一条减法，
		// 窗口级插电占比才不会把"夜里合盖在电池上"算成用户不插电
		let awakeACSeconds: Double
		let awakeBatterySeconds: Double
		let dwell80PlusSeconds: Double
		let peakDrainDayKey: String?
		let peakDrainPercent: Int?

		/// 窗口级插电占比（醒着口径）；醒着样本不足半小时不给结论
		var acShare: Double? {
			let total = awakeACSeconds + awakeBatterySeconds
			guard total >= 30 * 60 else { return nil }
			return awakeACSeconds / total
		}

		var dwell80PlusMinutes: Int? {
			guard dwell80PlusSeconds > 0 else { return nil }
			return Int(dwell80PlusSeconds / 60)
		}
	}

	nonisolated struct DrainComparison: Equatable, Sendable {
		let recentAvgPerDataDay: Double
		let priorAvgPerDataDay: Double
		let deltaPerDataDay: Double
	}

	/// 有效能耗样本：有掉电/充入，或醒着被观测时长 ≥ 半小时（与 DailyUsage.acShare 同门）。
	/// v2.9.9 起这条门槛从「含睡眠补记的总时长」改回「醒着时长」：只靠整夜补记凑够
	/// 半小时的日子（当天一帧醒着的都没记到）不该算样本日——那等于把 0% 用电抬进日均
	/// 分母，重演「缺记录不冒充 0」。旧档本就无睡眠补记，减法退化为原值，不跨口径。
	nonisolated static func hasEnergySample(_ day: DailyUsage) -> Bool {
		day.drainedPercent > 0 || day.chargedPercent > 0 || day.awakeObservationSeconds >= 30 * 60
	}

	nonisolated static func aggregate(history: [DailyUsage], dayKeys: [String]) -> WindowStats {
		let keySet = Set(dayKeys)
		return aggregateMatching(history: history) { keySet.contains($0.dayKey) }
	}

	nonisolated static func monthAggregate(history: [DailyUsage], monthPrefix: String) -> WindowStats {
		aggregateMatching(history: history) { $0.dayKey.hasPrefix(monthPrefix) }
	}

	private nonisolated static func aggregateMatching(
		history: [DailyUsage],
		match: (DailyUsage) -> Bool
	) -> WindowStats {
		var dataDays = 0
		var drained = 0
		var charged = 0
		var awakeACSeconds = 0.0
		var awakeBatterySeconds = 0.0
		var dwellSeconds = 0.0
		var peakKey: String?
		var peakDrain = 0
		for day in history where match(day) {
			guard hasEnergySample(day) else { continue }
			dataDays += 1
			drained += day.drainedPercent
			charged += day.chargedPercent
			awakeACSeconds += day.awakeACSeconds
			awakeBatterySeconds += day.awakeBatterySeconds
			dwellSeconds += day.soc80to90Seconds + day.soc90to100Seconds
			if day.drainedPercent > peakDrain {
				peakDrain = day.drainedPercent
				peakKey = day.dayKey
			}
		}
		let avg: Double? = dataDays > 0 ? Double(drained) / Double(dataDays) : nil
		return WindowStats(
			dataDays: dataDays,
			totalDrainedPercent: drained,
			totalChargedPercent: charged,
			avgDrainedPerDataDay: avg,
			awakeACSeconds: awakeACSeconds,
			awakeBatterySeconds: awakeBatterySeconds,
			dwell80PlusSeconds: dwellSeconds,
			peakDrainDayKey: peakKey,
			peakDrainPercent: peakKey == nil ? nil : peakDrain
		)
	}

	/// 近窗 vs 前窗的日均用电对比；两侧有效样本日不足则 nil
	nonisolated static func drainComparison(
		history: [DailyUsage],
		recentKeys: [String],
		priorKeys: [String],
		minDaysPerWindow: Int = 2
	) -> DrainComparison? {
		let recent = aggregate(history: history, dayKeys: recentKeys)
		let prior = aggregate(history: history, dayKeys: priorKeys)
		guard
			recent.dataDays >= minDaysPerWindow,
			prior.dataDays >= minDaysPerWindow,
			let rAvg = recent.avgDrainedPerDataDay,
			let pAvg = prior.avgDrainedPerDataDay
		else { return nil }
		return DrainComparison(
			recentAvgPerDataDay: rAvg,
			priorAvgPerDataDay: pAvg,
			deltaPerDataDay: rAvg - pAvg
		)
	}

	/// 小结/报告用的一行摘要；无有效样本返回空串
	nonisolated static func digestSummary(label: String, stats: WindowStats) -> String {
		guard stats.dataDays > 0 else { return "" }
		if let avg = stats.avgDrainedPerDataDay {
			let avgInt = Int(avg.rounded())
			return "\(label)用电 \(stats.totalDrainedPercent)%（记录 \(stats.dataDays) 天，日均 \(avgInt)%）、充入 \(stats.totalChargedPercent)%"
		}
		return "\(label)用电 \(stats.totalDrainedPercent)%、充入 \(stats.totalChargedPercent)%"
	}

	/// 报告【最近用电】前置聚合行；无窗口样本则空
	nonisolated static func reportLines(
		history: [DailyUsage],
		endingOn today: Date,
		calendar: Calendar = .current
	) -> [String] {
		var lines: [String] = []
		let recent7Keys = DwellTracking.dayKeys(endingOn: today, count: 7, calendar: calendar)
		let week = aggregate(history: history, dayKeys: recent7Keys)
		var weekLine = digestSummary(label: "近7日", stats: week)
		if !weekLine.isEmpty {
			if let share = week.acShare {
				weekLine += String(format: "、醒着插电占比 %.0f%%", share * 100)
			}
			if let peakKey = week.peakDrainDayKey, let peak = week.peakDrainPercent, peak > 0 {
				weekLine += "、峰值 \(peakKey) \(peak)%"
			}
			lines.append(weekLine)
		}
		let monthPrefix = UsagePatternAnalyzer.monthKeyString(today, calendar: calendar)
		let month = monthAggregate(history: history, monthPrefix: monthPrefix)
		let monthLine = digestSummary(label: "本月", stats: month)
		if !monthLine.isEmpty {
			lines.append(monthLine + "（日均有记录天数；无月级电量曲线）")
		}
		return lines
	}
}
