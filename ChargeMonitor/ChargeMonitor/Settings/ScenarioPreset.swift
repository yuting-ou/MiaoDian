import Foundation

/// 充电场景模式预设（核心功能优化计划 C1）。
/// 裁决：模式＝配置预设——保养线 + 提醒开关 + 免打扰的组合；
/// 控制层已由 D1 裁决永久取消，本枚举不做任何充电干预，只做配置映射。
/// 全部为 nonisolated 纯函数，测试/main.swift 直接对真代码断言。
nonisolated enum ScenarioPreset: String, CaseIterable, Identifiable, Sendable {
	case office
	case travel
	case storage
	case fastCharge

	var id: String { rawValue }

	var title: String {
		switch self {
		case .office: return "办公"
		case .travel: return "外出满充"
		case .storage: return "长期存放"
		case .fastCharge: return "快充"
		}
	}

	var detail: String {
		switch self {
		case .office: return "保养线 80%·到线提醒拔电·夜间免打扰"
		case .travel: return "保养线 90%·低电警示提前到 25%·全天候提醒"
		case .storage: return "保养线 70%·夜间免打扰·适合长期插电存放"
		case .fastCharge: return "保养线 90%·免打扰关闭，到线即提醒"
		}
	}

	/// 把预设映射到配置。只组合三类参数：保养线、提醒开关、免打扰；
	/// 其余字段（菜单栏显示、卡片、其他提醒）原样保留，不替用户做主。
	func applied(to config: AppConfiguration) -> AppConfiguration {
		var copy = config
		switch self {
		case .office:
			copy.chargeCareThresholdPercent = 80
			copy.lowBatteryThresholdPercent = 20
			copy.enabledOptions.insert(.chargeCareReminder)
			copy.enabledOptions.insert(.quietHours)
			copy.quietHoursStartHour = 23
			copy.quietHoursEndHour = 8
		case .travel:
			copy.chargeCareThresholdPercent = 90
			copy.lowBatteryThresholdPercent = 25
			copy.enabledOptions.insert(.chargeCareReminder)
			copy.enabledOptions.remove(.quietHours)
		case .storage:
			copy.chargeCareThresholdPercent = 70
			copy.lowBatteryThresholdPercent = 20
			copy.enabledOptions.insert(.chargeCareReminder)
			copy.enabledOptions.insert(.quietHours)
			copy.quietHoursStartHour = 23
			copy.quietHoursEndHour = 8
		case .fastCharge:
			copy.chargeCareThresholdPercent = 90
			copy.lowBatteryThresholdPercent = 20
			copy.enabledOptions.insert(.chargeCareReminder)
			copy.enabledOptions.remove(.quietHours)
		}
		return copy
	}

	/// 四档在「保养线/低电阈值/保养提醒/免打扰(+时段)」上两两互不相同，
	/// 因此当前配置最多命中一档；手动调过参数即脱离预设。
	func matches(_ config: AppConfiguration) -> Bool {
		let careOn = config.enabledOptions.contains(.chargeCareReminder)
		let quietOn = config.enabledOptions.contains(.quietHours)
		switch self {
		case .office:
			return config.chargeCareThresholdPercent == 80
				&& config.lowBatteryThresholdPercent == 20
				&& careOn && quietOn
				&& config.quietHoursStartHour == 23 && config.quietHoursEndHour == 8
		case .travel:
			return config.chargeCareThresholdPercent == 90
				&& config.lowBatteryThresholdPercent == 25
				&& careOn && !quietOn
		case .storage:
			return config.chargeCareThresholdPercent == 70
				&& config.lowBatteryThresholdPercent == 20
				&& careOn && quietOn
				&& config.quietHoursStartHour == 23 && config.quietHoursEndHour == 8
		case .fastCharge:
			return config.chargeCareThresholdPercent == 90
				&& config.lowBatteryThresholdPercent == 20
				&& careOn && !quietOn
		}
	}

	/// 反查当前配置命中哪一档；都不命中＝用户已手动调整（自定义）。
	/// 面板与设置页的回显都从这里取值，防止「预设切换静默失败」后界面谎报模式。
	nonisolated static func matched(in config: AppConfiguration) -> ScenarioPreset? {
		allCases.first { $0.matches(config) }
	}
}
