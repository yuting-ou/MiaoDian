import Foundation
import IOKit
import IOKit.ps

struct AdapterInfo {
	var name: String?
	var manufacturer: String?
}

struct ChargerProtocolInfo {
	var protocolName: String?
	var negotiatedVoltageMV: Int?
	var negotiatedCurrentMA: Int?
	var ratedWatts: Int?
	var tiers: [PowerTier]
	var activeTierIndex: Int?
}

struct BatteryMetrics {
	var cycleCount: Int?
	var stateOfChargePercent: Int?
	var chargingPowerW: Double?
	var currentPowerW: Double?
	var isExternalPowerConnected: Bool?
}

struct IOKitBatteryReader {
	private static let fastChargePowerThresholdW = 50.0
	static let minimumVisibleWatts = 0.1
	
	// SMC 实时传感器：注册表数据十几秒才刷新，功率类指标优先走 SMC
	private let smcReader = SMCPowerReader()
	
	private struct PowerReadingContext {
		let isCharging: Bool
		let isExternalPowerConnected: Bool
		let powerSource: PowerSourceType
	}
	
	private static let acPower = kIOPSACPowerValue as String
	private static let batteryPower = kIOPSBatteryPowerValue as String
	
	private static let keyTransportType = kIOPSTransportTypeKey as String
	private static let keyPSType = kIOPSTypeKey as String
	private static let keyIsCharging = kIOPSIsChargingKey as String
	private static let keyTimeToFull = kIOPSTimeToFullChargeKey as String
	private static let keyTimeToEmpty = kIOPSTimeToEmptyKey as String
	private static let keyCurrentCapacity = kIOPSCurrentCapacityKey as String
	
	func readSnapshot() async -> BatterySnapshot {
		let context = readPowerSourcesContext()
		let powerSource = mapPowerSource(context?.providingPowerSourceType) ?? .battery
		let adapter = (powerSource == .powerAdapter) ? readAdapterInfo() : nil
		let internalBattery = context?.internalBattery
		let smartBatteryProps = readSmartBatteryProperties()
		
		let isCharging = internalBattery?.bool(Self.keyIsCharging) ?? false
		let metrics = readBatteryMetrics(props: smartBatteryProps, internalBattery: internalBattery, powerSource: powerSource, isCharging: isCharging)
		let timeToFull = readTimeToFullChargeMinutes(internalBattery: internalBattery)
		let timeToEmpty = readTimeToEmptyMinutes(internalBattery: internalBattery)
		let isExternalPowerConnected = metrics.isExternalPowerConnected ?? (adapter != nil) || (powerSource == .powerAdapter)
		
		let chargingByWire = isExternalPowerConnected
		let chargingPower = metrics.chargingPowerW ?? 0
		let isFastCharging = chargingByWire && chargingPower >= Self.fastChargePowerThresholdW
		
		var snapshot = BatterySnapshot()
		snapshot.systemUptimeSeconds = Self.readUptimeSeconds()
		snapshot.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
		snapshot.powerSource = powerSource
		snapshot.isCharging = isCharging
		snapshot.isFastCharging = isFastCharging
		snapshot.isFull = isFull(metrics.stateOfChargePercent)
		
		if chargingByWire, let adapter {
			snapshot.adapterName = adapter.name
			snapshot.adapterManufacturer = adapter.manufacturer
		}
		
		if chargingByWire, let protocolInfo = readChargerProtocolInfo(props: smartBatteryProps) {
			snapshot.chargingProtocol = protocolInfo.protocolName
			snapshot.negotiatedVoltageMV = protocolInfo.negotiatedVoltageMV
			snapshot.negotiatedCurrentMA = protocolInfo.negotiatedCurrentMA
			snapshot.adapterRatedWatts = protocolInfo.ratedWatts
			snapshot.powerTiers = protocolInfo.tiers
			snapshot.activeTierIndex = protocolInfo.activeTierIndex
		}
		
		if chargingByWire {
			snapshot.adapterInputPowerW = readAdapterInputPowerW(props: smartBatteryProps)
		}
		
		snapshot.cycleCount = metrics.cycleCount
		snapshot.stateOfChargePercent = metrics.stateOfChargePercent
		
		if let props = smartBatteryProps {
			snapshot.designCapacityMAh = props.int("DesignCapacity")
			snapshot.maxCapacityMAh = props.int("AppleRawMaxCapacity") ?? props.int("NominalChargeCapacity")
			snapshot.temperatureC = readTemperatureC(props: props)
			// 电池端实时电流/电压，与功率计算同源（InstantAmperage 正充负放）
			if let amperage = props.int64("InstantAmperage"), abs(amperage) < 100_000 {
				snapshot.batteryAmperageMA = Int(amperage)
			}
			if let voltage = props.int64("Voltage"), voltage > 0, voltage < 100_000 {
				snapshot.batteryVoltageMV = Int(voltage)
			}
		}
		snapshot.timeToFullChargeMinutes = timeToFull
		snapshot.timeToEmptyMinutes = timeToEmpty
		snapshot.chargingPowerW = metrics.chargingPowerW
		snapshot.currentPowerW = metrics.currentPowerW
		
		// SMC 实时功率覆盖：整机功耗、适配器输入都是亚秒级更新的真实时值
		if let systemPowerW = smcReader.systemPowerW(), systemPowerW > 0 {
			snapshot.currentPowerW = systemPowerW
		}
		if chargingByWire, let adapterPowerW = smcReader.adapterInputPowerW(), adapterPowerW > 0 {
			snapshot.adapterInputPowerW = adapterPowerW
		}
		if isCharging, let batteryPowerW = smcReader.batteryPowerW(), batteryPowerW > 0 {
			snapshot.chargingPowerW = batteryPowerW
		}
		
		return snapshot
	}
	
