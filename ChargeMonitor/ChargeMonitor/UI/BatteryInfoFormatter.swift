import SwiftUI

// 单条信息：图标 + 标签 + 值（+ 可选着色 + 可选悬停说明）
struct BatteryInfoItem: Identifiable {
	enum Group {
		case power
		case battery
	}

	let group: Group
	let symbol: String
	let label: String
	let value: String
	var iconTint: Color? = nil
	var valueTint: Color? = nil
	// 悬停 tooltip：充电功率行用它解释"为什么功率小"这类读数疑惑
	var helpText: String? = nil

	var id: String { label }
}

struct BatteryInfoFormatter {
	let snapshot: BatterySnapshot
	let configuration: AppConfiguration
	var drainEstimate: DrainRateEstimate? = nil
	var healthTrend: (earliest: HealthSample, latest: HealthSample)? = nil
	// 上一觉合盖的掉电记录与当前充电器档案，面板传入；报告自建 formatter 走默认值
	var sleepDrain: SleepDrainRecord? = nil
	var chargerProfile: ChargerProfile? = nil
	// 当前充电器的协商功率统计（质量诊断），面板传入
	var chargerStats: ChargerPowerStats? = nil
	// 面板头部已有"还能用多久 / 还要充多久"一句话，面板信息行不再重复这两条；
	// 导出报告自建 formatter 走默认值，报告里仍保留
	var omitsTimeEstimates = false
	
	func makeItems(in group: BatteryInfoItem.Group) -> [BatteryInfoItem] {
		makeItems().filter { $0.group == group }
	}
	
	func makeItems() -> [BatteryInfoItem] {
		var items: [BatteryInfoItem] = []
		
		appendIfPresent(timeToFullItem, to: &items)
		appendIfPresent(chargingProtocolItem, to: &items)
		appendIfPresent(negotiatedTierItem, to: &items)
		appendIfPresent(availableTiersItem, to: &items)
		appendIfPresent(inputPowerItem, to: &items)
		appendIfPresent(chargingPowerItem, to: &items)
		appendIfPresent(currentPowerItem, to: &items)
		
		if snapshot.powerSource == .powerAdapter {
			appendIfPresent(adapterNameItem, to: &items)
			appendIfPresent(adapterManufacturerItem, to: &items)
			appendIfPresent(chargerProfileItem, to: &items)
		}
		
		appendIfPresent(cycleCountItem, to: &items)
		appendIfPresent(healthItem, to: &items)
		appendIfPresent(healthTrendItem, to: &items)
		appendIfPresent(temperatureItem, to: &items)
		appendIfPresent(batteryCurrentVoltageItem, to: &items)
		appendIfPresent(timeToEmptyItem, to: &items)
		appendIfPresent(drainRateItem, to: &items)
		appendIfPresent(sleepDrainItem, to: &items)
		appendIfPresent(uptimeItem, to: &items)
		
		return items
	}
	
	// 报告用的纯文本行
	func makeLines() -> [String] {
		var lines: [String] = []
		
		lines.append(powerSourceLine)
		if snapshot.isLowPowerModeEnabled {
			lines.append("低电量模式：已开启")
		}
		if showsNotChargingWarning {
			lines.append("电池未在充电")
		}
		lines.append(chargingStatusLine)
		lines.append(contentsOf: makeItems().map { "\($0.label)：\($0.value)" })
		
		return lines
	}
	
	private var enabledOptions: Set<DisplayOption> {
		configuration.enabledOptions
	}
	
	private var powerSourceLine: String {
		switch snapshot.powerSource {
		case .powerAdapter: return "电源来源：电源适配器"
		case .battery: return "电源来源：电池"
		}
	}
	
	private var showsNotChargingWarning: Bool {
		snapshot.powerSource == .powerAdapter && !snapshot.isCharging && !snapshot.isFull
	}
	
	private var chargingStatusLine: String {
		if snapshot.isFull { return "充电：已充满" }
		
		let label = snapshot.isCharging && snapshot.isFastCharging ? "充电（快充）" : "充电"
		let value: String = {
			guard snapshot.isCharging else { return "否" }
			return snapshot.stateOfChargePercent.map { "\($0)%" } ?? "是"
		}()
		
		return "\(label)：\(value)"
	}
	
	// MARK: - 电源相关
	
