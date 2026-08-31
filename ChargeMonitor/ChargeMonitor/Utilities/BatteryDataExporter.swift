import Foundation

// 历史数据导出为 CSV：把应用记录的时序数据（充电记录/每日用电/健康度/24h 电量/电源事件）
// 落成一份可被 Excel/Numbers/Python 直接读取的文本，方便用户自己长期分析。
// 纯本地输出，符合应用"数据自主、不上传"的定位
enum BatteryDataExporter {
	// 单文件多表：每张表用 "# 表名" 注释行 + 表头行 + 数据行，表间空一行分隔
	static func csv(
		sessions: [ChargeSession],
		dailyHistory: [DailyUsage],
		healthSamples: [HealthSample],
		socSamples: [SOCSample],
		powerEvents: [PowerEvent]
	) -> String {
		var lines: [String] = []

		appendSection(title: "充电记录", header: ["开始时间", "结束时间", "起始电量%", "结束电量%", "峰值功率W", "时长分钟"], rows: sessions.map { session in
			[dateText(session.startDate), dateText(session.endDate), "\(session.startPercent)", "\(session.endPercent)",
			 formatNumber(session.peakInputW), "\(session.durationMinutes)"]
		}, to: &lines)

		appendSection(title: "每日用电", header: ["日期", "用电%", "充入%", "插电秒", "电池秒", "插电占比"], rows: dailyHistory.map { usage in
			let share = usage.acShare.map { String(format: "%.3f", $0) } ?? ""
			return [usage.dayKey, "\(usage.drainedPercent)", "\(usage.chargedPercent)",
					formatNumber(usage.acSeconds), formatNumber(usage.batterySeconds), share]
		}, to: &lines)

		appendSection(title: "健康度趋势", header: ["日期", "健康度%", "循环次数"], rows: healthSamples.map { sample in
			[sample.date.ISO8601Format(), "\(sample.healthPercent)", sample.cycleCount.map(String.init) ?? ""]
		}, to: &lines)

		appendSection(title: "24小时电量", header: ["时间", "电量%", "是否充电"], rows: socSamples.map { sample in
			[dateText(sample.date), "\(sample.percent)", sample.isCharging ? "是" : "否"]
		}, to: &lines)

		appendSection(title: "电源事件", header: ["时间", "事件"], rows: powerEvents.map { event in
			[dateText(event.date), Self.eventName(event.kind)]
		}, to: &lines)

		return lines.joined(separator: "\n") + "\n"
	}

	private static func appendSection(title: String, header: [String], rows: [[String]], to lines: inout [String]) {
		if !lines.isEmpty { lines.append("") }
		lines.append("# \(title)")
		lines.append(header.map(escape).joined(separator: ","))
		for row in rows {
			lines.append(row.map(escape).joined(separator: ","))
		}
	}

	// CSV 转义：含逗号/引号/换行的字段用双引号包裹，内部引号翻倍
	private static func escape(_ field: String) -> String {
		if field.contains(",") || field.contains("\"") || field.contains("\n") {
			return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
		}
		return field
	}

	// 有小数就保留小数，整数写成整数，避免 Excel 里出现 "90.0"
	private static func formatNumber(_ value: Double) -> String {
		let rounded = value.rounded()
		if abs(value - rounded) < 0.0001 { return "\(Int(rounded))" }
		return String(format: "%.3f", value)
	}

	private static func eventName(_ kind: PowerEventKind) -> String {
		switch kind {
		case .pluggedIn: return "接上电源"
		case .unplugged: return "拔掉电源"
		case .chargedFull: return "充满电"
		case .sleep: return "进入睡眠"
		case .wake: return "唤醒"
		}
	}

	private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
		return formatter
	}()

	private static func dateText(_ date: Date) -> String {
		dateFormatter.string(from: date)
	}
}