	private struct PowerSourcesContext {
		let providingPowerSourceType: String?
		let internalBattery: [String: Any]?
	}
	
	private func readPowerSourcesContext() -> PowerSourcesContext? {
		guard
			let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
			let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
		else {
			DiagnosticLog.failureOnce("power-sources-unavailable", category: "IOKitBatteryReader", "IOPSCopyPowerSourcesInfo/List 返回空，电源信息不可用，快照降级为默认值")
			return nil
		}
		
		let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
		
		let internalBattery = list
			.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
			.first(where: isInternalBattery)
		
		return PowerSourcesContext(providingPowerSourceType: providing, internalBattery: internalBattery)
	}
	
	private func mapPowerSource(_ raw: String?) -> PowerSourceType? {
		switch raw {
		case Self.acPower: return .powerAdapter
		case Self.batteryPower: return .battery
		default: return nil
		}
	}
	
	private func isInternalBattery(_ desc: [String: Any]) -> Bool {
		if desc.string(Self.keyTransportType) == kIOPSInternalType { return true }
		return desc.string(Self.keyPSType) == kIOPSInternalBatteryType
	}
	
	private func readAdapterInfo() -> AdapterInfo? {
		guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() else { return nil }
		let dict = details as NSDictionary
		
		return AdapterInfo(
			name: dict.string("Name"),
			manufacturer: dict.string("Manufacturer")
		)
	}
	
	private func readChargerProtocolInfo(props: [String: Any]?) -> ChargerProtocolInfo? {
		guard let details = props?.dictionary("AdapterDetails") else { return nil }
		
		let familyCode = details.int64("FamilyCode").map { UInt32(truncatingIfNeeded: $0) }
		let isWireless = details.bool("IsWireless") ?? false
		
		let tiers: [PowerTier] = (details["UsbHvcMenu"] as? [[String: Any]])?.compactMap { entry in
			guard
				let voltage = entry.int("MaxVoltage"),
				let current = entry.int("MaxCurrent"),
				voltage > 0, current > 0
			else { return nil }
			return PowerTier(maxVoltageMV: voltage, maxCurrentMA: current)
		} ?? []
		
		return ChargerProtocolInfo(
			protocolName: protocolName(
				familyCode: familyCode,
				description: details.string("Description"),
				isWireless: isWireless
			),
			negotiatedVoltageMV: details.int("AdapterVoltage"),
			negotiatedCurrentMA: details.int("Current"),
			ratedWatts: details.int("Watts"),
			tiers: tiers,
			activeTierIndex: details.int("UsbHvcHvcIndex")
		)
	}
	