	private var timeToFullItem: BatteryInfoItem? {
		guard !omitsTimeEstimates else { return nil }
		guard let minutes = snapshot.timeToFullChargeMinutes, minutes > 0, !snapshot.isFull else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "hourglass",
			label: "充满还需",
			value: DurationFormatter.chinese(minutes: minutes),
			iconTint: .green
		)
	}
	
	private var chargingProtocolItem: BatteryInfoItem? {
		guard enabledOptions.contains(.chargingProtocol) else { return nil }
		guard snapshot.powerSource == .powerAdapter else { return nil }
		guard let name = snapshot.chargingProtocol else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "bolt.horizontal.circle.fill",
			label: "充电协议",
			value: name,
			iconTint: .yellow
		)
	}
	
	private var negotiatedTierItem: BatteryInfoItem? {
		guard enabledOptions.contains(.powerTiers) else { return nil }
		guard snapshot.powerSource == .powerAdapter else { return nil }
		guard
			let voltageMV = snapshot.negotiatedVoltageMV,
			let currentMA = snapshot.negotiatedCurrentMA,
			voltageMV > 0, currentMA > 0
		else { return nil }
		
		let watts = Double(voltageMV) * Double(currentMA) / 1_000_000.0
		var value = "\(formatVoltage(voltageMV)) \(formatCurrent(currentMA))（\(formatTierWatts(watts))）"
		// 协商明显低于额定 → 染橙提示可能是线材/接口问题（与"充电器偏慢"洞察同一套语言）
		var tint: Color? = nil
		if let rated = snapshot.adapterRatedWatts, rated > 0, watts < Double(rated) * 0.6 {
			tint = .orange
			value += " · 额定\(rated)W"
		} else if let rated = snapshot.adapterRatedWatts, rated > 0 {
			value += " · 额定\(rated)W"
		}
		return BatteryInfoItem(
			group: .power,
			symbol: "speedometer",
			label: "当前档位",
			value: value,
			iconTint: .blue,
			valueTint: tint
		)
	}
	
	private var availableTiersItem: BatteryInfoItem? {
		guard enabledOptions.contains(.powerTiers) else { return nil }
		guard snapshot.powerSource == .powerAdapter, !snapshot.powerTiers.isEmpty else { return nil }
		
		let parts = snapshot.powerTiers.enumerated().map { index, tier -> String in
			let watts = Double(tier.maxVoltageMV) * Double(tier.maxCurrentMA) / 1_000_000.0
			let text = formatTierWatts(watts)
			return index == snapshot.activeTierIndex ? "✓\(text)" : text
		}
		return BatteryInfoItem(
			group: .power,
			symbol: "square.grid.2x2",
			label: "可选档位",
			value: parts.joined(separator: " / "),
			iconTint: .blue
		)
	}
	
	private var inputPowerItem: BatteryInfoItem? {
		guard enabledOptions.contains(.inputWatts) else { return nil }
		guard let watts = visibleWatts(snapshot.adapterInputPowerW) else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "arrow.down.circle.fill",
			label: "输入功率",
			value: formatWatts(watts),
			iconTint: .teal
		)
	}
	
	private var chargingPowerItem: BatteryInfoItem? {
		guard enabledOptions.contains(.chargingWatts) else { return nil }
		guard snapshot.isCharging, let watts = visibleWatts(snapshot.chargingPowerW) else { return nil }
		// 充电阶段标注：涓流期"充电功率 0.3W"与"输入功率 20W"并存最容易困惑，
		// 值后挂阶段名，悬停给一句物理解释
		var phaseSuffix = ""
		var help: String? = nil
		if let phase = UsagePatternAnalyzer.chargingPhase(socPercent: snapshot.stateOfChargePercent) {
			phaseSuffix = " · \(phase.label)"
			help = "\(phase.label)：\(phase.explanation)"
		}
		return BatteryInfoItem(
			group: .power,
			symbol: "bolt.circle.fill",
			label: "充电功率",
			value: formatWatts(watts) + phaseSuffix,
			iconTint: .green,
			helpText: help
		)
	}
	
	private var currentPowerItem: BatteryInfoItem? {
		guard enabledOptions.contains(.currentWatts) else { return nil }
		guard let watts = visibleWatts(snapshot.currentPowerW) else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "cpu",
			label: "当前功耗",
			value: formatWatts(watts),
			iconTint: .purple
		)
	}
	
	private var adapterNameItem: BatteryInfoItem? {
		guard enabledOptions.contains(.adapterName) else { return nil }
		guard let name = snapshot.adapterName, !name.isEmpty else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "cable.connector",
			label: "适配器名称",
			value: name
		)
	}
	
	private var adapterManufacturerItem: BatteryInfoItem? {
		guard enabledOptions.contains(.adapterManufacturer) else { return nil }
		guard let value = snapshot.adapterManufacturer, !value.isEmpty else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "building.2",
			label: "制造商",
			value: value
		)
	}
	
	// 充电器档案：认识的充电器打个招呼，第一次见的标出来；
	// 有名字（用户起的或系统识别的）先亮名字，认不出的标"未命名"引导去设置认领；
	// 有历史统计时附上"平均协商功率"，疑似慢充染橙提醒可能是线材/接口问题
	private var chargerProfileItem: BatteryInfoItem? {
		guard enabledOptions.contains(.chargerProfile) else { return nil }
		guard snapshot.powerSource == .powerAdapter, let profile = chargerProfile else { return nil }

		let isNew = profile.connectCount <= 1
		let isUnnamed = profile.name.isEmpty && (profile.customName?.isEmpty ?? true)
		var value: String
		if isUnnamed {
			value = isNew ? "未命名 · 第一次见" : "未命名 · 见过 \(profile.connectCount) 次"
		} else {
			value = "\(profile.displayName) · \(isNew ? "第一次见" : "见过 \(profile.connectCount) 次")"
		}
		let tint: Color? = isNew ? .orange : .green
		var valueTint: Color? = nil

		if let stats = chargerStats, let avg = stats.avgWatts, stats.sampleCount >= 5 {
			value += " · 平均\(formatTierWatts(avg))"
			if stats.isSuspiciouslySlow {
				value += "「疑似慢充」"  // 平均协商远低于额定，多半线材/接口不行
				valueTint = .orange
			}
		}
		return BatteryInfoItem(
			group: .power,
			symbol: isNew ? "sparkles" : "checkmark.seal.fill",
			label: "充电器",
			value: value,
			iconTint: tint,
			valueTint: valueTint,
			helpText: isUnnamed ? "系统认不出这只充电器，可在设置 → 充电器里给它起个名字" : nil
		)
	}
	
	// MARK: - 电池相关
	
	private var cycleCountItem: BatteryInfoItem? {
		guard enabledOptions.contains(.cycleCount) else { return nil }
		return BatteryInfoItem(
			group: .battery,
			symbol: "arrow.triangle.2.circlepath",
			label: "循环次数",
			// 对比苹果标称的 1000 次循环寿命，数字才有参照系
			value: snapshot.cycleCount.map { "\($0) / 1000" } ?? "—",
			iconTint: .teal
		)
	}
	
	private var healthItem: BatteryInfoItem? {
		guard enabledOptions.contains(.batteryHealth) else { return nil }
		guard let percent = snapshot.healthPercent else { return nil }
		
		var value = "\(percent)%"
		if let max = snapshot.maxCapacityMAh, let design = snapshot.designCapacityMAh {
			value += "（\(max)/\(design) mAh）"
		}
		return BatteryInfoItem(
			group: .battery,
			symbol: "heart.fill",
			label: "电池健康",
			value: value,
			iconTint: .pink
		)
	}
	
	private var healthTrendItem: BatteryInfoItem? {
		guard enabledOptions.contains(.healthTrend) else { return nil }
		guard let trend = healthTrend else { return nil }
		
		let days = max(1, Int(trend.latest.date.timeIntervalSince(trend.earliest.date) / 86400))
		return BatteryInfoItem(
			group: .battery,
			symbol: "chart.line.uptrend.xyaxis",
			label: "健康趋势",
			value: "\(trend.earliest.healthPercent)% → \(trend.latest.healthPercent)% · 近\(days)天",
			iconTint: .mint
		)
	}
	
	private var temperatureItem: BatteryInfoItem? {
		guard enabledOptions.contains(.batteryTemperature) else { return nil }
		guard let temperature = snapshot.temperatureC else { return nil }
		return BatteryInfoItem(
			group: .battery,
			symbol: "thermometer.medium",
			label: "电池温度",
			value: String(format: "%.1f°C", temperature),
			iconTint: .orange,
			valueTint: temperature >= Double(configuration.highTemperatureThresholdC) ? .orange : nil
		)
	}
	
	// 电池端实时电流电压：正号在充、负号在放，一行看完
	private var batteryCurrentVoltageItem: BatteryInfoItem? {
		guard enabledOptions.contains(.batteryCurrentVoltage) else { return nil }
		guard let voltageMV = snapshot.batteryVoltageMV, let amperageMA = snapshot.batteryAmperageMA else { return nil }
		
		let volts = Double(voltageMV) / 1000
		let amps = Double(amperageMA) / 1000
		// 电流四舍五入到 0.00 时不带符号：插电未充电的微小噪声读数不该显示成刺眼的 "-0.00A"
		let ampsText = abs(amps) < 0.005 ? "0.00" : String(format: "%+.2f", amps)
		return BatteryInfoItem(
			group: .battery,
			symbol: "bolt.ring.closed",
			label: "电流电压",
			value: String(format: "%.2fV · %@A", volts, ampsText),
			iconTint: .cyan
		)
	}
	
	private var timeToEmptyItem: BatteryInfoItem? {
		guard !omitsTimeEstimates else { return nil }
		guard enabledOptions.contains(.timeRemaining) else { return nil }
		guard snapshot.powerSource == .battery, !snapshot.isCharging else { return nil }
		guard let minutes = snapshot.timeToEmptyMinutes, minutes > 0 else { return nil }
		return BatteryInfoItem(
			group: .battery,
			symbol: "clock",
			label: "剩余可用时间",
			value: DurationFormatter.chinese(minutes: minutes),
			iconTint: .indigo
		)
	}
	
	// 掉电速度基于最近一小时的真实放电记录
	private var drainRateItem: BatteryInfoItem? {
		guard enabledOptions.contains(.drainRate) else { return nil }
		guard snapshot.powerSource == .battery, !snapshot.isCharging else { return nil }
		guard let estimate = drainEstimate else { return nil }
		
		var value = String(format: "%.1f%%/小时", estimate.percentPerHour)
		if let minutes = estimate.estimatedMinutesRemaining, minutes > 0 {
			value += " · 约可用\(DurationFormatter.chinese(minutes: minutes))"
		}
		return BatteryInfoItem(
			group: .battery,
			symbol: "arrow.down.right.circle",
			label: "掉电速度",
			value: value,
			iconTint: .red
		)
	}
	
	private var uptimeItem: BatteryInfoItem? {
		guard enabledOptions.contains(.uptime) else { return nil }
		return BatteryInfoItem(
			group: .battery,
			symbol: "desktopcomputer",
			label: "开机时长",
			value: formatUptime(snapshot.systemUptimeSeconds) ?? "—",
			iconTint: .gray
		)
	}
	
	// 上一觉合盖掉了多少电；没掉电或超过一天的旧记录不再展示
	private var sleepDrainItem: BatteryInfoItem? {
		guard enabledOptions.contains(.sleepDrainReport) else { return nil }
		guard let record = sleepDrain, record.droppedPercent >= 1 else { return nil }
		guard Date().timeIntervalSince(record.wakeDate) < 24 * 3600 else { return nil }

		// 跟提醒同一套判定：掉得偏快的把数字染橙警示
		let isHeavy = record.durationMinutes >= 60 && record.dropPerHour >= 2
		var value = String(format: "合盖%@ 掉了%d%%（%.1f%%/小时）", DurationFormatter.chinese(minutes: record.durationMinutes), record.droppedPercent, record.dropPerHour)
		// 元凶留档后，面板也能复述"谁在阻止睡眠"
		if let culprits = record.culpritNames, !culprits.isEmpty {
			value += "（元凶：\(culprits.prefix(2).joined(separator: "、"))\(culprits.count > 2 ? "等" : "")）"
		}
		return BatteryInfoItem(
			group: .battery,
			symbol: "moon.zzz.fill",
			label: "睡眠掉电",
			value: value,
			iconTint: .indigo,
			valueTint: isHeavy ? .orange : nil
		)
	}
	
	// MARK: - 格式化辅助
	
	private func visibleWatts(_ value: Double?) -> Double? {
		guard let value, value >= IOKitBatteryReader.minimumVisibleWatts else { return nil }
		return value
	}
	
	private func formatWatts(_ value: Double) -> String {
		String(format: "%.2fW", value)
	}
	
	private func formatTierWatts(_ value: Double) -> String {
		let rounded = value.rounded()
		if abs(value - rounded) < 0.05 { return "\(Int(rounded))W" }
		return String(format: "%.1fW", value)
	}
	
	private func formatVoltage(_ millivolts: Int) -> String {
		let volts = Double(millivolts) / 1000.0
		let rounded = volts.rounded()
		if abs(volts - rounded) < 0.05 { return "\(Int(rounded))V" }
		return String(format: "%.1fV", volts)
	}
	
	private func formatCurrent(_ milliamps: Int) -> String {
		let amps = Double(milliamps) / 1000.0
		let rounded = amps.rounded()
		if abs(amps - rounded) < 0.05 { return "\(Int(rounded))A" }
		return String(format: "%.1fA", amps)
	}
	
	private func formatUptime(_ seconds: TimeInterval) -> String? {
		Self.uptimeFormatter.string(from: seconds)
	}
	
	private func appendIfPresent(_ item: BatteryInfoItem?, to items: inout [BatteryInfoItem]) {
		guard let item else { return }
		items.append(item)
	}
	
	private static let uptimeFormatter: DateComponentsFormatter = {
		let dcf = DateComponentsFormatter()
		var calendar = Calendar.current
		calendar.locale = Locale(identifier: "zh_CN")
		dcf.calendar = calendar
		dcf.allowedUnits = [.day, .hour, .minute]
		dcf.unitsStyle = .abbreviated
		dcf.zeroFormattingBehavior = .dropAll
		return dcf
	}()
}
