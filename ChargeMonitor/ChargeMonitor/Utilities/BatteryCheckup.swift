import Foundation

// 电池体检评分：健康度、循环次数、温度、充电习惯四项加权，0~100 分 + 一句评语
// 纯计算逻辑，nonisolated 方便单元测试直接调
nonisolated struct BatteryCheckup: Equatable, Sendable {
	let score: Int
	let verdict: String
	// 用了中性估计的分项名：数据读不到时不硬给分，但总分"看起来更确定"——
	// 冷启动时如实标注，用户知道这个分数有几分成色是估的
	var estimatedInputs: [String] = []
	
	// 评分等级：分档阈值的单一数据源——评语与各处配色（头部/卡片/分享卡）都基于它，
	// 避免四处各写一份 85/70/55 分档、改一处忘别处导致“同分不同色/评语对不上”
	enum Tier {
		case excellent, good, aging, poor
	}
	
	nonisolated static func tier(for score: Int) -> Tier {
		switch score {
		case 85...: return .excellent
		case 70..<85: return .good
		case 55..<70: return .aging
		default: return .poor
		}
	}
	
	var tier: Tier { Self.tier(for: score) }
	
	// 权重：健康度 55 + 循环 25 + 温度 10 + 高电量驻留 10
	nonisolated static func evaluate(
		healthPercent: Int?,
		cycleCount: Int?,
		temperatureC: Double?,
		highSocDwellShare: Double?
	) -> BatteryCheckup? {
		// 健康度是核心指标，读不到就不硬给分
		guard let health = healthPercent else { return nil }

		// 100% 满分，80%（官方换电参考线）归零
		let healthScore = clamp(Double(health - 80) / 20 * 55, upper: 55)
		var estimated: [String] = []
		// 0 次满分，1000 次（官方标称寿命）归零；读不到给中上估计
		let cycleScore: Double
		if let cycles = cycleCount {
			cycleScore = clamp((1 - Double(cycles) / 1000) * 25, upper: 25)
		} else {
			cycleScore = 18
			estimated.append("循环")
		}
		// ≤35°C 满分，45°C 以上归零；读不到给中上估计
		let tempScore: Double
		if let temp = temperatureC {
			tempScore = clamp((45 - temp) / 10 * 10, upper: 10)
		} else {
			tempScore = 7
			estimated.append("温度")
		}
		// 高电量驻留是电化学应力的直接度量：80%+ 驻留越多越伤电池
		// （≤20% 给满分，>50% 重扣）；读不到给中性估计
		let habitScore: Double
		if let share = highSocDwellShare {
			habitScore = share > 0.5 ? 5 : (share > 0.2 ? 8 : 10)
		} else {
			habitScore = 8
			estimated.append("驻留")
		}

		let total = Int((healthScore + cycleScore + tempScore + habitScore).rounded())
		return BatteryCheckup(score: total, verdict: verdict(for: total), estimatedInputs: estimated)
	}
	
	nonisolated static func verdict(for score: Int) -> String {
		switch tier(for: score) {
		case .excellent: return "状态优秀，继续保持"
		case .good: return "状态良好，正常使用"
		case .aging: return "开始老化，注意保养"
		case .poor: return "老化明显，建议检测电池"
		}
	}
	
	private nonisolated static func clamp(_ value: Double, upper: Double) -> Double {
		min(max(value, 0), upper)
	}
}
