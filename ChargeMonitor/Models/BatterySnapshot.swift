import Foundation

nonisolated struct BatterySnapshot: Equatable, Sendable {
	var powerSource: PowerSourceType = .battery
	var isCharging: Bool = false
	var isFull: Bool = false
	// 系统“低电量模式”是否开启，会明显影响功耗和掉电速度
	var isLowPowerModeEnabled: Bool = false
	
	var adapterName: String?
	var adapterManufacturer: String?
	
	var chargingProtocol: String?
	var negotiatedVoltageMV: Int?
	var negotiatedCurrentMA: Int?
	var adapterRatedWatts: Int?
	var powerTiers: [PowerTier] = []
	var activeTierIndex: Int?
	
	var cycleCount: Int?
	var stateOfChargePercent: Int?
	var designCapacityMAh: Int?
	var maxCapacityMAh: Int?
	var temperatureC: Double?
	// 电池端实时电流（正充负放，mA）与电压（mV）
	var batteryAmperageMA: Int?
	var batteryVoltageMV: Int?
	var timeToFullChargeMinutes: Int?
	var timeToEmptyMinutes: Int?

	var chargingPowerW: Double?
	var adapterInputPowerW: Double?
	var currentPowerW: Double?
	var isFastCharging: Bool = false
	
	var systemUptimeSeconds: TimeInterval = 0
	
	// 健康度 = 当前最大容量 / 出厂设计容量
	var healthPercent: Int? {
		guard let design = designCapacityMAh, let max = maxCapacityMAh, design > 0 else { return nil }
		return Int((Double(max) / Double(design) * 100).rounded())
	}
}

nonisolated enum PowerSourceType: Equatable, Sendable {
	case battery
	case powerAdapter
}

nonisolated struct PowerTier: Equatable, Sendable {
	var maxVoltageMV: Int
	var maxCurrentMA: Int
}
