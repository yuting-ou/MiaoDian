import SwiftUI

// 顶部大电量数字 + 圆环仪表
struct BatteryHeaderView: View {
	let snapshot: BatterySnapshot
	let drainEstimate: DrainRateEstimate?
	let lowBatteryThreshold: Int
	// 高温预警边框阈值（°C，v1.23.0 警示通道）：与高温提醒同一用户设置，不另造第二套
	var hotTemperatureThreshold: Int = 40
	// 宽面板时传入体检评分，展在头部右侧的空白区；窄面板为 nil、体检仍走卡片
	var checkup: BatteryCheckup? = nil
	
	var body: some View {
		HStack(spacing: 12) {
			gauge
				.accessibilityHidden(true)   // 圆环仅装饰，信息已并入下方文字的组合朗读
			
			VStack(alignment: .leading, spacing: 3) {
				HStack(alignment: .firstTextBaseline, spacing: 2) {
					Text(percentDisplay)
						.font(.system(size: 27, weight: .bold, design: .rounded))
						// 与信息行同一结论：numericText 插值字形持续吃内存，转场用淡入淡出
						.contentTransition(.opacity)
						.animation(.easeInOut(duration: 0.3), value: percentDisplay)
					Text("%")
						.font(.system(size: 15, weight: .semibold, design: .rounded))
						.foregroundStyle(GlassTokens.labelOnGlass)
				}
				
				statusView
				
				// 打开面板最想知道的一句话：还能用多久 / 还要充多久
				if let subtitleText {
					Text(subtitleText)
						.font(.system(size: 10))
						.foregroundStyle(GlassTokens.labelOnGlass)
						.lineLimit(1)
						.minimumScaleFactor(0.8)
				}
			}
			// 左侧一组（电量/状态/续航）合并为一句朗读，免得 VoiceOver 逐个小元素念得很碎
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(headerAccessibilityLabel)
			
			Spacer(minLength: 0)
			
			// 宽面板头部右侧：体检小圆环 + 评语，填上以前空着的一大块
			if let checkup {
				headerCheckup(checkup)
					.accessibilityElement(children: .ignore)
					.accessibilityLabel("电池体检 \(checkup.score) 分，\(checkup.verdict)")
			}
		}
		// 头部容器：26 上与卡片同款发丝分区（头部是内容不是控件，不单独成玻璃）；
		// 15–25 保持原裸排无底，降级观感与玻璃化之前一致
		.modifier(HeaderSection())
		// 警示通道（v1.23.0）：高温时头部外缘橙色预警边框，脉冲急促度随温度连续加快；
		// 低电呼吸挂在圆环内部（见 gaugeInterior），文字永不参与呼吸
		.modifier(HeatAlertBorder(snapshot: snapshot, thresholdC: hotTemperatureThreshold))
	}

	// 警示通道用的 mood（与 gaugeInterior 同一解析结果，一处解析两处消费）；
	// 调试注入优先（仅视觉层，不碰数据与记录）
	private var fillMoodForWarning: BatteryFillMood {
		switch DebugVisualForce.current {
		case .charging, .hotCharging: return .charging
		case .low: return .lowBattery
		case .none, .hot: break
		}
		return BatteryVisualResolver.fillMood(
			isCharging: snapshot.isCharging,
			isFull: snapshot.isFull,
			onBatteryPower: snapshot.powerSource == .battery,
			socPercent: snapshot.stateOfChargePercent,
			lowBatteryThreshold: lowBatteryThreshold
		)
	}
	
	// 头部组合朗读：电量 + 状态 + 续航，拼成一句自然语句
	private var headerAccessibilityLabel: String {
		var parts = ["电量 \(snapshot.stateOfChargePercent.map { "\($0)%" } ?? "—")", statusText]
		if snapshot.isLowPowerModeEnabled { parts.append("低电量模式") }
		if let subtitleText { parts.append(subtitleText) }
		return parts.joined(separator: "，")
	}
	
