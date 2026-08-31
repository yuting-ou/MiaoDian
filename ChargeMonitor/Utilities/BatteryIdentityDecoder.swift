import Foundation

// 电池出厂信息解码：把 IOKit 注册表里的原始字节/整数翻译成人话
// 全部纯函数（实机数据做成 fixture 进单测），读取层只负责取数
nonisolated enum BatteryIdentityDecoder {
	// ManufacturerData / MfgData 里的 TLV 结构解析结果
	struct ParsedInfo: Equatable, Sendable {
		// YYWW 日期码（如 "1916"），与电芯批次一起写入出厂数据
		let dateCode: String?
		// 电芯厂商代码（如 "ATL"）
		let vendorCode: String?
	}

	// 扫描 [长度字节][N 个可打印 ASCII 字符] 结构的串：
	// 厂商数据里藏着日期码（4 位数字）、批次（3 位数字）、厂商代码（2~5 位大写字母）
	static func parseManufacturerData(_ data: Data) -> ParsedInfo? {
		let runs = asciiRuns(in: data)
		let dateCode = runs.first { $0.count == 4 && $0.allSatisfy(\.isNumber) }
		let vendorCode = runs.first {
			(2...5).contains($0.count) && $0.allSatisfy { $0.isUppercase && $0.isLetter }
		}
		guard dateCode != nil || vendorCode != nil else { return nil }
		return ParsedInfo(dateCode: dateCode, vendorCode: vendorCode)
	}

	// 逐字节找长度前缀的可打印串；长度只认 2~8（厂商数据里的串都很短），
	// 二进制噪声段因为含不可打印字节自然被跳过
	static func asciiRuns(in data: Data) -> [String] {
		let bytes = [UInt8](data)
		var runs: [String] = []
		var index = 0
		while index < bytes.count {
			let length = Int(bytes[index])
			guard length >= 2, length <= 8, index + 1 + length <= bytes.count else {
				index += 1
				continue
			}
			let slice = bytes[(index + 1)..<(index + 1 + length)]
			guard slice.allSatisfy({ (0x20...0x7E).contains($0) }) else {
				index += 1
				continue
			}
			if let text = String(bytes: slice, encoding: .ascii) {
				runs.append(text)
			}
			index += 1 + length
		}
		return runs
	}

	// macOS 10.15+ 电池的 ManufactureDate 大整数：以 2001-01-01 为纪元的 100µs 计数
	// （osquery 社区在 Intel/Apple Silicon 实机上逆向验证的编码；
	// 解出的日期落在合理出生区间内才采信，防止把噪声当日期）
	static func manufactureDateText(largeValue: Int64, now: Date = Date()) -> String? {
		guard largeValue > 0xFFFF else { return nil }
		let date = Date(timeIntervalSinceReferenceDate: TimeInterval(largeValue) / 100_000.0)
		guard date >= earliestPlausibleDate, date < now.addingTimeInterval(366 * 86400) else { return nil }
		return calendarDayText(date)
	}

	// Intel 旧机型的 16 位 SMBus 日期字：bits 15-9 年（1980 起）、8-5 月、4-0 日
	static func smbusDateText(_ word: Int, now: Date = Date()) -> String? {
		guard (0...0xFFFF).contains(word) else { return nil }
		let year = 1980 + (word >> 9)
		let month = (word >> 5) & 0xF
		let day = word & 0x1F
		guard (1...12).contains(month), (1...31).contains(day) else { return nil }
		guard let date = dateComponentsToDate(year: year, month: month, day: day) else { return nil }
		guard date >= earliestPlausibleDate, date < now.addingTimeInterval(366 * 86400) else { return nil }
		return calendarDayText(date)
	}

	// YYWW 日期码 → "2019 年第 16 周"
	static func dateCodeText(_ code: String) -> String? {
		guard code.count == 4, code.allSatisfy(\.isNumber),
			let year = Int(code.prefix(2)), let week = Int(code.suffix(2)),
			(1...53).contains(week)
		else { return nil }
		return "\(2000 + year) 年第 \(week) 周"
	}

	// 电芯厂商代码 → 展示名；没收录的直接显示原码
	static func vendorDisplayName(_ code: String?) -> String? {
		guard let code, !code.isEmpty else { return nil }
		switch code {
		case "ATL": return "ATL（新能源科技）"
		case "LGC", "LGCS": return "LG 化学"
		case "SONY": return "索尼"
		case "SDI": return "三星 SDI"
		case "SMP", "COS": return "新普科技"
		case "DYNT": return "顺达科技"
		case "SUNW": return "欣旺达"
		case "PAN", "PANZ": return "松下"
		default: return code
		}
	}

	// 串联电芯的均衡情况：芯数与最大压差（mV）
	static func cellBalance(_ voltagesMV: [Int]) -> (count: Int, deltaMV: Int)? {
		guard voltagesMV.count >= 2 else { return nil }
		guard let maxV = voltagesMV.max(), let minV = voltagesMV.min() else { return nil }
		return (voltagesMV.count, maxV - minV)
	}

	// 均衡情况的展示文本："3 芯 · 压差 3 mV"
	static func cellBalanceText(_ voltagesMV: [Int]) -> String? {
		guard let balance = cellBalance(voltagesMV) else { return nil }
		return "\(balance.count) 芯 · 压差 \(balance.deltaMV) mV"
	}

	// BatteryData["CellVoltage"]：串联电芯电压数组（mV），过滤掉 0 和异常值
	static func cellVoltages(from batteryData: [String: Any]?) -> [Int] {
		guard let raw = batteryData?["CellVoltage"] as? [Any] else { return [] }
		return raw.compactMap { ($0 as? NSNumber)?.intValue }.filter { (100...10_000).contains($0) }
	}

	// MARK: - 内部辅助

	// 日期合理下限：2001 纪元前不存在这种编码，也早于所有在役 Mac 的电池
	// （Date 的参考纪元正是 2001-01-01，偏移 0 即纪元本身）
	private static let earliestPlausibleDate = Date(timeIntervalSinceReferenceDate: 0)

	// 统一用 UTC 取年月日：出厂时间戳以 UTC 写入，显示到"日"不受运行时区影响
	private static func calendarDayText(_ date: Date) -> String? {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
		let components = calendar.dateComponents([.year, .month, .day], from: date)
		guard let year = components.year, let month = components.month, let day = components.day else { return nil }
		return "\(year) 年 \(month) 月 \(day) 日"
	}

	private static func dateComponentsToDate(year: Int, month: Int, day: Int) -> Date? {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
		let components = DateComponents(year: year, month: month, day: day)
		return calendar.date(from: components)
	}
}
