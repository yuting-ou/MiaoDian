import SwiftUI

// 最近 5 分钟的功耗迷你曲线（平滑 + 渐变填充，悬停可查每个时刻的功率）
struct PowerChartSection: View {
	let samples: [PowerSample]
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "功耗曲线", isCollapsed: isCollapsed, onToggle: onToggle) {
				// 当前功率是最受关注的数字，用主色突出；峰值作为参照置于后
				// 此值每 2 秒刷新，转场用淡入淡出而非 numericText，避免插值字形位图持续堆积
				Text(currentText)
					.font(.system(size: 10, weight: .semibold).monospacedDigit())
					.foregroundStyle(Color.accentColor)
					.contentTransition(.opacity)
					.animation(.easeInOut(duration: 0.3), value: currentText)
				Text(peakText)
					.font(.system(size: 10).monospacedDigit())
					.foregroundStyle(.secondary)
			}
			
			if !isCollapsed {
				SparkAreaChart(
					values: samples.map(\.watts),
					color: .accentColor,
					minRange: 0.5,
					bandBottom: 0.94,
					bandHeight: 0.86,
					hoverLabel: { index in
						String(format: "%@ · %.1fW", Self.timeText(samples[index].date), samples[index].watts)
					}
				)
				.frame(height: 40)
				.padding(.top, 4)
				// 曲线是纯 Canvas，VoiceOver 读不出；给个概括当前/峰值的朗读
				.accessibilityElement(children: .ignore)
				.accessibilityLabel("功耗曲线，\(currentText)，\(peakText.replacingOccurrences(of: "· ", with: ""))")
			}
		}
	}
	
	private var currentText: String {
		String(format: "当前%.1fW", samples.last?.watts ?? 0)
	}
	
	private var peakText: String {
		let peak = samples.map(\.watts).max() ?? 0
		return String(format: "· 峰值%.1fW", peak)
	}
	
	private static func timeText(_ date: Date) -> String {
		timeFormatter.string(from: date)
	}
	
	private static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm:ss"
		return formatter
	}()
}

// 最近 30 分钟的温度迷你曲线，画法与功耗曲线同款，换橙色调
struct TemperatureChartSection: View {
	let samples: [TemperatureSample]
	let thresholdC: Int
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "温度曲线", isCollapsed: isCollapsed, onToggle: onToggle) {
				// 当前温度超警示线时整个数字变红，不只是淡淡染色
				Text(currentText)
					.font(.system(size: 10, weight: .semibold).monospacedDigit())
					.foregroundStyle(isOverThreshold ? Color.red : Color.orange)
					.contentTransition(.opacity)
					.animation(.easeInOut(duration: 0.3), value: currentText)
				Text(peakText)
					.font(.system(size: 10).monospacedDigit())
					.foregroundStyle(.secondary)
			}
			
			if !isCollapsed {
				SparkAreaChart(
					values: samples.map(\.celsius),
					color: .orange,
					// 温度波动往往只有零点几度，range 给下限免得微小抖动被拉成大起大落
					minRange: 1.0,
					hoverLabel: { index in
						String(format: "%@ · %.1f°C", Self.timeText(samples[index].date), samples[index].celsius)
					}
				)
				.frame(height: 36)
				.padding(.top, 4)
				.accessibilityElement(children: .ignore)
				.accessibilityLabel("温度曲线，\(currentText)\(isOverThreshold ? "，超过警示线" : "")")
			}
		}
	}
	
	private var isOverThreshold: Bool {
		(samples.last?.celsius ?? 0) >= Double(thresholdC)
	}
	
	private var currentText: String {
		String(format: "当前%.1f°C", samples.last?.celsius ?? 0)
	}
	
	private var peakText: String {
		String(format: "· 峰值%.1f°C", samples.map(\.celsius).max() ?? 0)
	}
	
	private static func timeText(_ date: Date) -> String {
		timeFormatter.string(from: date)
	}
	
	private static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()
}

// 电池体检：四项加权出一个总分，一眼看电池状态
struct BatteryCheckupSection: View {
	let checkup: BatteryCheckup
	
	var body: some View {
		PopoverCard {
			HStack(spacing: 8) {
				ZStack {
					Circle()
						.stroke(color.opacity(0.15), lineWidth: 3)
					Circle()
						.trim(from: 0, to: CGFloat(checkup.score) / 100)
						.stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
						.rotationEffect(.degrees(-90))
					Text("\(checkup.score)")
						.font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
						.foregroundStyle(color)
				}
				.frame(width: 30, height: 30)
				
				VStack(alignment: .leading, spacing: 1) {
					Text("电池体检")
						.font(.system(size: 11, weight: .semibold))
						.foregroundStyle(.secondary)
					Text(checkup.verdict)
						.font(.system(size: PopoverLayout.bodyFontSize, weight: .medium))
				}
				
				Spacer(minLength: 0)
			}
			.padding(.vertical, 1)
			.help("综合健康度、循环次数、温度与充电习惯的加权评分")
		}
	}
	
	private var color: Color {
		switch checkup.tier {
		case .excellent: return .green
		case .good: return .teal
		case .aging: return .orange
		case .poor: return .red
		}
	}
}

// 24 小时电量走势：充电段绿色、放电段主题色，断档（关机/长睡）不连线
struct SOCChartSection: View {
	let samples: [SOCSample]
	let lowThreshold: Int
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	@State private var hoverX: CGFloat? = nil
	// 悬停所在画布的实际宽度（标题栏取最近采样点要用，画布外拿不到）
	@State private var canvasWidth: CGFloat = 0
	
