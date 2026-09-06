import SwiftUI

// 健康趋势图（自包含）：历史实线 + 可选的老化预测虚线，同一 Canvas 同一映射才对齐
// 有预测时历史只占左侧 62%，右侧留给延伸虚线；无预测时历史铺满全宽
struct HealthTrendChart: View {
	let samples: [HealthSample]
	let hasProjection: Bool
	
	var body: some View {
		Canvas { context, size in
			let values = samples.map { Double($0.healthPercent) }
			guard values.count >= 2, let maxV = values.max(), let minV = values.min() else { return }
			// 有预测时把 80% 纳入下界，保证交汇点在画布内；无预测则沿用原来的下限 2
			let lo = hasProjection ? min(minV, 80) : minV
			let range = max(maxV - lo, 2)
			let histFraction: CGFloat = hasProjection ? 0.62 : 1.0
			let histWidth = size.width * histFraction
			
			func yPos(_ v: Double) -> CGFloat {
				size.height * (0.88 - 0.72 * CGFloat((v - lo) / range))
			}
			
			let points = values.enumerated().map { index, value in
				CGPoint(x: histWidth * CGFloat(index) / CGFloat(values.count - 1), y: yPos(value))
			}
			
			// 中点二次曲线平滑
			var line = Path()
			line.move(to: points[0])
			for index in 1..<points.count {
				let prev = points[index - 1]
				let cur = points[index]
				let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
				line.addQuadCurve(to: mid, control: prev)
			}
			if let last = points.last { line.addLine(to: last) }
			
			var fill = line
			fill.addLine(to: CGPoint(x: histWidth, y: size.height))
			fill.addLine(to: CGPoint(x: 0, y: size.height))
			fill.closeSubpath()
			context.fill(fill, with: .linearGradient(
				Gradient(colors: [Color.green.opacity(0.3), Color.green.opacity(0.02)]),
				startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
			))
			context.stroke(line, with: .color(.green), lineWidth: 1.5)
			
			guard let lastPoint = points.last else { return }
			let halo = Path(ellipseIn: CGRect(x: lastPoint.x - 4, y: lastPoint.y - 4, width: 8, height: 8))
			context.fill(halo, with: .color(Color.green.opacity(0.25)))
			let dot = Path(ellipseIn: CGRect(x: lastPoint.x - 2, y: lastPoint.y - 2, width: 4, height: 4))
			context.fill(dot, with: .color(.green))
			
			// 老化预测虚线：从实线末端延到右边缘的 80% 点
			if hasProjection {
				let endPoint = CGPoint(x: size.width, y: yPos(80))
				var dash = Path()
				dash.move(to: lastPoint)
				dash.addLine(to: endPoint)
				context.stroke(dash, with: .color(Color.orange.opacity(0.75)), style: StrokeStyle(lineWidth: 1.3, dash: [3, 2]))
				
				let ring = Path(ellipseIn: CGRect(x: endPoint.x - 3, y: endPoint.y - 3, width: 6, height: 6))
				context.stroke(ring, with: .color(.orange), lineWidth: 1.3)
				let label = context.resolve(Text("80%").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.orange))
				let ls = label.measure(in: size)
				context.draw(label, at: CGPoint(x: size.width - ls.width / 2 - 1, y: max(endPoint.y - 9, ls.height / 2)), anchor: .center)
			}
		}
	}
}

// 充电习惯建议：一条本地统计得出的软提示（图标 + 一句话）
struct HabitInsightSection: View {
	// 洞察链 v2：多条洞察按优先级排列——第一条主行，其余次级行（字号/颜色降一档）
	let insights: [ChargingHabitInsight]
	
