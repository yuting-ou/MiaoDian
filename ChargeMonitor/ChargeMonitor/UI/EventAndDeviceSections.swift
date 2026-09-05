import SwiftUI

// 电源事件时间线：最近的插拔电/充满/睡眠唤醒记录，排查“电去哪了”用
struct PowerEventTimelineSection: View {
	let events: [PowerEvent]
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	private static let maxVisible = 6
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "电源事件", isCollapsed: isCollapsed, onToggle: onToggle) {
				if isCollapsed, let last = events.last {
					Text("\(Self.style(last.kind).title) \(Self.timeText(last.date))")
						.font(.system(size: 10).monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			.padding(.bottom, isCollapsed ? 0 : 2)
			
			if !isCollapsed {
				ForEach(events.suffix(Self.maxVisible).reversed()) { event in
					let style = Self.style(event.kind)
					HStack(spacing: 8) {
						Image(systemName: style.symbol)
							.font(.system(size: 10, weight: .medium))
							.symbolRenderingMode(.hierarchical)
							.foregroundStyle(style.color)
							.frame(width: 16)
						
						Text(style.title)
							.font(.system(size: PopoverLayout.bodyFontSize))
						
						Spacer(minLength: 8)
						
						Text(Self.timeText(event.date))
							.font(.system(size: 10).monospacedDigit())
							.foregroundStyle(.secondary)
					}
					.padding(.vertical, 2)
				}
			}
		}
	}
	
	private static func style(_ kind: PowerEventKind) -> (symbol: String, color: Color, title: String) {
		switch kind {
		case .pluggedIn: return ("powerplug.fill", .green, "接上电源")
		case .unplugged: return ("powerplug", .orange, "拔掉电源")
		case .chargedFull: return ("battery.100percent.bolt", .green, "充满电")
		case .sleep: return ("moon.fill", .indigo, "进入睡眠")
		case .wake: return ("sun.max.fill", .yellow, "唤醒")
		case .batteryReplaced: return ("wrench.and.screwdriver.fill", .teal, "电池更换")
		}
	}
	
	// 今天/昨天只显示时刻，更早带上日期
	private static func timeText(_ date: Date) -> String {
		let calendar = Calendar.current
		if calendar.isDateInToday(date) { return timeFormatter.string(from: date) }
		if calendar.isDateInYesterday(date) { return "昨天 " + timeFormatter.string(from: date) }
		return dateFormatter.string(from: date)
	}
	
	nonisolated private static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()
	
	nonisolated private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "M月d日 HH:mm"
		return formatter
	}()
}

// 蓝牙外设（耳机、鼠标、键盘等）电量
struct BluetoothDevicesSection: View {
	let devices: [BluetoothDeviceBattery]
	// 低电染红的阈值跟用户设置走同一条，与外设低电通知保持一致
	let lowThreshold: Int
	
	var body: some View {
		PopoverCard {
			PopoverSectionHeader("外设电量")
				.padding(.bottom, 2)
			
			ForEach(devices) { device in
				HStack(spacing: 8) {
					deviceBadge(for: device.kind)
					
					VStack(alignment: .leading, spacing: 1) {
						Text(device.name)
							.font(.system(size: PopoverLayout.bodyFontSize, weight: .medium))
							.lineLimit(1)
						
						Text(Self.kindTitle(device.kind))
							.font(.system(size: 9))
							.foregroundStyle(.secondary)
					}
					
					Spacer(minLength: 8)
					
					batteryBar(percent: device.percent)
					
					Text("\(device.percent)%")
						.font(.system(size: PopoverLayout.bodyFontSize, weight: .medium).monospacedDigit())
						.foregroundStyle(device.percent <= lowThreshold ? Color.red : Color.primary)
						.frame(width: 34, alignment: .trailing)
				}
				.padding(.vertical, 3)
			}
		}
	}
	
	// 彩色图标块，按设备类型着色：26 着色玻璃、15–25 原实色底（tintedTile 双路径）
	private func deviceBadge(for kind: BluetoothDeviceKind) -> some View {
		let style = Self.badgeStyle(kind)
		return Image(systemName: style.symbol)
			.font(.system(size: 11, weight: .semibold))
			.foregroundStyle(style.color)
			.frame(width: 24, height: 24)
			.tintedTile(style.color, cornerRadius: 7)
	}
	
	private func batteryBar(percent: Int) -> some View {
		let color: Color = percent <= lowThreshold ? .red : (percent <= 50 ? .orange : .green)
		return Capsule()
			.fill(Color.secondary.opacity(0.2))
			.frame(width: 36, height: 4)
			.overlay(alignment: .leading) {
				Capsule()
					.fill(color)
					.frame(width: 36 * CGFloat(percent) / 100)
			}
	}
	
	private static func badgeStyle(_ kind: BluetoothDeviceKind) -> (symbol: String, color: Color) {
		switch kind {
		case .mouse: return ("computermouse.fill", .blue)
		case .keyboard: return ("keyboard.fill", .purple)
		case .trackpad: return ("rectangle.and.hand.point.up.left.filled", .indigo)
		case .headphones: return ("headphones", .pink)
		case .speaker: return ("hifispeaker.fill", .orange)
		case .gamepad: return ("gamecontroller.fill", .green)
		case .phone: return ("iphone", .teal)
		case .other: return ("dot.radiowaves.left.and.right", .gray)
		}
	}
	
	private static func kindTitle(_ kind: BluetoothDeviceKind) -> String {
		switch kind {
		case .mouse: return "鼠标"
		case .keyboard: return "键盘"
		case .trackpad: return "触控板"
		case .headphones: return "耳机"
		case .speaker: return "音箱"
		case .gamepad: return "游戏手柄"
		case .phone: return "手机"
		case .other: return "蓝牙设备"
		}
	}
}