	private func protocolName(familyCode: UInt32?, description: String?, isWireless: Bool) -> String? {
		if isWireless { return "无线充电" }
		
		switch familyCode {
		case .some(0xE000400A): return "USB-C PD"
		case .some(0xE0004009): return "USB-C"
		case .some(0xE0004008): return "USB-C 电源"
		case .some(0xE0004000...0xE0004007): return "USB"
		case .some(0xE0024000...0xE0024FFF): return "交流电源"
		default: break
		}
		
		if let description = description?.lowercased() {
			if description.contains("pd") { return "USB-C PD" }
			if description.contains("usb") { return "USB" }
		}
		
		return nil
	}
	
	// 从适配器实际取电的总功率（供电 + 充电）
	private func readAdapterInputPowerW(props: [String: Any]?) -> Double? {
		guard let telemetry = props?.dictionary("PowerTelemetryData") else { return nil }
		guard
			let value = readPowerValueAbs(props: telemetry, key: "SystemPowerIn"),
			value >= Self.minimumVisibleWatts
		else { return nil }
		return round2(value)
	}
	
	// Temperature 单位为 0.01°C
	private func readTemperatureC(props: [String: Any]) -> Double? {
		guard let raw = props.int("Temperature"), raw > 0 else { return nil }
		let celsius = Double(raw) / 100.0
		guard (0...100).contains(celsius) else { return nil }
		return (celsius * 10).rounded() / 10
	}
	
	private func readTimeToFullChargeMinutes(internalBattery: [String: Any]?) -> Int? {
		guard
			let internalBattery,
			let minutes = internalBattery.int(Self.keyTimeToFull),
			minutes >= 0
		else { return nil }
		return minutes
	}

	private func readTimeToEmptyMinutes(internalBattery: [String: Any]?) -> Int? {
		guard
			let internalBattery,
			let minutes = internalBattery.int(Self.keyTimeToEmpty),
			minutes >= 0
		else { return nil }
		return minutes
	}
	
	private func readBatteryMetrics(
		props: [String: Any]?,
		internalBattery: [String: Any]?,
		powerSource: PowerSourceType,
		isCharging: Bool
	) -> BatteryMetrics {
		guard let props else {
			return BatteryMetrics(
				stateOfChargePercent: readStateOfCharge(internalBattery: internalBattery),
				isExternalPowerConnected: (powerSource == .powerAdapter)
			)
		}
		
		let stateOfCharge = readStateOfCharge(internalBattery: internalBattery) ?? props.int("StateOfCharge")
		let externalPowerConnected = readExternalPowerConnected(props: props, powerSource: powerSource)
		let power = readPower(
			props: props,
			context: PowerReadingContext(
				isCharging: isCharging,
				isExternalPowerConnected: externalPowerConnected,
				powerSource: powerSource
			)
		)
		
		return BatteryMetrics(
			cycleCount: props.int("CycleCount"),
			stateOfChargePercent: stateOfCharge,
			chargingPowerW: power?.charging,
			currentPowerW: power?.current,
			isExternalPowerConnected: externalPowerConnected
		)
	}
	
	private func readStateOfCharge(internalBattery: [String: Any]?) -> Int? {
		internalBattery?.int(Self.keyCurrentCapacity)
	}
	
