import Foundation

// 时长格式化：把分钟数转成"X小时Y分钟"的中文表述
// 抽成单一工具，供面板续航/充满预告、通知文案等多处复用，避免各写一份逻辑漂移
enum DurationFormatter {
	// 整小时不带分钟、不满一小时不带小时；0 分钟按"0分钟"处理
	static func chinese(minutes: Int) -> String {
		let safe = max(0, minutes)
		let hours = safe / 60
		let mins = safe % 60
		if hours > 0, mins > 0 { return "\(hours)小时\(mins)分钟" }
		if hours > 0 { return "\(hours)小时" }
		return "\(mins)分钟"
	}
}