// 最近几次充电会话
struct ChargeHistorySection: View {
	let sessions: [ChargeSession]
	let isCollapsed: Bool
	let onToggle: () -> Void
	// 点按某条记录打开完整充电曲线（独立窗口，由上层负责调起）
	let onSelect: (ChargeSession) -> Void
	// 充电器身份键 → 展示名（列表行说清哪次是哪只充的）
	let chargerNames: [String: String]

	// 每行悬停态（按 startDate 区分，避免 ForEach 里逐行 @State 状态残留）
	@State private var hoveredStartDate: Date? = nil

	private static let maxVisibleSessions = 3
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "充电记录", isCollapsed: isCollapsed, onToggle: onToggle) {
				if isCollapsed, let last = sessions.last {
					Text("上次 \(last.startPercent)% → \(last.endPercent)%")
						.font(.system(size: 10).monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			.padding(.bottom, isCollapsed ? 0 : 2)
			
			if !isCollapsed {
				ForEach(sessions.suffix(Self.maxVisibleSessions).reversed()) { session in
					Button {
						onSelect(session)
					} label: {
						HStack(spacing: 8) {
							Image(systemName: "bolt.badge.clock")
								.font(.system(size: 11, weight: .medium))
								.foregroundStyle(Color.green)
								.frame(width: 16)

							// 两行式：第一行电量变化（核心信息不可被截），第二行时长·峰值·时间
							VStack(alignment: .leading, spacing: 1) {
								Text("\(session.startPercent)% → \(Text("\(session.endPercent)%").foregroundStyle(Color.green))")
									.font(.system(size: PopoverLayout.bodyFontSize, weight: .medium))
									.lineLimit(1)
								Text(Self.detail(session, chargerName: session.chargerKey.flatMap { chargerNames[$0] }))
									.font(.system(size: 9))
									.foregroundStyle(.secondary)
									.lineLimit(1)
							}

							Spacer(minLength: 6)

							// 这次充电的电量走势小图；旧记录没曲线、不足 1 分钟的闪充画不出走势，都不占位
							if let curve = session.curve, curve.count >= 2, (curve.last?.minuteOffset ?? 0) > 0 {
								ChargeSparkline(curve: curve)
									.frame(width: 30, height: 12)
							}

							Image(systemName: "chevron.right")
								.font(.system(size: 8, weight: .semibold))
								.foregroundStyle(.tertiary)
						}
						.padding(.vertical, 3)
						.padding(.horizontal, 4)
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.background(
						RoundedRectangle(cornerRadius: PopoverLayout.rowCornerRadius, style: .continuous)
							.fill(hoveredStartDate == session.startDate ? Color.primary.opacity(0.08) : .clear)
					)
					.onHover { hovering in
						hoveredStartDate = hovering ? session.startDate : nil
					}
					.help("点按查看完整充电曲线")
				}
			}
		}
	}
	
	nonisolated private static func detailText(session: ChargeSession, chargerName: String?) -> String {
		var text = "\(dateText(session.startDate)) · \(session.durationMinutes)分钟"
		if session.peakInputW >= 1 {
			text += String(format: " · 峰值%.0fW", session.peakInputW)
		}
		// 多只充电器的用户：列表行说清哪次是哪只充的（认不出/旧记录无键则省略）
		if let chargerName, !chargerName.isEmpty {
			text += " · \(chargerName)"
		}
		return text
	}

	// 供单测直测（nonisolated 静态）
	nonisolated static func detail(_ session: ChargeSession, chargerName: String? = nil) -> String {
		detailText(session: session, chargerName: chargerName)
	}
	
	// 时间戳人性化：今天/昨天只显示时刻，更早才显示日期
	nonisolated private static func dateText(_ date: Date) -> String {
		let calendar = Calendar.current
		if calendar.isDateInToday(date) {
			return "今天 " + timeFormatter.string(from: date)
		}
		if calendar.isDateInYesterday(date) {
			return "昨天 " + timeFormatter.string(from: date)
		}
		return dateFormatter.string(from: date)
	}
	
	nonisolated private static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()
	
	nonisolated private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "MM-dd HH:mm"
		return formatter
	}()
}

// 充电会话的迷你电量曲线：横轴时间、纵轴电量，一眼看出充得快慢
struct ChargeSparkline: View {
	let curve: [ChargePoint]
	
	var body: some View {
		Canvas { context, size in
			guard curve.count >= 2, let lastOffset = curve.last?.minuteOffset, lastOffset > 0 else { return }
			
			// 纵轴固定 0~100%，不同会话之间高度可比：充 40→80 的图就是比 70→80 的“高一截”
			let points = curve.map { point -> CGPoint in
				let x = size.width * CGFloat(point.minuteOffset) / CGFloat(lastOffset)
				let y = size.height * (1 - CGFloat(point.percent) / 100)
				return CGPoint(x: x, y: y)
			}
			
			var linePath = Path()
			linePath.move(to: points[0])
			for point in points.dropFirst() {
				linePath.addLine(to: point)
			}
			
			var fillPath = linePath
			fillPath.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
			fillPath.addLine(to: CGPoint(x: points[0].x, y: size.height))
			fillPath.closeSubpath()
			
			context.fill(fillPath, with: .color(Color.green.opacity(0.18)))
			context.stroke(linePath, with: .color(Color.green.opacity(0.9)), lineWidth: 1)
		}
	}
}

