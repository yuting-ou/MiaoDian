import Foundation

// 电池体检评分：健康度、循环次数、温度、充电习惯四项加权，0~100 分 + 一句评语
// 纯计算逻辑，nonisolated 方便单元测试直接调
struct BatteryCheckup: Equatable {
	let score: Int
	let verdict: String
	
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
	
	// 权重：健康度 55 + 循环 25 + 温度 10 + 充电习惯 10
	nonisolated static func evaluate(
		healthPercent: Int?,
		cycleCount: Int?,
		temperatureC: Double?,
		acShare: Double?
	) -> BatteryCheckup? {
		// 健康度是核心指标，读不到就不硬给分
		guard let health = healthPercent else { return nil }
		
		// 100% 满分，80%（官方换电参考线）归零
		let healthScore = clamp(Double(health - 80) / 20 * 55, upper: 55)
		// 0 次满分，1000 次（官方标称寿命）归零；读不到给中上估计
		let cycleScore = cycleCount.map { clamp((1 - Double($0) / 1000) * 25, upper: 25) } ?? 18
		// ≤35°C 满分，45°C 以上归零；读不到给中上估计
		let tempScore = temperatureC.map { clamp((45 - $0) / 10 * 10, upper: 10) } ?? 7
		// 长期插电（占比 >90%）对电池不算友好，扣一半
		let habitScore: Double
		if let share = acShare {
			habitScore = share > 0.9 ? 5 : 10
		} else {
			habitScore = 8
		}
		
		let total = Int((healthScore + cycleScore + tempScore + habitScore).rounded())
		return BatteryCheckup(score: total, verdict: verdict(for: total))
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
