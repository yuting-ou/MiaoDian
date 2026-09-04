import Foundation

// 功耗曲线的采样点
nonisolated struct PowerSample: Equatable, Sendable {
	let date: Date
	let watts: Double
}

// 电量跳变事件：电池模式下相邻两次采样电量突变 ≥2%（如 95% 直接跳 97%），
// 是电量计（Gas Gauge）失准的典型表现；攒多了提示做一次完整充放循环校准
nonisolated struct SocJumpEvent: Codable, Equatable, Sendable, Identifiable {
	let date: Date
	let fromPercent: Int
	let toPercent: Int

	var id: Date { date }
}

// 温度曲线的采样点
nonisolated struct TemperatureSample: Equatable, Sendable {
	let date: Date
	let celsius: Double
}

// 掉电速度估算结果
nonisolated struct DrainRateEstimate: Equatable, Sendable {
	let percentPerHour: Double
	let estimatedMinutesRemaining: Int?
}

// 充电曲线采样点：相对会话开始的分钟数 + 当时电量
// 只在电量变化时记一笔，一次会话最多百来个点，体积很小
nonisolated struct ChargePoint: Codable, Equatable, Sendable {
	let minuteOffset: Int
	let percent: Int
}

// 一次充电会话记录
nonisolated struct ChargeSession: Codable, Equatable, Identifiable, Sendable {
	let startDate: Date
	var endDate: Date
	let startPercent: Int
	var endPercent: Int
	var peakInputW: Double
	// 电量随时间的曲线；旧数据没有这字段，用可选兼容解码
	var curve: [ChargePoint]? = nil
	// 这次充电用的充电器身份键（旧档无此字段，解码为 nil）
	var chargerKey: String? = nil

	var id: Date { startDate }

	var durationMinutes: Int {
		max(1, Int(endDate.timeIntervalSince(startDate) / 60))
	}
}

// 当天用电累计：电池模式掉了多少、充进去多少，外加插电/电池时长占比
nonisolated struct DailyUsage: Codable, Equatable, Sendable {
	var dayKey: String
	var drainedPercent: Int = 0
	var chargedPercent: Int = 0
	// 插电/电池供电的累计秒数，算”今天多少时间插着电”
	var acSeconds: Double = 0
	var batterySeconds: Double = 0
	// 高电量驻留秒数（80–90% 与 90%+ 两档）：电化学应力的直接度量
	var soc80to90Seconds: Double = 0
	var soc90to100Seconds: Double = 0

	// 插电时长占比；样本不足半小时不给结论，免得刚开机就下定论
	var acShare: Double? {
		let total = acSeconds + batterySeconds
		guard total >= 30 * 60 else { return nil }
		return acSeconds / total
	}

	// 高电量（80%+）驻留分钟数；与 acShare 同一采样量门槛
	var dwell80PlusMinutes: Int? {
		guard acShare != nil else { return nil }
		return Int((soc80to90Seconds + soc90to100Seconds) / 60)
	}

	// 高电量驻留占通电总时长的比例（0~1）；样本不足半小时不给结论
	var highSocDwellShare: Double? {
		let total = acSeconds + batterySeconds
		guard total >= 30 * 60 else { return nil }
		return (soc80to90Seconds + soc90to100Seconds) / total
	}

	enum CodingKeys: String, CodingKey {
		case dayKey, drainedPercent, chargedPercent, acSeconds, batterySeconds
		case soc80to90Seconds, soc90to100Seconds
	}

	init(dayKey: String, drainedPercent: Int = 0, chargedPercent: Int = 0, acSeconds: Double = 0, batterySeconds: Double = 0,
		 soc80to90Seconds: Double = 0, soc90to100Seconds: Double = 0) {
		self.dayKey = dayKey
		self.drainedPercent = drainedPercent
		self.chargedPercent = chargedPercent
		self.acSeconds = acSeconds
		self.batterySeconds = batterySeconds
		self.soc80to90Seconds = soc80to90Seconds
		self.soc90to100Seconds = soc90to100Seconds
	}

	// 旧存档没有时长/驻留字段，缺省 0 兼容解码
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.dayKey = try container.decodeIfPresent(String.self, forKey: .dayKey) ?? ""
		self.drainedPercent = try container.decodeIfPresent(Int.self, forKey: .drainedPercent) ?? 0
		self.chargedPercent = try container.decodeIfPresent(Int.self, forKey: .chargedPercent) ?? 0
		self.acSeconds = try container.decodeIfPresent(Double.self, forKey: .acSeconds) ?? 0
		self.batterySeconds = try container.decodeIfPresent(Double.self, forKey: .batterySeconds) ?? 0
		self.soc80to90Seconds = try container.decodeIfPresent(Double.self, forKey: .soc80to90Seconds) ?? 0
		self.soc90to100Seconds = try container.decodeIfPresent(Double.self, forKey: .soc90to100Seconds) ?? 0
	}
}

// 每日健康度采样
nonisolated struct HealthSample: Codable, Equatable, Sendable {
	let date: Date
	let healthPercent: Int
	let cycleCount: Int?
}

// 24 小时电量曲线的采样点
nonisolated struct SOCSample: Codable, Equatable, Sendable {
	let date: Date
	let percent: Int
	let isCharging: Bool
}

