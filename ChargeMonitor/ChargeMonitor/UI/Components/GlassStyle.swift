import SwiftUI

// 液态玻璃材质 token 与可用性感知修饰符（macOS 26 玻璃 / 15–25 原质感降级，双路径）。
// 裁决规则：玻璃让一步，可读性不让步——文本、数字、图表是内容层，永不坐在玻璃上；
// 玻璃只给外壳（一整块板）、控件（悬停/按压有弹性高光）、徽章与仪表（tint 着色）。
// 卡片在 26 上降为玻璃板上的极淡分区+发丝线，不各自成玻璃（避免"玻璃汤"）。
enum GlassMetrics {
	nonisolated static let shellCornerRadius: CGFloat = 12
	nonisolated static let cardCornerRadius: CGFloat = 12
	nonisolated static let rowCornerRadius: CGFloat = 10
}

extension View {
	/// 面板外壳：26 与控件/徽章统一为 glassEffect（同一液态玻璃材质系统），
	/// 白色 tint 作亮度地板——玻璃跟随壁纸，地板托住对比度（材质直跟壁纸实测 1.7~2.5:1 不达标）；
	/// 深色外观自适应补黑。15–25 用 regularMaterial（无玻璃 API，降级质感）
	func panelShell() -> some View { modifier(PanelShellModifier()) }

	/// 卡片分区：26 极淡填充+发丝线（内容对比度由外壳玻璃统一柔化，分区本身不再加模糊层）；
	/// 15–25 原 quaternarySystemFill+0.06 描边，观感与玻璃化之前完全一致
	func cardSection() -> some View { modifier(CardSectionModifier()) }

	/// 可交互控件玻璃：26 clear+interactive（悬停高光、按压弹性，"液态"的灵魂在反馈）；
	/// 15–25 不施玻璃，由调用方保留原悬停灰底行为
	@ViewBuilder func controlGlass(in shape: GlassControlShape = .rect) -> some View {
		if #available(macOS 26.0, *) {
			switch shape {
			case .rect:
				glassEffect(.clear.interactive(), in: .rect(cornerRadius: GlassMetrics.rowCornerRadius))
			case .circle:
				glassEffect(.clear.interactive(), in: .circle)
			}
		} else {
			self
		}
	}

	/// 仪表玻璃底：头部圆环仪表下垫 clear 玻璃圆（仪器是控件不是内容，允许上玻璃）；15–25 无
	@ViewBuilder func gaugeGlassBase() -> some View {
		if #available(macOS 26.0, *) {
			glassEffect(.clear, in: .circle)
		} else {
			self
		}
	}

	/// 头部/图表容器分区：26 与卡片同款发丝分区（它们本无容器，降级路径保持"无"以复刻原观感）
	@ViewBuilder func glassSection() -> some View {
		if #available(macOS 26.0, *) {
			cardSection()
		} else {
			self
		}
	}

	/// 着色玻璃图标块（蓝牙设备等）：26 clear+tint；15–25 原实色 16% 圆角底
	@ViewBuilder func tintedTile(_ color: Color, cornerRadius: CGFloat) -> some View {
		if #available(macOS 26.0, *) {
			glassEffect(.clear.tint(color.opacity(0.5)), in: .rect(cornerRadius: cornerRadius))
		} else {
			background(
				RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
					.fill(color.opacity(0.16))
			)
		}
	}
}

enum GlassControlShape {
	case rect, circle
}

/// "关闭"按钮样式：26 玻璃胶囊、15–25 系统淡底——曲线窗口空态用
struct CloseButtonStyle: ButtonStyle {
	@ViewBuilder
	func makeBody(configuration: Configuration) -> some View {
		if #available(macOS 26.0, *) {
			configuration.label
				.padding(.horizontal, 14)
				.padding(.vertical, 6)
				.glassEffect(.regular.interactive(), in: .capsule)
		} else {
			configuration.label
				.padding(.horizontal, 10)
				.padding(.vertical, 4)
				.background(
					RoundedRectangle(cornerRadius: 6, style: .continuous)
						.fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
				)
		}
	}
}

