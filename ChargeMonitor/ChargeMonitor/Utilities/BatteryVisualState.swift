import Foundation

/// 填充通道（v1.21.0）：面板头部"正在发生什么"的视觉语言，四态互斥。
/// 优先级：充电 > 已充满 > 低电 > 正常——插着电的"低电量"是待充电不是危机，
/// 与头部现有 isLowBattery（仅电池供电才警示）同一口径，不另造第二套阈值。
nonisolated enum BatteryFillMood: Equatable, Sendable {
	case calm         // 电池供电正常：accent 静态渐变，零常驻动效
	case full         // 已充满稳态：绿色静态渐变
	case charging     // 充电中：绿色波浪（周期随瞬时功率走 wavePeriod）
	case lowBattery   // 低电：暖橙→红渐变 + 轻呼吸
}

/// 视觉状态解析器（v1.21.0 纯函数）：把快照字段解析成填充通道与温度警示急促度。
/// 动效必须诚实——所有数值都是真实数据的单调映射，"越急 = 越紧急"；
/// 数据缺失一律退回安静态：缺数据 ≠ 有热度，缺功率 ≠ 在狂奔。
nonisolated enum BatteryVisualResolver {
	/// 充电波浪周期锚点：≤10W 慢节奏 2.4s，≥60W 快节奏 1.2s，之间线性
	nonisolated static let wavePeriodSlow: Double = 2.4
	nonisolated static let wavePeriodFast: Double = 1.2
	nonisolated static let wavePowerFloorW: Double = 10
	nonisolated static let wavePowerCeilW: Double = 60

	// —— 填充通道视觉令牌（v1.22.0，实现与证明测试同源）——
	/// 波浪主波不透明度上限：46pt 小面积装饰层，不许淹没中心符号与进度弧
	nonisolated static let waveFillMaxAlpha: Double = 0.26
	/// 静息底色不透明度上限：常态必须比动效态更安静（最正常 = 最安静）
	nonisolated static let calmBaseMaxAlpha: Double = 0.16

	/// 充电波浪周期（秒）：随瞬时充电功率连续加快（功率来自 IOKit 已有采样，零新增）。
	/// 功率缺失或为 0 按最慢——系统还没算出功率时，宁可从容不可吓人。
	nonisolated static func wavePeriod(chargingPowerW: Double?) -> Double {
		let watts = min(max(chargingPowerW ?? 0, 0), wavePowerCeilW)
		let t = max(0, (watts - wavePowerFloorW) / (wavePowerCeilW - wavePowerFloorW))
		return wavePeriodSlow - (wavePeriodSlow - wavePeriodFast) * t
	}

	/// 填充通道：soc 缺失一律平静——头部数字已经显示"—"，视觉跟着安静，不另编状态
	nonisolated static func fillMood(
		isCharging: Bool,
		isFull: Bool,
		onBatteryPower: Bool,
		socPercent: Int?,
		lowBatteryThreshold: Int
	) -> BatteryFillMood {
		if isCharging && !isFull { return .charging }
		if isFull { return .full }
		if onBatteryPower, let socPercent, socPercent <= lowBatteryThreshold { return .lowBattery }
		return .calm
	}

	/// 温度急促度：阈值处 1.0，+8°C 线性升到 2.0 封顶；阈值以下无警示（nil）。
	/// tempC 缺失 → nil（缺数据不等于在发热）。
	nonisolated static func temperatureUrgency(tempC: Double?, thresholdC: Double) -> Double? {
		guard let tempC, tempC >= thresholdC else { return nil }
		let t = min(max((tempC - thresholdC) / 8.0, 0), 1)
		return 1.0 + t
	}

	/// 温度警示迟滞：到阈值即出现，回落到阈值-1°C 才解除——
	/// 温度在阈值附近抖动时，预警边框不许一闪一闪。
	nonisolated static func shouldWarnHeat(tempC: Double?, thresholdC: Double, wasShowing: Bool) -> Bool {
		guard let tempC else { return false }
		return tempC >= (wasShowing ? thresholdC - 1 : thresholdC)
	}

	// —— 警示通道周期令牌（v1.23.0，实现与证明测试同源）——
	/// 高温边框脉冲基准周期（急促度 1.0 时）；2.0 封顶时减半到 0.8s
	nonisolated static let heatPulseBasePeriod: Double = 1.6
	/// 低电呼吸周期：比充电光点（1.8s）更慢更沉——提醒而非催促
	nonisolated static let lowBreathPeriod: Double = 2.2
}

/// 调试视觉注入口（v1.23.0 临时设施，v2.0.0 移除）：启动参数
/// `--miao-visual=charging|low|hot|hot-charging` 强制头部呈现对应状态，
/// 供用户在真实数据不可得时（高温/低电）目检验收。解析为纯函数可测。
nonisolated enum DebugVisualForce: Equatable, Sendable {
	case none, charging, low, hot, hotCharging

	nonisolated static func parse(_ arguments: [String]) -> DebugVisualForce {
		guard let flag = arguments.first(where: { $0.hasPrefix("--miao-visual=") }) else { return .none }
		switch flag.dropFirst("--miao-visual=".count) {
		case "charging": return .charging
		case "low": return .low
		case "hot": return .hot
		case "hot-charging": return .hotCharging
		default: return .none
		}
	}

	nonisolated static var current: DebugVisualForce {
		parse(ProcessInfo.processInfo.arguments)
	}
}