// 电源事件：插拔电、充满、睡眠/唤醒、电池更换的时间线记录
nonisolated enum PowerEventKind: String, Codable, Sendable {
	case pluggedIn
	case unplugged
	case chargedFull
	case sleep
	case wake
	case batteryReplaced
}

nonisolated struct PowerEvent: Codable, Equatable, Identifiable, Sendable {
	let date: Date
	let kind: PowerEventKind
	
	var id: Date { date }
}

// 一次合盖睡眠的掉电记录
nonisolated struct SleepDrainRecord: Codable, Equatable, Sendable {
	let sleepDate: Date
	let wakeDate: Date
	let startPercent: Int
	let endPercent: Int
	// 醒来时正在持有"阻止系统睡眠"断言的进程名（旧档无此字段）
	var culpritNames: [String]? = nil
	
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
// 系统只认得苹果原厂头——第三方氮化镓大多只报额定瓦数，
// 所以允许用户给认不出的头自己起名字（customName），下游功能立刻说人话
nonisolated struct ChargerProfile: Codable, Equatable, Sendable {
	let key: String
	var name: String
	var ratedWatts: Int?
	let firstSeen: Date
	var lastSeen: Date
	var connectCount: Int
	// 用户起的名字；系统识别不了时由用户认领，优先于 name 展示
	var customName: String?
	// PD 源功率档位签名（展示用）：两只同瓦数的不同充电器靠它辨认
	var tierSignature: String?

	// 展示名：用户命名 > 系统识别名 > 额定瓦数兜底
	var displayName: String {
		if let customName, !customName.isEmpty { return customName }
		if !name.isEmpty { return name }
		if let ratedWatts, ratedWatts > 0 { return "\(ratedWatts)W 充电器" }
		return "充电器"
	}
}

// 充电器/线材质量诊断：按充电器累计多次充电的协商功率，识别"协商功率长期低于额定"的劣质线/口
nonisolated struct ChargerPowerStats: Codable, Equatable, Sendable {
	let key: String
	var ratedWatts: Int?
	var sampleCount: Int = 0
	var sumWatts: Double = 0
	var maxWatts: Double = 0

	// 平均协商功率；无样本时为 nil
	var avgWatts: Double? {
		sampleCount > 0 ? sumWatts / Double(sampleCount) : nil
	}

	// 协商平均显著低于额定（<60%）且样本足够 → 疑似线材/接口质量不佳
	var isSuspiciouslySlow: Bool {
		guard sampleCount >= 5, let rated = ratedWatts, rated > 0, let avg = avgWatts else { return false }
		return avg < Double(rated) * 0.6
	}
}

// 时段用电累计：按一天 24 小时分桶累计电池模式的掉电，看哪个时段用电最凶
nonisolated struct HourlyDrainStats: Codable, Equatable, Sendable {
	// 每小时桶累计掉的百分点（下标 0~23）
	var drainedByHour: [Double]
	// 有效累计天数（跨天时 +1，用于摊平成"日均"）
	var accumulatedDays: Int
	// 最近一次累计所在的日期键（跨天判定用）
	var lastDayKey: String

	init() {
		self.drainedByHour = Array(repeating: 0, count: 24)
		self.accumulatedDays = 0
		self.lastDayKey = ""
	}

	// 归一化桶（防越界）
	func bucket(_ hour: Int) -> Int {
		min(max(hour, 0), 23)
	}
}

// 时段温度画像：每小时的历史最高电池温度（°C）。
// 热暴露看峰值（均值会把午后高温摊平），与时段用电热力图对照，
// 回答"用电高峰是不是也叠着一天里电池最热的时段"
nonisolated struct HourlyTempStats: Codable, Equatable, Sendable {
	// 每小时历史最高温（下标 0~23）；0 = 该小时尚无数据
	var maxTempByHour: [Double]
	// 有效累计天数（跨天 +1，样本不足不下结论）
	var accumulatedDays: Int
	// 最近一次累计所在的日期键
	var lastDayKey: String

	init() {
		self.maxTempByHour = Array(repeating: 0, count: 24)
		self.accumulatedDays = 0
		self.lastDayKey = ""
	}

	func bucket(_ hour: Int) -> Int {
		min(max(hour, 0), 23)
	}
}

// 应用耗电累计：按天记录每个应用处于"高耗电"状态的秒数，回答"到底谁最费电"
nonisolated struct AppEnergyUsage: Codable, Equatable, Sendable, Identifiable {
	let bundleId: String
	var name: String
	// dayKey -> 当天累计秒数（只保留最近 30 天）
	var secondsByDay: [String: Double]
	var lastSeen: Date
	// 24 小时活跃分布（秒）：1.6.0 起新增，旧档无此字段为 nil。
	// 长期滚动累积——用电习惯本就稳定，回答"这应用一般几点在费电"
	var secondsByHour: [Double]?

	var id: String { bundleId }

	// 指定日期集合内的累计秒数（如最近 7 天）
	func seconds(within dayKeys: Set<String>) -> Double {
		dayKeys.reduce(0) { $0 + (secondsByDay[$1] ?? 0) }
	}
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