	// 头部版体检徽章：环形进度 + 中心分数 + 右侧评语
	private func headerCheckup(_ checkup: BatteryCheckup) -> some View {
		HStack(spacing: 7) {
			ZStack {
				Circle()
					.stroke(checkupColor(checkup.score).opacity(0.15), lineWidth: 3)
				Circle()
					.trim(from: 0, to: CGFloat(checkup.score) / 100)
					.stroke(checkupColor(checkup.score), style: StrokeStyle(lineWidth: 3, lineCap: .round))
					.rotationEffect(.degrees(-90))
				Text("\(checkup.score)")
					.font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
					.foregroundStyle(checkupColor(checkup.score))
			}
			.frame(width: 34, height: 34)
			
			VStack(alignment: .leading, spacing: 1) {
				Text("电池体检")
					.font(.system(size: 9))
					.foregroundStyle(GlassTokens.labelOnGlass)
				Text(checkup.verdict)
					.font(.system(size: 10.5, weight: .medium))
					.foregroundStyle(.primary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(width: 92, alignment: .leading)
		}
		.help("综合健康度、循环次数、温度与高电量驻留的加权评分")
	}
	
	private func checkupColor(_ score: Int) -> Color {
		switch BatteryCheckup.tier(for: score) {
		case .excellent: return .green
		case .good: return .teal
		case .aging: return .orange
		case .poor: return .red
		}
	}
	
	private var percentFraction: CGFloat {
		CGFloat(snapshot.stateOfChargePercent ?? 0) / 100
	}

	// 没读到数据时用"—"占位，与菜单栏的"—%"同一语言，不误显示成 0%
	private var percentDisplay: String {
		snapshot.stateOfChargePercent.map(String.init) ?? "—"
	}
	
	private var gaugeColor: Color {
		if snapshot.isCharging || snapshot.isFull { return .green }
		if (snapshot.stateOfChargePercent ?? 100) <= lowBatteryThreshold { return .red }
		return .accentColor
	}
	
	private var gauge: some View {
		ZStack {
			Circle()
				.stroke(gaugeColor.opacity(0.15), lineWidth: 4.5)

			// 填充通道（v1.22.0）：圆环内部的氛围层——充电波浪 / 静息渐变，解析器驱动
			gaugeInterior

			// 进度弧：沿弧线方向由淡到浓的角度渐变，更有质感
			Circle()
				.trim(from: 0, to: max(0.02, percentFraction))
				.stroke(
					AngularGradient(
						colors: [gaugeColor.opacity(0.45), gaugeColor],
						center: .center,
						startAngle: .degrees(0),
						endAngle: .degrees(360 * percentFraction)
					),
					style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
				)
				.rotationEffect(.degrees(-90))
				.animation(.easeOut(duration: 0.4), value: percentFraction)
			
			// 充电且未充满时：进度弧尽头一颗呼吸光点，克制不喧闹
			// 充满后光点停在 12 点钟方向持续呼吸没意义，不再显示
			if snapshot.isCharging && !snapshot.isFull {
				ChargingBreathingDot(color: gaugeColor)
					.offset(y: -23)
					.rotationEffect(.degrees(360 * percentFraction))
			}
			
			Image(systemName: centerSymbol)
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(gaugeColor)
		}
		.frame(width: 46, height: 46)
		// 圆环浮在一枚小玻璃镜片上（仪表属控件层，允许上玻璃）；15–25 无
		.padding(3)
		.gaugeGlassBase()
	}

	// 填充通道（v1.22.0）：圆环内部的氛围层，BatteryVisualResolver 四态驱动。
	// 充电 = 波浪液面（周期随瞬时功率）；其余 = 静息底色渐变（事件过渡，无常驻动效）。
	// 「减少动态效果」：波浪静止为平液面，不退场——静态语义仍在，动效让步。
	private var gaugeInterior: some View {
		ZStack {
			Circle()
				.fill(moodBaseGradient(fillMoodForWarning))
			if fillMoodForWarning == .charging {
				ChargingWaveFill(color: gaugeColor,
								 period: BatteryVisualResolver.wavePeriod(chargingPowerW: snapshot.chargingPowerW),
								 level: percentFraction)
			}
		}
		.animation(.easeInOut(duration: 0.35), value: fillMoodForWarning)
		// 低电轻呼吸（v1.23.0）：只呼吸圆环内的底色层，文字与大数字永不参与
		.modifier(LowPowerBreath(active: fillMoodForWarning == .lowBattery))
	}

	// 各态底色：正常/低电用各自语义色的极淡渐变（液面从下往上涨的隐喻），
	// 充电/充满绿色。低电走暖橙→红渐变（v1.23.0 警示语言）。
	// 不透明度上限取解析器令牌（证明测试同源）：常态 ≤0.16，必须比动效态安静
	private func moodBaseGradient(_ mood: BatteryFillMood) -> LinearGradient {
		switch mood {
		case .calm:
			return LinearGradient(
				colors: [Color.accentColor.opacity(0.10), Color.accentColor.opacity(BatteryVisualResolver.calmBaseMaxAlpha)],
				startPoint: .top, endPoint: .bottom
			)
		case .full, .charging:
			return LinearGradient(
				colors: [Color.green.opacity(0.10), Color.green.opacity(BatteryVisualResolver.calmBaseMaxAlpha)],
				startPoint: .top, endPoint: .bottom
			)
		case .lowBattery:
			return LinearGradient(
				colors: [Color.orange.opacity(0.12), Color.red.opacity(BatteryVisualResolver.calmBaseMaxAlpha)],
				startPoint: .top, endPoint: .bottom
			)
		}
	}
	
	// 呼吸光点：限帧到 12fps（慢呼吸肉眼无差），模糊半径固定不变避免逐帧重算高斯模糊，
	// 呼吸只动透明度和缩放。不用 repeatForever/symbolEffect 是因为那类持续动画
	// 会以屏幕满帧率驱动整个面板视图树重算，CPU 开销大得多。
	// 「减少动态效果」：光点静止呈现（无 TimelineView 持续帧），不得有残留动画
	private struct ChargingBreathingDot: View {
		let color: Color
		@Environment(\.accessibilityReduceMotion) private var reduceMotion
		
		var body: some View {
			if reduceMotion {
				Circle()
					.fill(.white)
					.frame(width: 4.5, height: 4.5)
					.shadow(color: color, radius: 3)
					.opacity(0.8)
			} else {
				TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
					let time = context.date.timeIntervalSinceReferenceDate
					let breathe = 0.5 + 0.5 * sin(time * 2 * .pi / 1.8)
					Circle()
						.fill(.white)
						.frame(width: 4.5, height: 4.5)
						.shadow(color: color, radius: 3)
						.opacity(0.55 + 0.45 * breathe)
						.scaleEffect(0.9 + 0.25 * breathe)
				}
			}
		}
	}
	
	// 充电/充满用绿色胶囊徽章，低电量用红色胶囊警示，其余状态保持素雅文字
	@ViewBuilder
	private var statusView: some View {
		if snapshot.isCharging || snapshot.isFull {
			statusBadge(
				symbol: snapshot.isFull ? "checkmark.circle.fill" : "bolt.fill",
				text: statusText,
				color: .green
			)
		} else if isLowBattery {
			// 和菜单栏变红、低电量通知同一套警示语言，阈值统一走用户设置
			statusBadge(
				symbol: "exclamationmark.triangle.fill",
				text: "电量偏低",
				color: .red
			)
		} else {
			Text(plainStatusText)
				.font(.system(size: 11))
				.foregroundStyle(GlassTokens.labelOnGlass)
		}
	}
	
	private func statusBadge(symbol: String, text: String, color: Color) -> some View {
		// 着色玻璃胶囊：状态色从"贴纸色块"变成"染色的玻璃"，深浅色与桌面自动协调
		GlassBadge(symbol: symbol, text: text, color: color)
	}
	
	private var isLowBattery: Bool {
		snapshot.powerSource == .battery && (snapshot.stateOfChargePercent ?? 100) <= lowBatteryThreshold
	}
	
	private var centerSymbol: String {
		if snapshot.isCharging { return "bolt.fill" }
		if snapshot.powerSource == .powerAdapter { return "powerplug.fill" }
		return "minus.plus.batteryblock.fill"
	}
	
	private var statusText: String {
		if snapshot.isFull { return "已充满 · 电源适配器" }
		if snapshot.isCharging { return snapshot.isFastCharging ? "正在快充" : "正在充电" }
		if snapshot.powerSource == .powerAdapter { return "已接通电源 · 未充电" }
		return "正在使用电池"
	}
	
	// 状态是素雅文字时，低电量模式直接拼在后面
	private var plainStatusText: String {
		snapshot.isLowPowerModeEnabled ? statusText + " · 低电量模式" : statusText
	}
	
	// 状态是胶囊徽章时（充电/充满/低电量），徽章里装不下低电量模式，挪到副标题行
	private var showsStatusBadge: Bool {
		snapshot.isCharging || snapshot.isFull || isLowBattery
	}
	
	// 副标题行：续航一句话 + 低电量模式标记
	private var subtitleText: String? {
		var parts: [String] = []
		if let remainingText { parts.append(remainingText) }
		if snapshot.isLowPowerModeEnabled && showsStatusBadge { parts.append("低电量模式") }
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}
	
	// 头部一句话续航：充电看还要多久充满，用电池看还能撑多久，都附上具体时刻
	// 系统估算没出来时（刚拔插常见），用最近一小时掉电速度兜底
	private var remainingText: String? {
		if snapshot.isCharging, !snapshot.isFull,
		   let minutes = snapshot.timeToFullChargeMinutes, minutes > 0 {
			return "约 \(DurationFormatter.chinese(minutes: minutes)) 后充满（\(DurationFormatter.clockText(afterMinutes: minutes))）"
		}
		if snapshot.powerSource == .battery, !snapshot.isCharging {
			if let minutes = snapshot.timeToEmptyMinutes, minutes > 0 {
				return "预计还能用 \(DurationFormatter.chinese(minutes: minutes))（到 \(DurationFormatter.clockText(afterMinutes: minutes))）"
			}
			if let minutes = drainEstimate?.estimatedMinutesRemaining, minutes > 0 {
				return "预计还能用 \(DurationFormatter.chinese(minutes: minutes))（到 \(DurationFormatter.clockText(afterMinutes: minutes))）"
			}
		}
		return nil
	}
}

// 充电波浪液面（v1.22.0）：液位 = 真实电量占比（视觉有出处，不许装饰说谎），
// 波面正弦涌动。限帧 12fps（与呼吸光点同纪律）；纯几何位移，无模糊无 repeatForever；
// 「减少动态效果」退化为静止波面（同一液位同一语义色，只让步动效不让步信息）
private struct ChargingWaveFill: View {
	let color: Color
	let period: Double
	let level: CGFloat   // 0...1 水位 = 电量占比
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		Group {
			if reduceMotion {
				waveCanvas(phase: .pi / 3)
			} else {
				TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
					let time = context.date.timeIntervalSinceReferenceDate
					waveCanvas(phase: (time / period) * 2 * .pi)
				}
			}
		}
		.clipShape(Circle())
	}

	// 主波 + 错相淡波：两层错相制造"液面厚度"，淡波频率取负制造反向流动视差
	private func waveCanvas(phase: Double) -> some View {
		Canvas { context, size in
			let surfaceY = size.height * (1 - level * 0.92) - 1
			let main = wavePath(size: size, surfaceY: surfaceY, amplitude: 1.6, waveNumber: 0.05, phase: phase)
			context.fill(
				main,
				with: .linearGradient(
					Gradient(colors: [color.opacity(0.14), color.opacity(BatteryVisualResolver.waveFillMaxAlpha)]),
					startPoint: CGPoint(x: 0, y: surfaceY),
					endPoint: CGPoint(x: 0, y: size.height)
				)
			)
			let echo = wavePath(size: size, surfaceY: surfaceY + 1.4, amplitude: 1.0, waveNumber: -0.032, phase: phase * 0.7)
			context.fill(echo, with: .color(color.opacity(0.10)))
		}
	}

	private func wavePath(size: CGSize, surfaceY: CGFloat, amplitude: CGFloat, waveNumber: Double, phase: Double) -> Path {
		var path = Path()
		path.move(to: CGPoint(x: 0, y: surfaceY))
		var x: CGFloat = 0
		while x <= size.width {
			let y = surfaceY + amplitude * CGFloat(sin(phase + Double(x) * waveNumber))
			path.addLine(to: CGPoint(x: x, y: y))
			x += 2
		}
		path.addLine(to: CGPoint(x: size.width, y: size.height))
		path.addLine(to: CGPoint(x: 0, y: size.height))
		path.closeSubpath()
		return path
	}
}

