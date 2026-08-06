import Foundation

enum DisplayOption: String, CaseIterable, Identifiable, Codable {
	// 电源信息
	case adapterManufacturer
	case adapterName
	case chargerProfile
	case chargingProtocol
	case powerTiers
	case inputWatts
	case chargingWatts
	case currentWatts
	// 电池信息
	case cycleCount
	case batteryHealth
	case batteryCheckup
	case batteryTemperature
	case batteryCurrentVoltage
	case uptime
	case timeRemaining
	case drainRate
	case sleepDrainReport
	case significantEnergyApps
	case bluetoothDevices
	// 图表卡片
	case powerChart
	case temperatureChart
	case socChart
	case usageCalendar
	case healthTrend
	case dailySummary
	case chargeHistory
	case powerEvents
	case habitInsight
	// 提醒通知（alerts 是总开关，其余是细分开关）
	case alerts
	case alertFull
	case alertLowBattery
	case alertLowForecast
	case alertFullForecast
	case alertHighTemperature
	case alertTempSurge
	case alertSlowCharge
	case alertHighDrain
	case alertDeviceLow
	case alertHealthMilestone
	case chargeCareReminder
	case weeklyDigest
	case quietHours
	// 通用
	case startAtLogin
	case preventSleeping
	
	var id: String { rawValue }
	
	var title: String {
		switch self {
		case .adapterManufacturer: return "制造商"
		case .adapterName: return "适配器名称"
		case .chargerProfile: return "充电器档案"
		case .chargingProtocol: return "充电协议"
		case .powerTiers: return "功率档位"
		case .inputWatts: return "输入功率"
		case .chargingWatts: return "充电功率"
		case .currentWatts: return "当前功耗"
		case .cycleCount: return "循环次数"
		case .batteryHealth: return "电池健康"
		case .batteryCheckup: return "电池体检评分"
		case .batteryTemperature: return "电池温度"
		case .batteryCurrentVoltage: return "电流电压"
		case .uptime: return "开机时长"
		case .timeRemaining: return "剩余可用时间"
		case .drainRate: return "掉电分析"
		case .sleepDrainReport: return "睡眠掉电"
		case .significantEnergyApps: return "高耗电应用"
		case .bluetoothDevices: return "外设电量"
		case .powerChart: return "功耗曲线"
		case .temperatureChart: return "温度曲线"
		case .socChart: return "24小时电量曲线"
		case .usageCalendar: return "用电日历"
		case .healthTrend: return "健康趋势"
		case .dailySummary: return "今日小结"
		case .chargeHistory: return "充电记录"
		case .powerEvents: return "电源事件"
		case .habitInsight: return "充电习惯建议"
		case .alerts: return "启用提醒通知"
		case .alertFull: return "充满提醒"
		case .alertLowBattery: return "低电量提醒"
		case .alertLowForecast: return "低电量预判"
		case .alertFullForecast: return "充满时间预告"
		case .alertHighTemperature: return "高温提醒"
		case .alertTempSurge: return "温度骤升预警"
		case .alertSlowCharge: return "慢充提醒"
		case .alertHighDrain: return "耗电异常提醒"
		case .alertDeviceLow: return "外设低电提醒"
		case .alertHealthMilestone: return "健康度里程碑"
		case .chargeCareReminder: return "充到 80% 提醒拔电"
		case .weeklyDigest: return "每周电池周报"
		case .quietHours: return "夜间免打扰（23点–8点）"
		case .startAtLogin: return "登录时启动"
		case .preventSleeping: return "防止睡眠"
		}
	}
	
	// 偏好设置里按组收进子菜单，30 多个开关平铺早就没法看了
	enum Group: CaseIterable {
		case power
		case battery
		case charts
		case alerts
		case general
		
		var title: String {
			switch self {
			case .power: return "电源信息"
			case .battery: return "电池信息"
			case .charts: return "图表卡片"
			case .alerts: return "提醒通知"
			case .general: return "通用"
			}
		}
		
		var symbol: String {
			switch self {
			case .power: return "powerplug"
			case .battery: return "battery.75percent"
			case .charts: return "chart.xyaxis.line"
			case .alerts: return "bell"
			case .general: return "switch.2"
			}
		}
	}
	
	var group: Group {
		switch self {
		case .adapterManufacturer, .adapterName, .chargerProfile, .chargingProtocol,
			.powerTiers, .inputWatts, .chargingWatts, .currentWatts:
			return .power
		case .cycleCount, .batteryHealth, .batteryCheckup, .batteryTemperature, .batteryCurrentVoltage,
			.uptime, .timeRemaining, .drainRate, .sleepDrainReport, .significantEnergyApps, .bluetoothDevices:
			return .battery
		case .powerChart, .temperatureChart, .socChart, .usageCalendar, .healthTrend, .dailySummary, .chargeHistory, .powerEvents, .habitInsight:
			return .charts
		case .alerts, .alertFull, .alertLowBattery, .alertLowForecast, .alertFullForecast,
			.alertHighTemperature, .alertTempSurge, .alertSlowCharge, .alertHighDrain,
			.alertDeviceLow, .alertHealthMilestone, .chargeCareReminder, .weeklyDigest, .quietHours:
			return .alerts
		case .startAtLogin, .preventSleeping:
			return .general
		}
	}
}

// 菜单栏显示内容
enum MenuBarContent: String, CaseIterable, Identifiable, Codable {
	case percent
	case icon
	case iconAndPercent
	case temperature
	case power
	case remainingTime
	case rotating
	case sparkline
	
	var id: String { rawValue }
	
	var title: String {
		switch self {
		case .percent: return "电量百分比"
		case .icon: return "电池图标"
		case .iconAndPercent: return "图标 + 电量"
		case .temperature: return "电池温度"
		case .power: return "当前功耗"
		case .remainingTime: return "剩余时间"
		case .rotating: return "轮换显示"
		case .sparkline: return "电量走势图"
		}
	}
}
