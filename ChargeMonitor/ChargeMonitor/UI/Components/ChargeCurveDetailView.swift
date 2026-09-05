import SwiftUI

// 充电曲线窗口的共享选择：面板点哪条记录、窗口当前该展示哪条，两边通过它同步
@MainActor
final class ChargeCurveSelection: ObservableObject {
	static let shared = ChargeCurveSelection()
	@Published var startDate: Date?
}

// 窗口宿主：按共享选择从历史记录里找会话，找到展示曲线，找不到展示空态
struct ChargeCurveWindowHost: View {
	@ObservedObject private var selection = ChargeCurveSelection.shared
	@ObservedObject private var historyRecorder: BatteryHistoryRecorder

	init(historyRecorder: BatteryHistoryRecorder) {
		self.historyRecorder = historyRecorder
	}

	var body: some View {
		if let date = selection.startDate,
		   let session = historyRecorder.recentSessions.first(where: { $0.startDate == date }) {
			ChargeCurveDetailView(
				session: session,
				history: historyRecorder.recentSessions,
				chargerName: session.chargerKey.flatMap { key in
					historyRecorder.chargerProfiles.first { $0.key == key }?.displayName
				}
			)
		} else {
			ChargeCurveEmptyView()
		}
	}
}

// 空态：要看的会话已被清理出"最近 20 条"列表（窗口还开着时列表滚动了）
struct ChargeCurveEmptyView: View {
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(spacing: 10) {
			Image(systemName: "chart.xyaxis.line")
				.font(.system(size: 28))
				.foregroundStyle(.tertiary)
			Text("这条充电记录已被清理")
				.font(.system(size: 12))
				.foregroundStyle(.secondary)
			Button("关闭") { dismiss() }
				.buttonStyle(CloseButtonStyle())
				.keyboardShortcut(.cancelAction)
		}
		.padding(20)
		.frame(width: 420, height: 240)
	}
}

// 充电会话曲线放大查看（独立窗口）：横轴经过分钟数、纵轴固定 0~100%，
// 一眼看出这次充电是先快后慢还是全程稳定，悬停可查任一点（分钟 + 电量）；
// 底部附与历史平均充速的对比（%/分钟）
struct ChargeCurveDetailView: View {
	let session: ChargeSession
	// 全部会话（用于速度对比；缺省空数组则不显示对比）
	var history: [ChargeSession] = []
	// 这次充电用的充电器展示名（会话认得出时显示）
	var chargerName: String? = nil

	@Environment(\.dismiss) private var dismiss

	// 悬停点位下标；与 SparkAreaChart 同款游标交互
	@State private var hoverIndex: Int? = nil

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
				.padding(.bottom, 12)

			// 图表容器：26 发丝分区（图表本体是内容层，绝不玻璃化）；15–25 无容器如原样
			chart
				.frame(height: 170)
				.padding(12)
				.glassSection()
				.padding(.top, 2)
				.accessibilityElement(children: .ignore)
				.accessibilityLabel(chartAccessibilityLabel)

			axisFooter
				.padding(.top, 6)

