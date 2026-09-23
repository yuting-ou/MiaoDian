import Foundation

// E4 场景系数·本机强度校准（纯函数）
// 诚实口径：不是 per-scenario 回归——历史没有「用户当时在开会还是轻度」标注，
// 不能从 drainedPercent 编造出各场景系数。做的是「本机相对自身基线的放电强度」：
// 近期比自己的基线更费电时，有界收紧场景系数（续航偏保守），反之亦然。
// 数据全部从既有 DailyUsage 推导，不新增 defaults 键。
// 能量悖论：无新采样/定时器；亮度与网络因子经审计不进本轮（持续读显示/网络成本过高）。
nonisolated enum RuntimeScenarioCalibration {
	/// 出厂系数允许的相对伸缩；再叠绝对上下限，防异常日把系数打飞
	nonisolated static let factorRange: ClosedRange<Double> = 0.80...1.25
	nonisolated static let absoluteMultiplierRange: ClosedRange<Double> = 0.40...2.50

	/// 醒着的电池供电时长：分子（drainedPercent）只统计醒着时段的掉电，v2.9.2 起
	/// batterySeconds 还含整夜睡眠，必须减回去才与分子同源。旧行无该字段=nil，
	/// 减法自动退化为原值（旧口径 batterySeconds 本就不含睡眠）→ 跨升级日不跳变。
	nonisolated static func awakeBatterySeconds(_ day: DailyUsage) -> Double {
		let slept = min(day.batterySeconds, day.sleepBatterySeconds ?? 0)
		return max(0, day.batterySeconds - slept)
	}

	/// 单日放电强度 %/小时；醒着不足半小时或无掉电则无样本（缺记录不冒充 0）
	nonisolated static func dayIntensity(_ day: DailyUsage) -> Double? {
		let awake = awakeBatterySeconds(day)
		guard awake >= 30 * 60, day.drainedPercent > 0 else { return nil }
		let hours = awake / 3600
		guard hours > 0 else { return nil }
		return Double(day.drainedPercent) / hours
	}

	/// 从日历史推出有效强度样本（新→旧，即 dayKey 降序附近的插入序由调用方保证）
	nonisolated static func intensities(history: [DailyUsage]) -> [Double] {
		history.compactMap(dayIntensity)
	}

	/// 同桶才可比：以时间最新一行的归因窗口为参照，只保留同窗口的强度样本。
	/// 归因窗口的覆盖面会随版本变（v2.9.4 把秒数从 30 秒小帽放宽到与掉电同窗），
	/// 旧行的醒着秒数系统性偏小 → 强度偏高；若让"近 3 日（新口径）÷ 基线 14 日（旧口径）"
	/// 混进同一句中位数比较，会出现数倍假降幅、因子贴到 0.80 夹紧下限、续航预测转乐观。
	/// 旧行 attributionGapSeconds=nil 自成一桶：升级前彼此仍可比，只是不与新口径混用。
	nonisolated static func comparableSamples(history: [DailyUsage]) -> [Double] {
		let dated = history
			.sorted { $0.dayKey < $1.dayKey }
			.compactMap { day in dayIntensity(day).map { (day.attributionGapSeconds, $0) } }
		guard !dated.isEmpty else { return [] }
		// 参照取最后一行的窗口值本身（可能是 nil）：nil 桶也要能自比，
		// 写成 guard let 会把"无窗口标记"当成"没有参照"，把整批旧档一起判废
		let reference = dated[dated.count - 1].0
		return dated.filter { $0.0 == reference }.map(\.1)
	}

	/// 近期中位数 / 基线中位数，夹紧到 factorRange；样本不足 → nil（维持出厂）
	/// recentCount：最近 N 个有效样本；baselineMax：其前至多 M 个；baselineMin：至少这么多才谈「基线」
	nonisolated static func intensityFactor(
		history: [DailyUsage],
		recentCount: Int = 3,
		baselineMax: Int = 14,
		baselineMin: Int = 5
	) -> Double? {
		// 按 dayKey 升序取样本（不依赖 history 插入序），且只在同一口径桶内比较
		let sorted = comparableSamples(history: history)
		guard sorted.count >= recentCount + baselineMin else { return nil }
		let recent = Array(sorted.suffix(recentCount))
		let baselineStart = max(0, sorted.count - recentCount - baselineMax)
		let baselineEnd = sorted.count - recentCount
		guard baselineEnd > baselineStart else { return nil }
		let baseline = Array(sorted[baselineStart..<baselineEnd])
		guard baseline.count >= baselineMin else { return nil }
		guard let rMed = median(recent), let bMed = median(baseline), bMed > 0.05 else { return nil }
		let raw = rMed / bMed
		return min(max(raw, factorRange.lowerBound), factorRange.upperBound)
	}

	/// 出厂系数 × 本机因子，再夹紧；factor 为 nil 时原样返回出厂值
	nonisolated static func effectiveMultiplier(factory: Double, factor: Double?) -> Double {
		guard let factor else { return factory }
		let scaled = factory * min(max(factor, factorRange.lowerBound), factorRange.upperBound)
		let lo = max(absoluteMultiplierRange.lowerBound, factory * 0.85)
		let hi = min(absoluteMultiplierRange.upperBound, factory * 1.20)
		return min(max(scaled, lo), hi)
	}

	/// 卡片底部口径句；无因子则空（不刷屏）。
	/// 显示的是强度因子，不是每个场景夹紧后的倍率——避免用户以为 ×1.25 就是各场景系数。
	nonisolated static func calibrationNote(factor: Double?) -> String {
		guard let factor, abs(factor - 1.0) >= 0.02 else { return "" }
		return String(format: "已按本机近期用电强度微调（强度 ×%.2f，场景系数已夹紧）", factor)
	}

	nonisolated static func median(_ values: [Double]) -> Double? {
		guard !values.isEmpty else { return nil }
		let sorted = values.sorted()
		let mid = sorted.count / 2
		if sorted.count % 2 == 0 {
			return (sorted[mid - 1] + sorted[mid]) / 2
		}
		return sorted[mid]
	}
}
