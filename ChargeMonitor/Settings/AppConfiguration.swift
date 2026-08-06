import Foundation

struct AppConfiguration: Codable, Equatable {
	var enabledOptions: Set<DisplayOption> = Self.defaultEnabledOptions
	var knownOptions: Set<DisplayOption> = Set(DisplayOption.allCases)
	var menuBarContent: MenuBarContent = .percent
	// 提醒阈值可调：低电量警示（菜单栏变红/面板徽章/通知）与高温警示共用
	var lowBatteryThresholdPercent: Int = 20
	var highTemperatureThresholdC: Int = 40
	// 保养提醒、外设低电、耗电异常的阈值也开放自定义
	var chargeCareThresholdPercent: Int = 80
	var deviceLowThresholdPercent: Int = 20
	var highDrainThresholdPerHour: Int = 20
	// 被用户折叠起来的图表卡片（存 DisplayOption rawValue）
	var collapsedCards: Set<String> = []
	
	static let `default` = AppConfiguration()
	
	private static var defaultEnabledOptions: Set<DisplayOption> {
		// 保养提醒默认关：不是每个人都想充到 80% 就拔线；免打扰默认关，让用户自己选
		Set(DisplayOption.allCases).subtracting([.startAtLogin, .preventSleeping, .chargeCareReminder, .quietHours])
	}
	
	// 旧版配置里不存在的选项，用于迁移时按默认值开启一次
	private static var legacyKnownOptions: Set<DisplayOption> {
		Set(DisplayOption.allCases).subtracting([
			.chargingProtocol, .powerTiers, .inputWatts,
			.batteryHealth, .batteryTemperature, .alerts,
			.powerChart, .drainRate, .bluetoothDevices, .healthTrend, .chargeHistory,
			.dailySummary, .chargeCareReminder, .temperatureChart,
			.sleepDrainReport, .weeklyDigest, .chargerProfile,
			.batteryCheckup, .batteryCurrentVoltage, .socChart, .powerEvents,
			.alertFull, .alertLowBattery, .alertLowForecast, .alertFullForecast,
			.alertHighTemperature, .alertTempSurge, .alertSlowCharge,
			.alertHighDrain, .alertDeviceLow, .alertHealthMilestone, .quietHours,
			.usageCalendar, .habitInsight
		])
	}
	
	init() {}
	
	func normalized() -> AppConfiguration {
		var copy = self
		let newOptions = Set(DisplayOption.allCases).subtracting(copy.knownOptions)
		copy.enabledOptions.formUnion(newOptions.intersection(Self.defaultEnabledOptions))
		copy.knownOptions = Set(DisplayOption.allCases)
		copy.enabledOptions = copy.enabledOptions.intersection(Set(DisplayOption.allCases))
		// 阈值夹到合理区间，防止手改配置文件写出离谱值
		copy.lowBatteryThresholdPercent = min(max(copy.lowBatteryThresholdPercent, 5), 50)
		copy.highTemperatureThresholdC = min(max(copy.highTemperatureThresholdC, 35), 50)
		copy.chargeCareThresholdPercent = min(max(copy.chargeCareThresholdPercent, 60), 95)
		copy.deviceLowThresholdPercent = min(max(copy.deviceLowThresholdPercent, 5), 40)
		copy.highDrainThresholdPerHour = min(max(copy.highDrainThresholdPerHour, 10), 40)
		// 折叠状态只保留仍然存在的卡片选项
		let validCardIDs = Set(DisplayOption.allCases.map(\.rawValue))
		copy.collapsedCards = copy.collapsedCards.intersection(validCardIDs)
		return copy
	}
	
	enum CodingKeys: String, CodingKey {
		case enabledOptions
		case knownOptions
		case menuBarContent
		case lowBatteryThresholdPercent
		case highTemperatureThresholdC
		case chargeCareThresholdPercent
		case deviceLowThresholdPercent
		case highDrainThresholdPerHour
		case collapsedCards
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.enabledOptions = try container.decodeIfPresent(
			Set<DisplayOption>.self,
			forKey: .enabledOptions
		) ?? Self.defaultEnabledOptions
		self.knownOptions = try container.decodeIfPresent(
			Set<DisplayOption>.self,
			forKey: .knownOptions
		) ?? Self.legacyKnownOptions
		self.menuBarContent = try container.decodeIfPresent(
			MenuBarContent.self,
			forKey: .menuBarContent
		) ?? .percent
		self.lowBatteryThresholdPercent = try container.decodeIfPresent(
			Int.self,
			forKey: .lowBatteryThresholdPercent
		) ?? 20
		self.highTemperatureThresholdC = try container.decodeIfPresent(
			Int.self,
			forKey: .highTemperatureThresholdC
		) ?? 40
		self.chargeCareThresholdPercent = try container.decodeIfPresent(
			Int.self,
			forKey: .chargeCareThresholdPercent
		) ?? 80
		self.deviceLowThresholdPercent = try container.decodeIfPresent(
			Int.self,
			forKey: .deviceLowThresholdPercent
		) ?? 20
		self.highDrainThresholdPerHour = try container.decodeIfPresent(
			Int.self,
			forKey: .highDrainThresholdPerHour
		) ?? 20
		self.collapsedCards = try container.decodeIfPresent(
			Set<String>.self,
			forKey: .collapsedCards
		) ?? []
	}
}
