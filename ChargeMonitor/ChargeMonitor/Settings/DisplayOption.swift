import Foundation

nonisolated enum DisplayOption: String, CaseIterable, Identifiable, Codable, Sendable {
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
	case batteryIdentity
	case batteryCheckup
	case batteryTemperature
	case batteryCurrentVoltage
	case uptime
	case timeRemaining
	case drainRate
	case runtimeScenarios
	case sleepDrainReport
	case significantEnergyApps
	case bluetoothDevices
	// 图表卡片
	case powerChart
	case temperatureChart
	case socChart
	case hourlyDrainChart
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
	case alertGaugeCalibration
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
		case .batteryIdentity: return "电池身份证"
		case .batteryCheckup: return "电池体检评分"
		case .batteryTemperature: return "电池温度"
		case .batteryCurrentVoltage: return "电流电压"
		case .uptime: return "开机时长"
		case .timeRemaining: return "剩余可用时间"
		case .drainRate: return "掉电分析"
		case .runtimeScenarios: return "续航换算"
		case .sleepDrainReport: return "睡眠掉电"
		case .significantEnergyApps: return "高耗电应用"
		case .bluetoothDevices: return "外设电量"
		case .powerChart: return "功耗曲线"
		case .temperatureChart: return "温度曲线"
		case .socChart: return "24小时电量曲线"
		case .hourlyDrainChart: return "时段用电热力图"
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
		case .alertGaugeCalibration: return "电量计校准提醒"
		case .alertDeviceLow: return "外设低电提醒"
		case .alertHealthMilestone: return "健康度里程碑"
		case .chargeCareReminder: return "充电到保养线提醒拔电"
		case .weeklyDigest: return "每周电池周报"
		case .quietHours: return "夜间免打扰"
		case .startAtLogin: return "登录时启动"
		case .preventSleeping: return "防止睡眠"
		}
	}

	// 设置窗口每个开关下面的一句说明，同时也是搜索的匹配字段
	var detail: String {
		switch self {
		case .adapterManufacturer: return "充电器芯片厂商，如 Apple、Anker"
		case .adapterName: return "系统读到的适配器名称"
		case .chargerProfile: return "记住见过的充电器，第一次见会标注"
		case .chargingProtocol: return "USB-C PD / USB 等快充协议识别"
		case .powerTiers: return "当前协商的电压电流档位与可选档位"
		case .inputWatts: return "从适配器取电的总功率（供电 + 充电）"
		case .chargingWatts: return "电池端实际充电功率"
		case .currentWatts: return "整机实时功耗"
		case .cycleCount: return "电池充放循环次数（标称寿命 1000 次）"
		case .batteryHealth: return "当前满充容量相对出厂设计的百分比"
		case .batteryIdentity: return "序列号、电芯厂商、生产日期等出厂信息"
		case .batteryCheckup: return "健康度、循环、温度与高电量驻留的加权评分"
		case .batteryTemperature: return "电池电芯温度"
		case .batteryCurrentVoltage: return "电池端实时电压与电流（正充负放）"
		case .uptime: return "本次开机时长"
		case .timeRemaining: return "按系统估算的剩余可用时间"
		case .drainRate: return "按最近一小时真实放电算出的掉电速度"
		case .runtimeScenarios: return "轻度/视频/会议三种场景还能用多久"
		case .sleepDrainReport: return "合盖睡眠期间掉了多少电"
		case .significantEnergyApps: return "当前耗电大户与本周累计排行"
		case .bluetoothDevices: return "蓝牙耳机、鼠标、键盘等外设电量"
		case .powerChart: return "最近 5 分钟整机功耗迷你曲线"
		case .temperatureChart: return "最近 30 分钟电池温度曲线"
		case .socChart: return "最近 24 小时电量走势，充电段绿色"
		case .hourlyDrainChart: return "一天 24 小时的用电强度热力图"
		case .usageCalendar: return "按天展示用电强度的日历格子"
		case .healthTrend: return "每天一个健康度采样，看老化趋势"
		case .dailySummary: return "今天用电、充入与充电次数小结"
		case .chargeHistory: return "最近几次充电记录，点开看曲线"
		case .powerEvents: return "插拔电、充满、睡眠唤醒时间线"
		case .habitInsight: return "根据用电习惯给一句保养建议"
		case .alerts: return "总开关：关闭后所有提醒都不再发送"
		case .alertFull: return "充满 100% 时提醒"
		case .alertLowBattery: return "电量低于警示线时提醒（紧急）"
		case .alertLowForecast: return "按当前掉速预估快到警示线时提前提醒"
		case .alertFullForecast: return "插上电源时预告几点能充满"
		case .alertHighTemperature: return "电池温度超过警示线时提醒"
		case .alertTempSurge: return "短时间内温度快速上升时提醒"
		case .alertSlowCharge: return "协商功率明显低于充电器额定值时提醒"
		case .alertHighDrain: return "掉电速度异常偏快时提醒并点名应用"
		case .alertGaugeCalibration: return "电量跳变频发时建议校准电量计"
		case .alertDeviceLow: return "外设电量低于警示线时提醒"
		case .alertHealthMilestone: return "健康度跌破 90/85/80% 时各提醒一次"
		case .chargeCareReminder: return "充电到保养线时提醒拔掉电源"
		case .weeklyDigest: return "每周日晚 / 每月 1 号发送电池小结"
		case .quietHours: return "设定时段内非紧急通知静音"
		case .startAtLogin: return "登录 macOS 时自动启动妙电"
		case .preventSleeping: return "阻止系统与显示器进入睡眠（演示/下载时用）"
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
		case .cycleCount, .batteryHealth, .batteryIdentity, .batteryCheckup, .batteryTemperature, .batteryCurrentVoltage,
			.uptime, .timeRemaining, .drainRate, .runtimeScenarios, .sleepDrainReport, .significantEnergyApps, .bluetoothDevices:
			return .battery
		case .powerChart, .temperatureChart, .socChart, .hourlyDrainChart, .usageCalendar, .healthTrend, .dailySummary, .chargeHistory, .powerEvents, .habitInsight:
			return .charts
		case .alerts, .alertFull, .alertLowBattery, .alertLowForecast, .alertFullForecast,
			.alertHighTemperature, .alertTempSurge, .alertSlowCharge, .alertHighDrain, .alertGaugeCalibration,
			.alertDeviceLow, .alertHealthMilestone, .chargeCareReminder, .weeklyDigest, .quietHours:
			return .alerts
		case .startAtLogin, .preventSleeping:
			return .general
		}
	}
}

// 菜单栏显示内容
nonisolated enum MenuBarContent: String, CaseIterable, Identifiable, Codable, Sendable {
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
