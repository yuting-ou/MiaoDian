import Foundation

// 时长与时刻格式化：面板续航/充满预告、通知文案等多处复用，避免各写一份逻辑漂移
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
	
	// N 分钟后的时刻（"HH:mm"），跨天时加"明天"免得误以为是今天
	// now/calendar/timeZone 均可注入，供单测固定时区与日期
	static func clockText(
		afterMinutes minutes: Int,
		from now: Date = Date(),
		calendar: Calendar = .current,
		timeZone: TimeZone = .current
	) -> String {
		let target = now.addingTimeInterval(TimeInterval(minutes) * 60)
		// DateFormatter 是引用类型，必须复制后再设时区，否则会污染共享模板
		let formatter = clockFormatter.copy() as! DateFormatter
		formatter.timeZone = timeZone
		let time = formatter.string(from: target)
		return calendar.isDateInTomorrow(target) ? "明天 " + time : time
	}
	
	// 每次调用复制一份再设时区，静态实例本身保持无状态
	private static let clockFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()
}