	private static let windowSeconds: TimeInterval = 24 * 3600
	// 相邻采样间隔超过这个值视为断档，不连线
	private static let gapSeconds: TimeInterval = 45 * 60
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "24小时电量", isCollapsed: isCollapsed, onToggle: onToggle) {
				if let hoverText {
					Text(hoverText)
						.font(.system(size: 10, weight: .semibold).monospacedDigit())
						.foregroundStyle(Color.accentColor)
				} else if let last = samples.last {
					Text("现在 \(last.percent)%")
						.font(.system(size: 10, weight: .semibold).monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			
			if !isCollapsed {
				GeometryReader { geo in
					chartCanvas(width: geo.size.width)
						.onContinuousHover { phase in
							switch phase {
							case .active(let location):
								hoverX = location.x
								canvasWidth = geo.size.width
							case .ended: hoverX = nil
							}
						}
						.frame(width: geo.size.width)
				}
				.frame(height: 44)
				.padding(.top, 4)
				.accessibilityElement(children: .ignore)
				.accessibilityLabel("24小时电量走势，现在 \(samples.last?.percent ?? 0)%")
				
				HStack {
					Text(Self.axisFormatter.string(from: Date().addingTimeInterval(-Self.windowSeconds)))
					Spacer()
					Text("现在")
				}
				.font(.system(size: 9))
				.foregroundStyle(.tertiary)
				.padding(.top, 2)
			}
		}
	}
	
	// 悬停处最近的采样点（用于标题栏展示“时刻 · 电量”）；宽度由调用方传入
	private func hoverSample(width: CGFloat) -> SOCSample? {
		guard let x = hoverX, width > 0 else { return nil }
		let start = Date().addingTimeInterval(-Self.windowSeconds)
		let target = start.addingTimeInterval(Self.windowSeconds * x / width)
		return samples.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
	}
	
	// 标题栏的悬停文字：用画布实际宽度换算最近采样点，与游标同一套定位；
	// 宽度未知（悬停刚落进画布、还没跑到闭包）时退回不显示，由“现在 X%”顶上
	private var hoverText: String? {
		guard hoverX != nil, canvasWidth > 0, let sample = hoverSample(width: canvasWidth) else { return nil }
		return "\(Self.axisFormatter.string(from: sample.date)) · \(sample.percent)%"
	}
	
	private func chartCanvas(width: CGFloat) -> some View {
		Canvas { context, size in
			let now = Date()
			let start = now.addingTimeInterval(-Self.windowSeconds)
			let hovered = hoverSample(width: size.width)
			
			func xPos(_ date: Date) -> CGFloat {
				size.width * CGFloat(date.timeIntervalSince(start) / Self.windowSeconds)
			}
			func yPos(_ percent: Int) -> CGFloat {
				size.height * (0.95 - 0.9 * CGFloat(percent) / 100)
			}
			
			// 低电警示线：淡红色虚线参照
			var thresholdLine = Path()
			thresholdLine.move(to: CGPoint(x: 0, y: yPos(lowThreshold)))
			thresholdLine.addLine(to: CGPoint(x: size.width, y: yPos(lowThreshold)))
			context.stroke(thresholdLine, with: .color(Color.red.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
			
			// 按“时间断档 / 充电状态翻转”切分段落，充电段绿色、放电段主题色
			var runs: [[SOCSample]] = []
			var current: [SOCSample] = []
			for sample in samples {
				if let last = current.last,
				   sample.date.timeIntervalSince(last.date) > Self.gapSeconds || last.isCharging != sample.isCharging {
					// 状态翻转时把前一点也塞进新段，曲线才衔接不断口（断档除外）
					runs.append(current)
					current = sample.date.timeIntervalSince(last.date) > Self.gapSeconds ? [] : [last]
				}
				current.append(sample)
			}
			if !current.isEmpty { runs.append(current) }
			
			for run in runs where run.count >= 2 {
				let color: Color = (run.last?.isCharging ?? false) ? .green : .accentColor
				var line = Path()
				line.move(to: CGPoint(x: xPos(run[0].date), y: yPos(run[0].percent)))
				for sample in run.dropFirst() {
					line.addLine(to: CGPoint(x: xPos(sample.date), y: yPos(sample.percent)))
				}
				
				var fill = line
				fill.addLine(to: CGPoint(x: xPos(run[run.count - 1].date), y: size.height))
				fill.addLine(to: CGPoint(x: xPos(run[0].date), y: size.height))
				fill.closeSubpath()
				context.fill(
					fill,
					with: .linearGradient(
						Gradient(colors: [color.opacity(0.18), color.opacity(0.02)]),
						startPoint: .zero,
						endPoint: CGPoint(x: 0, y: size.height)
					)
				)
				context.stroke(line, with: .color(color), lineWidth: 1.5)
			}
			
			// 末端当前点
			if let last = samples.last {
				let point = CGPoint(x: xPos(last.date), y: yPos(last.percent))
				let color: Color = last.isCharging ? .green : .accentColor
				context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(color.opacity(0.25)))
				context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(color))
			}
			
			// 悬停游标
			if let sample = hovered {
				let x = xPos(sample.date)
				var cursor = Path()
				cursor.move(to: CGPoint(x: x, y: 0))
				cursor.addLine(to: CGPoint(x: x, y: size.height))
				context.stroke(cursor, with: .color(Color.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
				let marker = Path(ellipseIn: CGRect(x: x - 2.5, y: yPos(sample.percent) - 2.5, width: 5, height: 5))
				context.fill(marker, with: .color(sample.isCharging ? .green : .accentColor))
			}
		}
	}
	
	private static let axisFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()
}

