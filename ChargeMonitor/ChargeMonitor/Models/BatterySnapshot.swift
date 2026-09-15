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
	// 系统充电暂缓签名（AppleSmartBattery → ChargerData → NotChargingReason 原始值），读不到为 nil
	var notChargingReason: Int?
	
	var systemUptimeSeconds: TimeInterval = 0
	
	// 「优化电池充电」暂缓位：本机（Apple Silicon）80% 按住时实测恒为
	// 16777216 = 0x01000000（macOS 26.6.2：35 分钟 2000+ 帧稳定；升到 27.0 后经
	// reader 真实代码路径复现同值）。负例同样已实测：同一优化周期恢复充电时
	// （27.0，91% charging，8 帧连续）该位清零 NotChargingReason=0——"充电中不误报"有真机依据。
	// isCharging 门保留：Apple 未文档化该位语义，跨机型/跨版本不许把本机实测外推成保证，
	// 判定因此不依赖"充电中必为 0"（M1-C2 设计裁决）
	nonisolated static let optimizedChargingHoldBit = 0x01000000
	
	nonisolated static func isSystemChargeHeld(
		powerSource: PowerSourceType,
		isCharging: Bool,
		isFull: Bool,
		notChargingReason: Int?
	) -> Bool {
		guard powerSource == .powerAdapter, !isCharging, !isFull else { return false }
		guard let reason = notChargingReason else { return false }
		return reason & optimizedChargingHoldBit != 0
	}
	
	// 系统正在暂缓充电（纯读判定，面板露出与保养提醒静默共用）
	var isSystemChargeHeld: Bool {
		Self.isSystemChargeHeld(
			powerSource: powerSource,
			isCharging: isCharging,
			isFull: isFull,
			notChargingReason: notChargingReason
		)
	}
	
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
