// 用电日历周历排布：纯逻辑，从 TrendAndCalendarSections 切出——
// 视图文件因 SwiftUIMacros 进不了测试编译面，纯算法必须自立文件。
import Foundation

// 用电日历的周历排布（纯逻辑，抽出来可注入 today/calendar 供单测）
// 网格永远以「真实今天」为右下锚点，而非最后一条数据的日期——
// 否则今天还没产生用电数据时，日历会以昨天为基准，日期整体错位
enum UsageCalendarLayout {
	// 与 dayKey 主键同源，固定 POSIX 公历，避免非公历系统下日期错乱；
	// 时区跟随 buildColumns 注入的 calendar（生产时 .current 即系统时区，行为不变）
	static func dayKey(_ date: Date, calendar: Calendar) -> String {
		var gregorian = Calendar(identifier: .gregorian)
		gregorian.timeZone = calendar.timeZone
		let c = gregorian.dateComponents([.year, .month, .day], from: date)
		return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
	}

	static func buildColumns(_ history: [DailyUsage], weeks: Int, today: Date, calendar: Calendar) -> [[DailyUsage?]] {
		let byKey = Dictionary(history.map { ($0.dayKey, $0) }, uniquingKeysWith: { _, b in b })
		let todayStart = calendar.startOfDay(for: today)
		
		// 从今天所在周往前数 weeks-1 周的周日作为起点
		let todayWeekday = calendar.component(.weekday, from: todayStart) - 1 // 0=周日
		guard let gridStart = calendar.date(byAdding: .day, value: -(todayWeekday + (weeks - 1) * 7), to: todayStart) else { return [] }
		
		var columns: [[DailyUsage?]] = []
		var cursor = gridStart
		for _ in 0..<weeks {
			var week: [DailyUsage?] = []
			for _ in 0..<7 {
				if cursor > todayStart {
					week.append(nil)
				} else {
					week.append(byKey[dayKey(cursor, calendar: calendar)])
				}
				cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
			}
			columns.append(week)
		}
		return columns
	}
}