// 高温预警边框（v1.23.0 警示通道）：头部外缘橙色描边，脉冲节奏随温度急促度连续加快
// （急促度 1.0 → 1.6s/拍，2.0 → 0.8s/拍）。阈值与迟滞全部走 BatteryVisualResolver
// （与高温提醒同一用户设置）；温度缺失 = 不警示；「减少动态效果」退化为静息描边。
// 调试注入口（--miao-visual=hot / hot-charging）强制显示，v2.0.0 移除
private struct HeatAlertBorder: ViewModifier {
	let snapshot: BatterySnapshot
	let thresholdC: Int
	@State private var heatShowing = false
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	// 调试注入：hot / hot-charging 强制显示边框（演示急促度取 1.5 中档）
	private var forced: Bool {
		switch DebugVisualForce.current {
		case .hot, .hotCharging: return true
		default: return false
		}
	}

	private var showing: Bool { forced || heatShowing }

	// 急促度：真实温度过阈值走解析器；调试注入固定 1.5 中档
	private var urgency: Double {
		forced ? 1.5 : (BatteryVisualResolver.temperatureUrgency(tempC: snapshot.temperatureC, thresholdC: Double(thresholdC)) ?? 1.0)
	}

	func body(content: Content) -> some View {
		content
			.overlay {
				if showing {
					warningStroke
				}
			}
			.onChange(of: snapshot.temperatureC) {
				heatShowing = BatteryVisualResolver.shouldWarnHeat(
					tempC: snapshot.temperatureC,
					thresholdC: Double(thresholdC),
					wasShowing: heatShowing
				)
			}
			.onAppear {
				heatShowing = BatteryVisualResolver.shouldWarnHeat(
					tempC: snapshot.temperatureC,
					thresholdC: Double(thresholdC),
					wasShowing: heatShowing
				)
			}
	}