			// 与历史平均充速的对比（样本不足或时长太短时没有）
			if let comparison {
				Text(comparison)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.padding(.top, 8)
			}
		}
		.padding(20)
		.frame(width: 420)
	}

	private var comparison: String? {
		UsagePatternAnalyzer.chargeSpeedComparison(current: session, history: history)
	}

	// MARK: - 头部汇总

	private var header: some View {
		HStack(alignment: .center) {
			VStack(alignment: .leading, spacing: 3) {
				Text("充电曲线")
					.font(.system(size: 13, weight: .semibold))
				Text(summaryText)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			}

			Spacer()

			Button(action: { dismiss() }) {
				Image(systemName: "xmark")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(.secondary)
					.frame(width: 24, height: 24)
					.controlGlass(in: .circle)
			}
			.buttonStyle(.plain)
			.keyboardShortcut(.cancelAction)
			.help("关闭")
		}
	}

	// 起止电量 · 时长 · 充电器 · 峰值功率 · 时间，一行看完
	private var summaryText: String {
		var parts = ["\(session.startPercent)% → \(session.endPercent)%", "\(DurationFormatter.chinese(minutes: session.durationMinutes))"]
		if let chargerName, !chargerName.isEmpty {
			parts.append(chargerName)
		}
		if session.peakInputW >= 1 {
			parts.append(String(format: "峰值%.0fW", session.peakInputW))
		}
		parts.append(Self.dateText(session.startDate))
		return parts.joined(separator: " · ")
	}

	private var chartAccessibilityLabel: String {
		let peak = session.curve?.map(\.percent).max() ?? session.endPercent
		return "充电曲线，从 \(session.startPercent)% 到 \(session.endPercent)%，峰值 \(peak)%，共 \(session.durationMinutes) 分钟"
	}

	// MARK: - 曲线

	private var curve: [ChargePoint] {
		session.curve ?? []
	}

	// 横轴总时长：会话时长兜底（个别旧记录没有 curve 时用起止时间估一条直线）
	private var lastOffset: Int {
		curve.last?.minuteOffset ?? session.durationMinutes
	}

	private var chart: some View {
		GeometryReader { geo in
			Canvas { context, size in
				// 所有坐标映射都基于 Canvas 的 size，避免跨作用域取不到尺寸
				let points = makePoints(size: size)
				guard points.count >= 2 else { return }

				drawGridlines(context, size: size)

				var linePath = Path()
				linePath.move(to: points[0])
				for point in points.dropFirst() {
					linePath.addLine(to: point)
				}

				var fillPath = linePath
				fillPath.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
				fillPath.addLine(to: CGPoint(x: points[0].x, y: size.height))
				fillPath.closeSubpath()
				context.fill(
					fillPath,
					with: .linearGradient(
						Gradient(colors: [Color.green.opacity(0.28), Color.green.opacity(0.02)]),
						startPoint: .zero,
						endPoint: CGPoint(x: 0, y: size.height)
					)
				)
				context.stroke(linePath, with: .color(.green), lineWidth: 1.6)

				// 起点 / 终点标记
				drawMarker(context, at: points[0], color: Color.green)
				drawMarker(context, at: points[points.count - 1], color: Color.green)

				// 悬停游标（只在有真实曲线数据时提供点位详情）
				if let index = hoverIndex, index < points.count, curve.count >= 2 {
					let point = points[index]
					var cursor = Path()
					cursor.move(to: CGPoint(x: point.x, y: 2))
					cursor.addLine(to: CGPoint(x: point.x, y: size.height))
					context.stroke(cursor, with: .color(Color.green.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

					let marker = Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
					context.fill(marker, with: .color(.green))

					if let label = hoverLabel(at: index) {
						let resolved = context.resolve(
							Text(label)
								.font(.system(size: 9, weight: .medium).monospacedDigit())
								.foregroundStyle(Color.primary)
						)
						let textSize = resolved.measure(in: size)
						let bubbleWidth = textSize.width + 12
						let bubbleX = min(max(point.x - bubbleWidth / 2, 0), size.width - bubbleWidth)
						let bubbleRect = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: textSize.height + 4)
						context.fill(Path(roundedRect: bubbleRect, cornerRadius: 4), with: .color(Color.green.opacity(0.16)))
						context.draw(resolved, at: CGPoint(x: bubbleRect.midX, y: bubbleRect.midY), anchor: .center)
					}
				}
			}
			.onContinuousHover { phase in
				guard curve.count >= 2, geo.size.width > 0 else { return }
				switch phase {
				case .active(let location):
					let raw = Int((location.x / geo.size.width * CGFloat(curve.count - 1)).rounded())
					hoverIndex = min(max(raw, 0), curve.count - 1)
				case .ended:
					hoverIndex = nil
				}
			}
		}
	}

	// 真实曲线：x 按经过分钟数映射，y 固定 0~100%（不同会话可比）
	private func makePoints(size: CGSize) -> [CGPoint] {
		guard lastOffset > 0, size.width > 0, size.height > 0 else { return [] }

		func xPos(_ minute: Int) -> CGFloat {
			size.width * CGFloat(minute) / CGFloat(max(lastOffset, 1))
		}
		func yPos(_ percent: Int) -> CGFloat {
			size.height * (0.92 - 0.84 * CGFloat(percent) / 100)
		}

		// 旧记录无 curve 时：从起止电量画一条随时间线性变化的直线，也算有图可看
		if curve.count < 2 {
			return [CGPoint(x: xPos(0), y: yPos(session.startPercent)),
					CGPoint(x: xPos(lastOffset), y: yPos(session.endPercent))]
		}
		return curve.map { CGPoint(x: xPos($0.minuteOffset), y: yPos($0.percent)) }
	}

	private func hoverLabel(at index: Int) -> String? {
		guard index < curve.count else { return nil }
		let point = curve[index]
		return "第 \(point.minuteOffset) 分钟 · \(point.percent)%"
	}

	// 三条参考横线：0% / 50% / 100%
	private func drawGridlines(_ context: GraphicsContext, size: CGSize) {
		for percent in [100, 50, 0] {
			let y = size.height * (0.92 - 0.84 * CGFloat(percent) / 100)
			var line = Path()
			line.move(to: CGPoint(x: 0, y: y))
			line.addLine(to: CGPoint(x: size.width, y: y))
			context.stroke(line, with: .color(Color.primary.opacity(0.06)), lineWidth: 1)
		}

		// 充电阶段分区线：80% 进恒压、95% 进涓流——解释"为什么后段充得慢"
		for (percent, label) in [(80, "恒压 80%"), (95, "涓流 95%")] {
			let y = size.height * (0.92 - 0.84 * CGFloat(percent) / 100)
			var line = Path()
			line.move(to: CGPoint(x: 0, y: y))
			line.addLine(to: CGPoint(x: size.width, y: y))
			context.stroke(line, with: .color(Color.orange.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

			let resolved = context.resolve(
				Text(label)
					.font(.system(size: 8, weight: .medium).monospacedDigit())
					.foregroundStyle(Color.orange.opacity(0.85))
			)
			// 标注放线上方右端，不挡曲线主体
			let textSize = resolved.measure(in: size)
			context.draw(resolved, at: CGPoint(x: size.width - textSize.width / 2 - 2, y: y - textSize.height / 2 - 3), anchor: .center)
		}
	}

	private func drawMarker(_ context: GraphicsContext, at point: CGPoint, color: Color) {
		let halo = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
		context.fill(halo, with: .color(color.opacity(0.22)))
		let dot = Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
		context.fill(dot, with: .color(color))
	}

	// MARK: - 底部坐标

	private var axisFooter: some View {
		HStack {
			Text("0 分钟")
			Spacer()
			Text("\(DurationFormatter.chinese(minutes: lastOffset))")
		}
		.font(.system(size: 9))
		.foregroundStyle(.tertiary)
		.monospacedDigit()
	}

	// MARK: - 时间格式化

	private static func dateText(_ date: Date) -> String {
		let calendar = Calendar.current
		if calendar.isDateInToday(date) {
			return "今天 " + timeFormatter.string(from: date)
		}
		if calendar.isDateInYesterday(date) {
			return "昨天 " + timeFormatter.string(from: date)
		}
		return dateTimeFormatter.string(from: date)
	}

	private static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()

	private static let dateTimeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "M月d日 HH:mm"
		return formatter
	}()
}