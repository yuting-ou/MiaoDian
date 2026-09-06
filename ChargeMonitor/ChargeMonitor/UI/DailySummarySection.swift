import SwiftUI

// 今日小结：电池模式掉了多少、充进去多少、充了几次；有多天数据时附七天柱状图
struct DailySummarySection: View {
	let usage: DailyUsage
	let chargeCount: Int
	let history: [DailyUsage]
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "今日小结", isCollapsed: isCollapsed, onToggle: onToggle) {
				// 折叠时留一句概要，不点开也能瞥一眼
				if isCollapsed {
					Text("用电 \(usage.drainedPercent)% · 充入 \(usage.chargedPercent)%")
						.font(.system(size: 10).monospacedDigit())
						.foregroundStyle(GlassTokens.labelOnGlass)
				}
			}
			.padding(.bottom, isCollapsed ? 0 : 2)
			
			if !isCollapsed {
				HStack(spacing: 0) {
					statItem(symbol: "arrow.down.circle.fill", color: .orange, value: "\(usage.drainedPercent)%", label: "用电")
					statItem(symbol: "bolt.circle.fill", color: .green, value: "\(usage.chargedPercent)%", label: "充入")
					statItem(symbol: "repeat.circle.fill", color: .blue, value: "\(chargeCount) 次", label: "充电")
				}
				.padding(.vertical, 2)
				
				// 插电占比：长期插电党能看到自己的习惯
				if let share = usage.acShare {
					Text(String(format: "今天 %.0f%% 的时间插着电源", share * 100))
						.font(.system(size: 9))
						.foregroundStyle(.tertiary)
						.padding(.top, 1)
				}

				// 高电量驻留：80%+ 停留时长是电化学应力的直接度量
				if let dwellMinutes = usage.dwell80PlusMinutes {
					Text("高电量（80%+）驻留 \(DurationFormatter.chinese(minutes: dwellMinutes))")
						.font(.system(size: 9))
						.foregroundStyle(.tertiary)
						.padding(.top, 1)
				}
				
				// 至少两天数据才画对比图，单天没得比
				if history.count >= 2 {
					weekChart
						.padding(.top, 4)
				}
			}
		}
	}
	
	// 历史只存有数据的天；中间哪天没开机会断档，直接并排会误导成连续日期
	// 这里从窗口内最早一天连续排到今天，缺勤的日子补空柱占位
	private var paddedHistory: [DailyUsage] {
		let calendar = Calendar.current
		let today = calendar.startOfDay(for: Date())
		guard
			let firstKey = history.first?.dayKey,
			let firstDate = Self.dayKeyFormatter.date(from: firstKey),
			let windowStart = calendar.date(byAdding: .day, value: -6, to: today)
		else { return history }
		
		let byKey = Dictionary(history.map { ($0.dayKey, $0) }, uniquingKeysWith: { _, newer in newer })
		var result: [DailyUsage] = []
		var date = max(calendar.startOfDay(for: firstDate), windowStart)
		while date <= today {
			let key = Self.dayKeyFormatter.string(from: date)
			result.append(byKey[key] ?? DailyUsage(dayKey: key))
			guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
			date = next
		}
		return result
	}
	
	// 每天两根柱：橙色用电、绿色充入，高度按七天内最大值归一化
	private var weekChart: some View {
		let days = paddedHistory
		let maxValue = max(days.flatMap { [$0.drainedPercent, $0.chargedPercent] }.max() ?? 1, 1)
		return HStack(alignment: .bottom, spacing: 8) {
			ForEach(days, id: \.dayKey) { day in
				VStack(spacing: 2) {
					HStack(alignment: .bottom, spacing: 2) {
						bar(value: day.drainedPercent, maxValue: maxValue, color: .orange)
						bar(value: day.chargedPercent, maxValue: maxValue, color: .green)
					}
					.frame(height: 26, alignment: .bottom)
					
					Text(Self.dayLabel(day.dayKey))
						.font(.system(size: 8))
						.foregroundStyle(day.dayKey == days.last?.dayKey ? Color.primary : Color.secondary)
				}
				.frame(maxWidth: .infinity)
				// 悬停某天的柱子看具体数值（系统原生 tooltip）
				.help(Self.dayHelp(day))
			}
		}
	}
	
	private static func dayHelp(_ day: DailyUsage) -> String {
		let dateText = dayKeyFormatter.date(from: day.dayKey).map { helpDateFormatter.string(from: $0) } ?? day.dayKey
		return "\(dateText)：用电 \(day.drainedPercent)% · 充入 \(day.chargedPercent)%"
	}
	
	private static let helpDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "M月d日"
		return formatter
	}()
	
	private func bar(value: Int, maxValue: Int, color: Color) -> some View {
		Capsule()
			.fill(value > 0 ? color.opacity(0.85) : Color.secondary.opacity(0.18))
			.frame(width: 5, height: max(2, 26 * CGFloat(value) / CGFloat(maxValue)))
	}
	
	// 日期键转星期字，今天显示“今”
	private static func dayLabel(_ dayKey: String) -> String {
		guard let date = dayKeyFormatter.date(from: dayKey) else { return "" }
		if Calendar.current.isDateInToday(date) { return "今" }
		let weekday = Calendar.current.component(.weekday, from: date)
		return ["", "日", "一", "二", "三", "四", "五", "六"][weekday]
	}
	
	private static let dayKeyFormatter: DateFormatter = {
		let formatter = DateFormatter()
		// 解析落盘主键 dayKey，locale 必须与生成时一致用 POSIX 公历，否则非公历系统下解析会失败
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter
	}()
	
	private func statItem(symbol: String, color: Color, value: String, label: String) -> some View {
		HStack(spacing: 5) {
			Image(systemName: symbol)
				.font(.system(size: 13))
				.foregroundStyle(color)
			VStack(alignment: .leading, spacing: 0) {
				Text(value)
					.font(.system(size: PopoverLayout.bodyFontSize, weight: .semibold).monospacedDigit())
				Text(label)
					.font(.system(size: 9))
					.foregroundStyle(GlassTokens.labelOnGlass)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

