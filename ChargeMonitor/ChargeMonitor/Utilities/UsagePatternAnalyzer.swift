import Foundation

// 锂电充电阶段：恒流（大电流快充）→ 恒压（电流回落）→ 涓流（接近满，零点几瓦）
nonisolated enum ChargingPhase: Equatable, Sendable {
	case constantCurrent
	case constantVoltage
	case trickle

	var label: String {
		switch self {
		case .constantCurrent: return "恒流快充"
		case .constantVoltage: return "恒压缓充"
		case .trickle: return "涓流补足"
		}
	}

	// 一句话解释"为什么充得慢/功率小"，供行值后缀与 tooltip 共用
	var explanation: String {
		switch self {
		case .constantCurrent: return "电流顶着上限跑，充电功率大"
		case .constantVoltage: return "电压到顶，电流逐步回落，充电功率下降属正常"
		case .trickle: return "接近满电，只补零点几瓦涓流；输入功率几乎都被整机用掉"
		}
	}
}

// 用电模式分析：时段热力图数据、异常检测、充电速度对比、电量计校准判定——
// 全部纯函数（输入可注入），供面板/洞察/单测共用同一套算法
nonisolated enum UsagePatternAnalyzer {
	// MARK: - 电量计校准

	// 电池模式下相邻采样电量差 ≥2% 视为跳变：
	// 正常 10 秒级采样掉电远小于 1%，突变说明电量计读数在自我修正（失准）
	static func isSocJump(from: Int, to: Int) -> Bool {
		abs(to - from) >= 2
	}

	// 时间窗内的跳变次数
	static func socJumpCount(_ events: [SocJumpEvent], withinDays days: Int, now: Date) -> Int {
		guard days > 0 else { return 0 }
		let cutoff = now.addingTimeInterval(-Double(days) * 86400)
		return events.filter { $0.date > cutoff }.count
	}

	// 跳变攒到阈值 → 电量计失准，建议做一次完整充放循环校准
	static func gaugeNeedsCalibration(jumpCount: Int, threshold: Int = 5) -> Bool {
		jumpCount >= threshold
	}

	// MARK: - 时段用电

	// 电池模式掉电计入对应小时桶；跨天（含首次）时有效天数 +1
	static func accumulatingHourlyDrain(
		_ stats: HourlyDrainStats,
		hour: Int,
		droppedPercent: Double,
		dayKey: String
	) -> HourlyDrainStats {
		var stats = stats
		if stats.lastDayKey != dayKey {
			stats.lastDayKey = dayKey
			stats.accumulatedDays += 1
		}
		guard droppedPercent > 0 else { return stats }
		stats.drainedByHour[stats.bucket(hour)] += droppedPercent
		return stats
	}

	// 每小时"日均掉电"百分点（累计 ÷ 有效天数）
	static func hourlyAverageDrain(_ stats: HourlyDrainStats) -> [Double] {
		let days = Double(max(stats.accumulatedDays, 1))
		return stats.drainedByHour.map { $0 / days }
	}

	// 热力图强度：每小时日均掉电占最大桶的比例（0~1）
	static func hourlyIntensity(_ stats: HourlyDrainStats) -> [Double] {
		let averages = hourlyAverageDrain(stats)
		guard let maxAvg = averages.max(), maxAvg > 0 else {
			return Array(repeating: 0, count: 24)
		}
		return averages.map { $0 / maxAvg }
	}

	// 用电高峰小时：日均掉电最大的小时；天数不足或掉电太少不给结论
	static func peakDrainHour(_ stats: HourlyDrainStats, minDays: Int = 3) -> Int? {
		guard stats.accumulatedDays >= minDays else { return nil }
		let averages = hourlyAverageDrain(stats)
		guard let maxAvg = averages.max(), maxAvg >= 0.5 else { return nil }
		return averages.firstIndex(of: maxAvg)
	}

	// MARK: - 时段温度画像

	// 每小时保留历史最高温（热暴露看峰值，均值会把午后高温摊平）；跨天推进有效天数
	static func accumulatingHourlyTemp(_ stats: HourlyTempStats, hour: Int, celsius: Double, dayKey: String) -> HourlyTempStats {
		var stats = stats
		if stats.lastDayKey != dayKey {
			stats.lastDayKey = dayKey
			stats.accumulatedDays += 1
		}
		let bucket = stats.bucket(hour)
		if celsius > stats.maxTempByHour[bucket] {
			stats.maxTempByHour[bucket] = celsius
		}
		return stats
	}

	// 温度 × 时段用电交叉洞察：用电高峰恰好叠着一天里电池最热的时段时，
	// 高温 + 高负载是最伤电池的组合——两个信号早就在手边，只差拼成一句话
	static func heatUsageOverlapInsight(
		drain: HourlyDrainStats,
		temp: HourlyTempStats,
		minDays: Int = 3,
		hotThresholdC: Double = 35
	) -> String? {
		guard drain.accumulatedDays >= minDays, temp.accumulatedDays >= minDays else { return nil }
		guard let peakHour = peakDrainHour(drain) else { return nil }
		let hourly = temp.maxTempByHour
		guard let hottest = hourly.enumerated().max(by: { $0.element < $1.element })?.offset,
			hourly[hottest] >= hotThresholdC
		else { return nil }
		// 相邻 1 小时内算重叠（温度峰值常滞后于用电峰值一点）
		guard abs(peakHour - hottest) <= 1 else { return nil }
		return String(format: "用电高峰 %d 点恰好叠着电池最热的时段（该时段历史峰值 %.0f°C）——高温加高负载最伤电池，注意散热", peakHour, hourly[hottest])
	}

	// MARK: - 异常检测

	// 近 7 天日均用电 vs 之前 21 天基线（今天不完整不计入）；
	// 基线不足 10 天或基线太低（日均 <5%）不具备比较意义，返回 nil
	static func drainAnomaly(dailyHistory: [DailyUsage], todayKey: String) -> (recentAvg: Double, baselineAvg: Double)? {
		let usable = dailyHistory.filter { $0.dayKey < todayKey }
		guard usable.count >= 17 else { return nil }

		let recent = usable.suffix(7)
		let baseline = usable.dropLast(7).suffix(21)
		guard baseline.count >= 10 else { return nil }

		let recentAvg = recent.reduce(0.0) { $0 + Double($1.drainedPercent) } / Double(recent.count)
		let baselineAvg = baseline.reduce(0.0) { $0 + Double($1.drainedPercent) } / Double(baseline.count)
		guard baselineAvg >= 5 else { return nil }
		return (recentAvg, baselineAvg)
	}

	// MARK: - 充电速度对比

	// 本次充电 vs 历史平均充速（%/分钟）；时长太短、涨得太少或样本不足不给结论。
	// 会话认得出充电器时优先和"同一只头"比——不同头的速度本就不一样，混着比没有意义
	static func chargeSpeedComparison(current: ChargeSession, history: [ChargeSession], chargerAliases: Set<String> = []) -> String? {
		let gained = current.endPercent - current.startPercent
		guard current.durationMinutes >= 5, gained >= 10 else { return nil }
		let speed = Double(gained) / Double(current.durationMinutes)

		let eligible = history.filter {
			$0.startDate != current.startDate
				&& $0.durationMinutes >= 5
				&& ($0.endPercent - $0.startPercent) >= 10
		}
		let sameCharger: [ChargeSession] = current.chargerKey.map { key in
			// 识别 v2：归并档案的历史会话键是别名——同一只头的降档会话也进对比池
			eligible.filter { $0.chargerKey == key || chargerAliases.contains($0.chargerKey ?? "") }
		} ?? []
		let pool = sameCharger.count >= 2 ? sameCharger : eligible
		guard pool.count >= 2 else { return nil }

		let avgSpeed = pool.reduce(0.0) {
			$0 + Double($1.endPercent - $1.startPercent) / Double($1.durationMinutes)
		} / Double(pool.count)

		let scope = sameCharger.count >= 2 ? "用这只充电器" : "平时"
		let ratio = avgSpeed > 0 ? speed / avgSpeed : 1
		if ratio >= 1.2 {
			return String(format: "本次充速 %.1f%%/分钟，比\(scope)快约 %.0f%%", speed, (ratio - 1) * 100)
		}
		if ratio <= 0.8 {
			return String(format: "本次充速 %.1f%%/分钟，比\(scope)慢约 %.0f%%", speed, (1 - ratio) * 100)
		}
		return String(format: "本次充速 %.1f%%/分钟，与\(scope)相当", speed)
	}

	// MARK: - 充电阶段

	// 锂电充电阶段（CC/CV）判定：电量越接近满，充电电流按指数衰减——
	// 面板"充电功率 0.3W"和"输入功率 20W"并存的困惑就来自这里（涓流期电都被整机用掉）
	// 判定只看电量（电池端电压与电量强相关），不依赖功率样本，避免功率波动导致阶段跳变
	static func chargingPhase(socPercent: Int?) -> ChargingPhase? {
		guard let soc = socPercent, (0...100).contains(soc) else { return nil }
		switch soc {
		case ..<80:
			// 恒流阶段：电流顶着上限跑，功率大
			return .constantCurrent
		case 80..<95:
			// 恒压阶段：电压到顶后电流逐步回落
			return .constantVoltage
		default:
			// 涓流阶段：接近满电，只剩零点几瓦，属正常物理现象
			return .trickle
		}
	}

	// MARK: - 应用活跃时段归因

	// 3 小时滑动窗口的峰值时段：窗口占比 ≥60% 且总时长 ≥30 分钟才给结论
	// （分布太平说明全天都在用，"集中在几点"就是伪命题）
	static func peakActivityWindow(
		secondsByHour: [Double],
		windowHours: Int = 3,
		minShare: Double = 0.6,
		minTotalSeconds: Double = 30 * 60
	) -> (start: Int, end: Int)? {
		guard secondsByHour.count == 24 else { return nil }
		let total = secondsByHour.reduce(0, +)
		guard total >= minTotalSeconds else { return nil }
		var bestStart = 0
		var bestSum = 0.0
		for start in 0...(24 - windowHours) {
			let sum = secondsByHour[start..<start + windowHours].reduce(0, +)
			if sum > bestSum {
				bestSum = sum
				bestStart = start
			}
		}
		guard bestSum / total >= minShare else { return nil }
		return (bestStart, bestStart + windowHours)
	}

	// 寿命预测的方法披露（纯函数，供单测）：把"预言"降格为"有依据的估计"——
	// 用户问"你凭什么说 3 个月"时，答案就在悬停里；到期偏差也不算应用失约
	static func projectionCaveat(spanDays: Double) -> String {
		"基于最近 \(Int(spanDays.rounded())) 天健康度首尾两点的线性外推；实际老化受温度与充电习惯影响，可能更快或更慢"
	}

	// MARK: - 日期键

	// 与历史记录同源的 POSIX 公历日期键（dayKey 是落盘主键，必须公历）
	private static let dayKeyFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter
	}()

	static func dayKeyString(_ date: Date) -> String {
		dayKeyFormatter.string(from: date)
	}

	// 月份前缀键（"yyyy-MM"），与 dayKey 同源公历；月报按它匹配自然月。
	// 必须跟随传入 calendar 的时区（而不是系统时区），否则注入非本地时区测试/跨时区运行会错位；
	// 且强制公历年月，避免佛历等系统日历把年份偏成 2570。
	static func monthKeyString(_ date: Date, calendar: Calendar = .current) -> String {
		var gregorian = Calendar(identifier: .gregorian)
		gregorian.timeZone = calendar.timeZone
		let c = gregorian.dateComponents([.year, .month], from: date)
		return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
	}
}