	private func readPower(
		props: [String: Any],
		context: PowerReadingContext
	) -> (charging: Double?, current: Double?)? {
		guard
			let amperageMA = props.int64("InstantAmperage"),
			let voltageMV = props.int64("Voltage")
		else { return nil }
		
		let batteryPowerW = Double(amperageMA) * Double(voltageMV) / 1_000_000.0
		
		let chargingPowerW: Double? = {
			guard context.isCharging else { return nil }
			let value = batteryPowerW
			return value >= Self.minimumVisibleWatts ? round2(value) : nil
		}()
		
		let currentPowerW: Double? = {
			if let systemPowerW = readSystemPowerW(
				props: props,
				isExternalPowerConnected: context.isExternalPowerConnected,
				chargingPowerW: chargingPowerW
			) {
				return systemPowerW >= Self.minimumVisibleWatts ? round2(systemPowerW) : nil
			}
			
			guard context.powerSource == .battery else { return nil }
			
			let value = -batteryPowerW
			return value >= Self.minimumVisibleWatts ? round2(value) : nil
		}()
		
		return (chargingPowerW, currentPowerW)
	}
	
	private func readSystemPowerW(
		props: [String: Any],
		isExternalPowerConnected: Bool,
		chargingPowerW: Double?
	) -> Double? {
		if let value = readPowerValueAbs(props: props, key: "SystemPower"),
			value >= Self.minimumVisibleWatts { return value }
		if let value = readPowerValueAbs(props: props, key: "AvgSystemPower"),
			value >= Self.minimumVisibleWatts { return value }
		if let value = readPowerValueAbs(props: props, key: "AverageSystemPower"),
		   value >= Self.minimumVisibleWatts { return value }
		
		guard let telemetry = props.dictionary("PowerTelemetryData") else { return nil }
		
		if let value = readPowerValueAbs(props: telemetry, key: "SystemPower"), value >= Self.minimumVisibleWatts { return value }
		
		if isExternalPowerConnected, let systemPowerIn = readPowerValueAbs(props: telemetry, key: "SystemPowerIn"), systemPowerIn >= Self.minimumVisibleWatts {
			let charging = chargingPowerW ?? 0
			let withoutCharge = systemPowerIn - charging
			return withoutCharge >= Self.minimumVisibleWatts ? withoutCharge : systemPowerIn
		}
		
		return nil
	}
	
	private func readExternalPowerConnected(props: [String: Any], powerSource: PowerSourceType) -> Bool {
		if let connected = props.bool("ExternalConnected") { return connected }
		if let connected = props.bool("AppleRawExternalConnected") { return connected }
		return powerSource == .powerAdapter
	}
	
	private func readPowerValueAbs(props: [String: Any], key: String) -> Double? {
		guard let mW = props.int64(key) else { return nil }
		return Double(abs(mW)) / 1000.0
	}
	
	private func round2(_ value: Double) -> Double {
		(value * 100).rounded() / 100
	}
	
	private static func readUptimeSeconds() -> TimeInterval {
		var mib = [CTL_KERN, KERN_BOOTTIME]
		var bootTime = timeval()
		var size = MemoryLayout<timeval>.size
		guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else {
			return ProcessInfo.processInfo.systemUptime
		}
		let bootDate = Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000)
		return Date().timeIntervalSince(bootDate)
	}

	private func isFull(_ soc: Int?) -> Bool {
		guard let soc, (0...100).contains(soc) else { return false }
		return soc >= 100
	}
	
	private func readSmartBatteryProperties() -> [String: Any]? {
		let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
		guard service != 0 else {
			DiagnosticLog.failureOnce("smart-battery-service-missing", category: "IOKitBatteryReader", "未找到 AppleSmartBattery 服务，充电功率/循环次数等指标不可用")
			return nil
		}
		defer { IOObjectRelease(service) }
		
		var unmanaged: Unmanaged<CFMutableDictionary>?
		let result = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
		
		guard
			result == KERN_SUCCESS,
			let dict = unmanaged?.takeRetainedValue() as? [String: Any]
		else {
			DiagnosticLog.failureOnce("smart-battery-props-failed", category: "IOKitBatteryReader", "读取 AppleSmartBattery 属性失败（kern_return=\(result)），相关指标降级为不可用")
			return nil
		}
		
		return dict
	}
}
