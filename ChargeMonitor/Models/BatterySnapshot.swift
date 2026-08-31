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

// 电池身份证：出厂写入硬件的静态信息（序列号、电芯厂商、生产日期、电芯配置），
// 启动时读一次即可，不随轮询变化；电芯电压取读取时刻的快照（均衡度变化很慢）
nonisolated struct BatteryIdentity: Equatable, Sendable {
	let serialNumber: String?
	let cellVendorName: String?
	let manufactureDateText: String?
	let designCapacityMAh: Int?
	// 各串联电芯的电压（mV），用于展示电芯数与压差（均衡度）
	let cellVoltagesMV: [Int]

	// 至少有一项可用信息才值得展示
	var isMeaningful: Bool {
		serialNumber != nil || cellVendorName != nil || manufactureDateText != nil || !cellVoltagesMV.isEmpty
	}
}

nonisolated struct PowerTier: Equatable, Sendable {
	var maxVoltageMV: Int
	var maxCurrentMA: Int
}
