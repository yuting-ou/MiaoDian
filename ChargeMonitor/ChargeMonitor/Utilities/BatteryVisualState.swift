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
}