	@ViewBuilder
	private var warningStroke: some View {
		let period = BatteryVisualResolver.heatPulseBasePeriod / urgency
		if reduceMotion {
			borderShape.opacity(0.55)
		} else {
			TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
				let t = context.date.timeIntervalSinceReferenceDate
				let breathe = 0.5 + 0.5 * sin(t * 2 * .pi / period)
				borderShape.opacity(0.30 + 0.28 * breathe)
			}
		}
	}

	// 与头部玻璃分区同族圆角（26 玻璃路径 12 / 15–25 裸排 10）；发丝细线宽——警示靠节奏不靠蛮力
	@ViewBuilder
	private var borderShape: some View {
		if #available(macOS 26.0, *) {
			RoundedRectangle(cornerRadius: GlassMetrics.cardCornerRadius, style: .continuous)
				.strokeBorder(Color.orange, lineWidth: 1.5)
		} else {
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.strokeBorder(Color.orange, lineWidth: 1.5)
		}
	}
}

// 低电呼吸（v1.23.0 警示通道）：低电态下圆环内底色轻呼吸（透明度微幅波动），
// 周期 2.2s 比充电光点更慢更沉——提醒而非催促。「减少动态效果」退静止。
// 调试注入口（--miao-visual=low）强制显示，v2.0.0 移除
private struct LowPowerBreath: ViewModifier {
	let active: Bool
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private var forcedActive: Bool {
		DebugVisualForce.current == .low ? true : active
	}

	func body(content: Content) -> some View {
		if forcedActive, !reduceMotion {
			content
				.modifier(BreathPulse(period: BatteryVisualResolver.lowBreathPeriod))
		} else {
			content
		}
	}
}

// 通用呼吸脉冲：整层透明度 0.75↔1.0 微幅波动（只动 opacity，不动几何不重排）
private struct BreathPulse: ViewModifier {
	let period: Double
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func body(content: Content) -> some View {
		if reduceMotion {
			content
		} else {
			TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
				let t = context.date.timeIntervalSinceReferenceDate
				let breathe = 0.5 + 0.5 * sin(t * 2 * .pi / period)
				content.opacity(0.75 + 0.25 * breathe)
			}
		}
	}
}

// 头部容器双路径：26 玻璃板上的发丝分区，15–25 原裸排（仅水平 4pt 内边距）
private struct HeaderSection: ViewModifier {
	func body(content: Content) -> some View {
		if #available(macOS 26.0, *) {
			content
				.padding(.horizontal, 12)
				.padding(.vertical, 10)
				.frame(maxWidth: .infinity, alignment: .leading)
				.glassSection()
		} else {
			content.padding(.horizontal, 4)
		}
	}
}

