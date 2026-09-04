import Foundation

// 生成纯文本电池报告：当前状态 + 体检评分 + 电池档案 + 健康趋势 + 七天用电 + 充电记录 +
// 充电器档案 + 睡眠掉电 + 电源事件 + 外设电量，与面板信息保持一致
struct BatteryReportBuilder {
	let snapshot: BatterySnapshot
	let configuration: AppConfiguration
	let drainEstimate: DrainRateEstimate?
	let healthSamples: [HealthSample]
	let sessions: [ChargeSession]
	let bluetoothDevices: [BluetoothDeviceBattery]
	// 以下为新增数据源，默认空值保证旧调用方不报错
	var dailyHistory: [DailyUsage] = []
	var chargerProfiles: [ChargerProfile] = []
	var lastSleepDrain: SleepDrainRecord? = nil
	var powerEvents: [PowerEvent] = []
	var identity: BatteryIdentity? = nil
	var socJumpCount30d: Int = 0

	func build() -> String {
		var sections: [String] = []

		sections.append("妙电 · 电池报告")
		sections.append("生成时间：\(Self.dateTimeFormatter.string(from: Date()))")
		sections.append("")

		sections.append("【当前状态】")
		sections.append(contentsOf: currentStatusLines())

		if let checkupLine {
			sections.append("")
			sections.append("【电池体检】")
			sections.append(checkupLine)
		}

		// 电池档案：出厂静态信息 + 电量计跳变状态
		if let identity, let lines = identityLines(identity), !lines.isEmpty {
			sections.append("")
			sections.append("【电池档案】")
			sections.append(contentsOf: lines)
		}
		
		if let charger = chargerProfiles.first(where: { $0.key == currentChargerKey }) {
			sections.append("")
			sections.append("【当前充电器】")
			var line = charger.displayName
			if let watts = charger.ratedWatts, watts > 0 { line += "  \(watts)W" }
			line += "  已见 \(charger.connectCount) 次"
			sections.append(line)
		}
		
		if let sleepLine {
			sections.append("")
			sections.append("【上次睡眠掉电】")
			sections.append(sleepLine)
		}
		
		if !dailyHistory.isEmpty {
			sections.append("")
			sections.append("【最近用电】")
			for day in dailyHistory.reversed() {
				var line = "\(day.dayKey)  用电 \(day.drainedPercent)%  充入 \(day.chargedPercent)%"
				if let share = day.acShare {
					line += String(format: "  插电占比 %.0f%%", share * 100)
				}
				sections.append(line)
			}
		}
		
		if !healthSamples.isEmpty {
			sections.append("")
			sections.append("【健康度记录】")
			for sample in healthSamples.suffix(30) {
				var line = "\(Self.dateFormatter.string(from: sample.date))  健康 \(sample.healthPercent)%"
				if let cycles = sample.cycleCount {
					line += "  循环 \(cycles) 次"
				}
				sections.append(line)
			}
		}
		
		if !sessions.isEmpty {
			sections.append("")
			sections.append("【充电记录】")
			for session in sessions.reversed() {
				var line = "\(Self.dateTimeFormatter.string(from: session.startDate))  \(session.startPercent)% → \(session.endPercent)%  用时 \(session.durationMinutes) 分钟"
				if session.peakInputW >= 1 {
					line += String(format: "  峰值 %.0fW", session.peakInputW)
				}
				sections.append(line)
			}
		}
		
		if !powerEvents.isEmpty {
			sections.append("")
			sections.append("【电源事件】")
			for event in powerEvents.suffix(10).reversed() {
				sections.append("\(Self.dateTimeFormatter.string(from: event.date))  \(Self.eventTitle(event.kind))")
			}
		}
		
		if !bluetoothDevices.isEmpty {
			sections.append("")
			sections.append("【外设电量】")
			for device in bluetoothDevices {
				sections.append("\(device.name)：\(device.percent)%")
			}
		}
		
		return sections.joined(separator: "\n") + "\n"
	}
	
	// 报告里的体检行：分数 + 评语（与面板同一套算法）
	private var checkupLine: String? {
		guard let checkup = BatteryCheckup.evaluate(
			healthPercent: snapshot.healthPercent,
			cycleCount: snapshot.cycleCount,
			temperatureC: snapshot.temperatureC,
			highSocDwellShare: dailyHistory.last?.highSocDwellShare
		) else { return nil }
		return "\(checkup.score) 分  \(checkup.verdict)"
	}
	
	// 上次睡眠掉电行；没掉电或无记录则不出
	private var sleepLine: String? {
		guard let record = lastSleepDrain, record.droppedPercent >= 1 else { return nil }
		return String(format: "\(Self.dateTimeFormatter.string(from: record.sleepDate)) 起合盖 \(record.durationMinutes) 分钟，掉了 \(record.droppedPercent)%%（%.1f%%/小时）", record.dropPerHour)
	}

	// 电池档案行：序列号/电芯厂商/生产日期/容量/电芯配置/跳变状态
	private func identityLines(_ identity: BatteryIdentity) -> [String]? {
		var lines: [String] = []
		if let serial = identity.serialNumber { lines.append("序列号：\(serial)") }
		if let vendor = identity.cellVendorName { lines.append("电芯厂商：\(vendor)") }
		if let dateText = identity.manufactureDateText { lines.append("生产日期：\(dateText)") }
		if let design = identity.designCapacityMAh {
			var line = "设计容量：\(design) mAh"
			if let max = snapshot.maxCapacityMAh, max > 0 { line += "（当前满充 \(max) mAh）" }
			lines.append(line)
		}
		if !identity.cellVoltagesMV.isEmpty {
			var line = "电芯配置：\(identity.cellVoltagesMV.count) 芯串联"
			if let balance = BatteryIdentityDecoder.cellBalance(identity.cellVoltagesMV) {
				line += "，压差 \(balance.deltaMV) mV"
			}
			lines.append(line)
		}
		if socJumpCount30d > 0 {
			lines.append("电量跳变：最近 30 天 \(socJumpCount30d) 次")
		}
		return lines
	}
	
	// 当前接着的充电器身份键：与 recorder 的建档规则同源，不再各拼一份
	private var currentChargerKey: String? {
		guard snapshot.powerSource == .powerAdapter else { return nil }
		return BatteryHistoryRecorder.chargerKey(
			name: snapshot.adapterName ?? "",
			manufacturer: snapshot.adapterManufacturer ?? "",
			ratedWatts: snapshot.adapterRatedWatts ?? 0,
			tiers: snapshot.powerTiers,
			isWireless: snapshot.chargingProtocol == "无线充电"
		)
	}
	
	private static func eventTitle(_ kind: PowerEventKind) -> String {
		switch kind {
		case .pluggedIn: return "接上电源"
		case .unplugged: return "拔掉电源"
		case .chargedFull: return "充满电"
		case .sleep: return "进入睡眠"
		case .wake: return "唤醒"
		}
	}
	
	// 报告里不受面板开关限制，输出全部可用信息
	private func currentStatusLines() -> [String] {
		var fullConfiguration = configuration
		fullConfiguration.enabledOptions = Set(DisplayOption.allCases)
		
		return BatteryInfoFormatter(
			snapshot: snapshot,
			configuration: fullConfiguration,
			drainEstimate: drainEstimate,
			healthTrend: nil
		).makeLines()
	}
	
	private static let dateTimeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		// 报告里的日期用固定公历数字格式，不随系统非公历区域输出异常年份
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd HH:mm"
		return formatter
	}()
	
	private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter
	}()
}