	var body: some View {
		PopoverCard {
			VStack(alignment: .leading, spacing: 1) {
				Text(insights.count > 1 ? "洞察" : "小建议")
					.font(.system(size: 9))
					.foregroundStyle(GlassTokens.labelOnGlass)
				ForEach(Array(insights.prefix(3).enumerated()), id: \.offset) { index, insight in
					HStack(alignment: .top, spacing: 6) {
						Image(systemName: insight.symbol)
							.font(.system(size: index == 0 ? 12 : 9))
							.symbolRenderingMode(.hierarchical)
							.foregroundStyle(Color.accentColor)
							.frame(width: 14)
						Text(insight.message)
							.font(.system(size: index == 0 ? 11 : 10))
							.foregroundStyle(index == 0 ? Color.primary : GlassTokens.labelOnGlass)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
			}
			.padding(.vertical, 1)
		}
	}
}

// 用电日历热力图：一格一天，颜色越深那天用电越狠（仅统计电池模式掉电）
// 仿 GitHub 贡献格子，按周列排，一眼看出长期用电规律
struct UsageCalendarSection: View {
	let history: [DailyUsage]
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	// 最多展示最近 N 周（面板宽度有限）
	private static let weeks = 10
	private static let cellSize: CGFloat = 11
	private static let cellGap: CGFloat = 3
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "用电日历", isCollapsed: isCollapsed, onToggle: onToggle) {
				if let peak = history.map(\.drainedPercent).max(), peak > 0 {
					Text("峰值 \(peak)%")
						.font(.system(size: 10, weight: .semibold).monospacedDigit())
						.foregroundStyle(GlassTokens.labelOnGlass)
				}
			}
			
			if !isCollapsed {
				grid
					.padding(.top, 6)
					.accessibilityElement(children: .ignore)
					.accessibilityLabel(calendarAccessibilityLabel)
				
				HStack(spacing: 4) {
					Text("少")
						.font(.system(size: 9))
						.foregroundStyle(.tertiary)
					ForEach([0.0, 0.3, 0.6, 1.0], id: \.self) { level in
						RoundedRectangle(cornerRadius: 2, style: .continuous)
							.fill(HeatmapPalette.cellColor(level))
							.frame(width: 9, height: 9)
					}
					Text("多")
						.font(.system(size: 9))
						.foregroundStyle(.tertiary)
					Spacer()
				}
				.padding(.top, 6)
			}
		}
	}
	
	// 日历热力图是一堆彩色方格，VoiceOver 读不出；给个天数 + 峰值的汇总朗读
	private var calendarAccessibilityLabel: String {
		let days = history.filter { $0.drainedPercent > 0 }.count
		let peak = history.map(\.drainedPercent).max() ?? 0
		return "用电日历，近 \(days) 天有用电记录，单日峰值 \(peak)%"
	}
	
	// 按周分列：每列一周（周日到周六），从早到晚从左到右
	private var grid: some View {
		let columns = Self.buildColumns(history)
		let maxDrain = max(history.map(\.drainedPercent).max() ?? 1, 1)
		return HStack(alignment: .top, spacing: Self.cellGap) {
			ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
				VStack(spacing: Self.cellGap) {
					ForEach(0..<7, id: \.self) { weekday in
						cell(week[weekday], maxDrain: maxDrain)
					}
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
	
	@ViewBuilder
	private func cell(_ day: DailyUsage?, maxDrain: Int) -> some View {
		if let day {
			let level = Double(day.drainedPercent) / Double(maxDrain)
			RoundedRectangle(cornerRadius: 2, style: .continuous)
				.fill(HeatmapPalette.cellColor(level))
				.frame(width: Self.cellSize, height: Self.cellSize)
				.help("\(day.dayKey)：用电 \(day.drainedPercent)%")
		} else {
			// 窗口内但无数据的日子（没开机）留个极淡占位格
			RoundedRectangle(cornerRadius: 2, style: .continuous)
				.fill(Color.secondary.opacity(0.08))
				.frame(width: Self.cellSize, height: Self.cellSize)
		}
	}
	
	// 把用电历史按自然周排成列；每列 7 格（周日=0…周六=6），缺的天为 nil
	private static func buildColumns(_ history: [DailyUsage]) -> [[DailyUsage?]] {
		UsageCalendarLayout.buildColumns(history, weeks: weeks, today: Date(), calendar: .current)
	}
}

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

// 健康度趋势曲线：每天一个采样点，看健康度是稳还是在掉
struct HealthTrendSection: View {
	let samples: [HealthSample]
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "健康度趋势", isCollapsed: isCollapsed, onToggle: onToggle) {
				if let first = samples.first, let last = samples.last {
					// 首尾对比一眼看出变化；没掉就是好消息
					Text(first.healthPercent == last.healthPercent
						? "稳定在 \(last.healthPercent)%"
						: "\(first.healthPercent)% → \(last.healthPercent)%")
						.font(.system(size: 10, weight: .semibold).monospacedDigit())
						.foregroundStyle(last.healthPercent < first.healthPercent ? Color.orange : Color.green)
				}
			}
			
			if !isCollapsed {
				// 无预测时历史铺满全宽；有预测时历史占左侧，右侧接一段延伸到 80% 的虚线
				HealthTrendChart(samples: samples, hasProjection: projection != nil)
					.frame(height: 36)
					.padding(.top, 4)
					.accessibilityElement(children: .ignore)
					.accessibilityLabel(healthChartAccessibilityLabel)
				
				HStack {
					Text(Self.dayText(samples.first?.date))
					Spacer()
					Text(Self.dayText(samples.last?.date))
				}
				.font(.system(size: 9))
				.foregroundStyle(.tertiary)
				.padding(.top, 2)
				
				// 数据跨度够长且确实在掉时，外推一句寿命预测；
				// 悬停披露方法与不确定性——这是全应用最大胆的断言，必须答得上"凭什么"
				if let lifespanText, let projection {
					Text(lifespanText)
						.font(.system(size: 9))
						.foregroundStyle(GlassTokens.labelOnGlass)
						.padding(.top, 3)
						.help(UsagePatternAnalyzer.projectionCaveat(spanDays: projection.spanDays))
				}
			}
		}
	}
	
	// 图表纯 Canvas，VoiceOver 读不出，给个首尾健康度 + 寿命预测的朗读
	private var healthChartAccessibilityLabel: String {
		var text = "健康度趋势"
		if let first = samples.first, let last = samples.last {
			text += first.healthPercent == last.healthPercent
				? "，稳定在 \(last.healthPercent)%"
				: "，从 \(first.healthPercent)% 到 \(last.healthPercent)%"
		}
		if let lifespanText { text += "，" + lifespanText }
		return text
	}
	
	// 用首尾两点的平均掉速线性外推到 80%（苹果官方的换电池参考线）；复用 projection 避免两处公式不同步
	private var lifespanText: String? {
		guard let projection else { return nil }
		let months = Int((projection.remainingDays / 30).rounded())
		guard months >= 1 else {
			return "照此趋势快到 80% 了，可以考虑检测电池"
		}
		
		var span = ""
		if months / 12 > 0 { span += "\(months / 12) 年" }
		if months % 12 > 0 { span += "\(months % 12) 个月" }
		return "照此趋势，约 \(span)后降至 80%（官方换电池参考线）"
	}
	
	// 老化预测：外推到 80% 还需多少天；跨度不足 14 天或健康度没掉就不预测，免得拿噪声当趋势吓人
	private var projection: (remainingDays: Double, spanDays: Double)? {
		guard let first = samples.first, let last = samples.last else { return nil }
		let days = last.date.timeIntervalSince(first.date) / 86400
		guard days >= 14, first.healthPercent > last.healthPercent, last.healthPercent > 80 else { return nil }
		let declinePerDay = Double(first.healthPercent - last.healthPercent) / days
		guard declinePerDay > 0 else { return nil }
		let remainingDays = Double(last.healthPercent - 80) / declinePerDay
		return (remainingDays, days)
	}
	
	private static func dayText(_ date: Date?) -> String {
		guard let date else { return "" }
		return dayFormatter.string(from: date)
	}
	
	private static func dayText(_ date: Date) -> String {
		dayFormatter.string(from: date)
	}
	
	private static let dayFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "M月d日"
		return formatter
	}()
}