/// 着色玻璃徽章：26 clear 玻璃+语义色 tint（绿/红是"带信息的颜色"，tint 只染色不夺读）；
/// 15–25 原 Capsule 实色 13% 底。文字色始终用语义色本身，保证辨识度
struct GlassBadge: View {
	let color: Color
	let systemImage: String?
	let text: String

	init(symbol: String? = nil, text: String, color: Color) {
		self.systemImage = symbol
		self.text = text
		self.color = color
	}

	var body: some View {
		HStack(spacing: 3) {
			if let systemImage {
				Image(systemName: systemImage)
					.font(.system(size: 9, weight: .bold))
			}
			Text(text)
				.font(.system(size: 10.5, weight: .medium))
		}
		.foregroundStyle(color)
		.padding(.horizontal, 7)
		.padding(.vertical, 2.5)
		.modifier(BadgeBackground(color: color))
	}
}

private struct BadgeBackground: ViewModifier {
	let color: Color

	func body(content: Content) -> some View {
		if #available(macOS 26.0, *) {
			// clear 玻璃不吃淡色，tint 浓度给到 0.5 才压得住壁纸杂色
			content.glassEffect(.clear.tint(color.opacity(0.5)), in: .capsule)
		} else {
			content.background(Capsule().fill(color.opacity(0.13)))
		}
	}
}

// 面板外壳实现：玻璃 + 自适应亮度地板。浅色外观补白、深色外观补黑——
// 玻璃跟着壁纸走，地板保证黑字/白字对比度始终达标（苹果美学=液态质感，可读性=地板兜底）
private struct PanelShellModifier: ViewModifier {
	@Environment(\.colorScheme) private var colorScheme

	@ViewBuilder
	func body(content: Content) -> some View {
		if #available(macOS 26.0, *) {
			let floor: Color = colorScheme == .dark ? .black.opacity(0.35) : .white.opacity(0.4)
			content.glassEffect(.regular.tint(floor), in: .rect(cornerRadius: GlassMetrics.shellCornerRadius))
		} else {
			content.background(
				.regularMaterial,
				in: RoundedRectangle(cornerRadius: GlassMetrics.shellCornerRadius, style: .continuous)
			)
		}
	}
}

// 卡片分区的具体实现做成 ViewModifier：为了拿 @Environment——
// 「增加对比度」开启时发丝线与淡填充加倍（Apple 的可读性安全网必须接住）
private struct CardSectionModifier: ViewModifier {
	@Environment(\.colorSchemeContrast) private var contrast

	func body(content: Content) -> some View {
		let increased = contrast == .increased
		if #available(macOS 26.0, *) {
			content
				.background(
					RoundedRectangle(cornerRadius: GlassMetrics.cardCornerRadius, style: .continuous)
						.fill(Color.primary.opacity(increased ? 0.10 : 0.045))
				)
				.overlay(
					RoundedRectangle(cornerRadius: GlassMetrics.cardCornerRadius, style: .continuous)
						.strokeBorder(Color.primary.opacity(increased ? 0.22 : 0.09), lineWidth: 1)
				)
		} else {
			content
				.background(
					RoundedRectangle(cornerRadius: 10, style: .continuous)
						.fill(Color(nsColor: .quaternarySystemFill))
				)
				.overlay(
					RoundedRectangle(cornerRadius: 10, style: .continuous)
						.strokeBorder(Color.primary.opacity(increased ? 0.16 : 0.06), lineWidth: 1)
				)
		}
	}
}

/// 时段热力图配色：24 格时段图与用电日历共用同一套热力语言（此前两文件各一份逐字重复）
enum HeatmapPalette {
	// 淡绿 → 绿 → 橙，越深越耗电；0 用电极淡底
	nonisolated static func cellColor(_ level: Double) -> Color {
		if level <= 0.001 { return Color.secondary.opacity(0.12) }
		let clamped = min(max(level, 0), 1)
		let hue = 0.33 - 0.25 * clamped   // 0.33 绿 → 0.08 橙红
		return Color(hue: hue, saturation: 0.75, brightness: 0.85, opacity: 0.35 + 0.6 * clamped)
	}
}
