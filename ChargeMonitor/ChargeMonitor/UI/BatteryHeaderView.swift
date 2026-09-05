import SwiftUI

// 顶部大电量数字 + 圆环仪表
struct BatteryHeaderView: View {
	let snapshot: BatterySnapshot
	let drainEstimate: DrainRateEstimate?
	let lowBatteryThreshold: Int
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
						.foregroundStyle(.secondary)
				}
				
				statusView
				
				// 打开面板最想知道的一句话：还能用多久 / 还要充多久
				if let subtitleText {
					Text(subtitleText)
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
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
		// 头部整块收进大圆角玻璃卡：它是面板上唯一"常驻置顶"的材质层，与下方卡片列拉开层级
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.glassEffect(GlassTokens.card, in: .rect(cornerRadius: GlassTokens.headerCornerRadius))
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
					.foregroundStyle(.secondary)
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
		// 圆环浮在一枚小玻璃镜片上：与头部玻璃卡形成"层中透镜"的纵深，进度弧的端点不再悬空
		.padding(3)
		.glassEffect(GlassTokens.card, in: .circle)
	}
	
	// 呼吸光点：限帧到 12fps（慢呼吸肉眼无差），模糊半径固定不变避免逐帧重算高斯模糊，
	// 呼吸只动透明度和缩放。不用 repeatForever/symbolEffect 是因为那类持续动画
	// 会以屏幕满帧率驱动整个面板视图树重算，CPU 开销大得多
	private struct ChargingBreathingDot: View {
		let color: Color
		
		var body: some View {
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
				.foregroundStyle(.secondary)
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

