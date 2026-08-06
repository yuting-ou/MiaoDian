import Foundation

// 功耗曲线的采样点
struct PowerSample: Equatable {
	let date: Date
	let watts: Double
}

// 温度曲线的采样点
struct TemperatureSample: Equatable {
	let date: Date
	let celsius: Double
}

// 掉电速度估算结果
struct DrainRateEstimate: Equatable {
	let percentPerHour: Double
	let estimatedMinutesRemaining: Int?
}

// 充电曲线采样点：相对会话开始的分钟数 + 当时电量
// 只在电量变化时记一笔，一次会话最多百来个点，体积很小
struct ChargePoint: Codable, Equatable {
	let minuteOffset: Int
	let percent: Int
}

// 一次充电会话记录
struct ChargeSession: Codable, Equatable, Identifiable {
	let startDate: Date
	var endDate: Date
	let startPercent: Int
	var endPercent: Int
	var peakInputW: Double
	// 电量随时间的曲线；旧数据没有这字段，用可选兼容解码
	var curve: [ChargePoint]? = nil
	
	var id: Date { startDate }
	
	var durationMinutes: Int {
		max(1, Int(endDate.timeIntervalSince(startDate) / 60))
	}
}

// 当天用电累计：电池模式掉了多少、充进去多少，外加插电/电池时长占比
struct DailyUsage: Codable, Equatable {
	var dayKey: String
	var drainedPercent: Int = 0
	var chargedPercent: Int = 0
	// 插电/电池供电的累计秒数，算“今天多少时间插着电”
	var acSeconds: Double = 0
	var batterySeconds: Double = 0
	
	// 插电时长占比；样本不足半小时不给结论，免得刚开机就下定论
	var acShare: Double? {
		let total = acSeconds + batterySeconds
		guard total >= 30 * 60 else { return nil }
		return acSeconds / total
	}
	
	enum CodingKeys: String, CodingKey {
		case dayKey, drainedPercent, chargedPercent, acSeconds, batterySeconds
	}
	
	init(dayKey: String, drainedPercent: Int = 0, chargedPercent: Int = 0, acSeconds: Double = 0, batterySeconds: Double = 0) {
		self.dayKey = dayKey
		self.drainedPercent = drainedPercent
		self.chargedPercent = chargedPercent
		self.acSeconds = acSeconds
		self.batterySeconds = batterySeconds
	}
	
	// 旧存档没有时长字段，缺省 0 兼容解码
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.dayKey = try container.decode(String.self, forKey: .dayKey)
		self.drainedPercent = try container.decodeIfPresent(Int.self, forKey: .drainedPercent) ?? 0
		self.chargedPercent = try container.decodeIfPresent(Int.self, forKey: .chargedPercent) ?? 0
		self.acSeconds = try container.decodeIfPresent(Double.self, forKey: .acSeconds) ?? 0
		self.batterySeconds = try container.decodeIfPresent(Double.self, forKey: .batterySeconds) ?? 0
	}
}

// 每日健康度采样
struct HealthSample: Codable, Equatable {
	let date: Date
	let healthPercent: Int
	let cycleCount: Int?
}

// 24 小时电量曲线的采样点
struct SOCSample: Codable, Equatable {
	let date: Date
	let percent: Int
	let isCharging: Bool
}

// 电源事件：插拔电、充满、睡眠/唤醒的时间线记录
nonisolated enum PowerEventKind: String, Codable, Sendable {
	case pluggedIn
	case unplugged
	case chargedFull
	case sleep
	case wake
}

struct PowerEvent: Codable, Equatable, Identifiable {
	let date: Date
	let kind: PowerEventKind
	
	var id: Date { date }
}

// 一次合盖睡眠的掉电记录
struct SleepDrainRecord: Codable, Equatable {
	let sleepDate: Date
	let wakeDate: Date
	let startPercent: Int
	let endPercent: Int
	
	var durationMinutes: Int {
		max(1, Int(wakeDate.timeIntervalSince(sleepDate) / 60))
	}
	
	var droppedPercent: Int { startPercent - endPercent }
	
	// 折算成每小时掉电，方便跟白天使用对比
	var dropPerHour: Double {
		Double(droppedPercent) / (Double(durationMinutes) / 60)
	}
}

// 充电器档案：记住见过的充电器，插上时能认出老朋友还是新面孔
struct ChargerProfile: Codable, Equatable {
	let key: String
	var name: String
	var ratedWatts: Int?
	let firstSeen: Date
	var lastSeen: Date
	var connectCount: Int
}

// 蓝牙外设类型（来自系统蓝牙报告的 minorType，名字关键词兜底）
nonisolated enum BluetoothDeviceKind: String, Equatable, Sendable {
	case mouse
	case keyboard
	case trackpad
	case headphones
	case speaker
	case gamepad
	case phone
	case other
}

// 蓝牙外设电量
nonisolated struct BluetoothDeviceBattery: Equatable, Identifiable, Sendable {
	let name: String
	let percent: Int
	var kind: BluetoothDeviceKind = .other
	
	var id: String { name }
}
