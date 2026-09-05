import SwiftUI

// 液态玻璃设计令牌：面板材质语言的唯一入口（macOS 26 部署目标由 build.sh 保证，无需可用性分支）。
// 卡片/按钮/徽章的材质全部在此定义，Section 只引用不内联——改观感只动这一处。
// 苹果美学的核心是用材质做层级：玻璃自带边缘高光与透底，不再需要手动发丝描边和灰底色块。
enum GlassTokens {
	// 卡片底材质：regular 玻璃，透而不喧；相邻卡片在 GlassEffectContainer 里边缘互相融合
	nonisolated static let card: Glass = .regular
	// 交互材质：悬停/按压出现镜面高光，用于控制行与可点元素
	nonisolated static let interactive: Glass = .regular.interactive()

	// 圆角体系：卡片 16、头部大卡 20、行 10——对齐系统面板量级，连续曲率
	nonisolated static let cardCornerRadius: CGFloat = 16
	nonisolated static let headerCornerRadius: CGFloat = 20
	nonisolated static let rowCornerRadius: CGFloat = 10

	// 着色玻璃：只留给语义状态（充电绿/低电红/高温橙），着色克制——tint 浓度压低，
	// 让玻璃还是玻璃，颜色只是透出来的一层情绪
	nonisolated static func tinted(_ color: Color) -> Glass {
		.regular.tint(color.opacity(0.35))
	}
}

// 着色玻璃胶囊徽章：替代旧的 Capsule().fill(color.opacity(0.13)) 色块底。
// 同一种状态语言（图标+短语），但底从"贴纸"变成"染了色的玻璃"，深浅色与桌面壁纸自动协调
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
		.glassEffect(GlassTokens.tinted(color), in: .capsule)
	}
}

// 时段热力图配色：24 格时段图与用电日历共用同一套热力语言（此前两文件各一份逐字重复）
enum HeatmapPalette {
	// 淡绿 → 绿 → 橙，越深越耗电；0 用电极淡底
	nonisolated static func cellColor(_ level: Double) -> Color {
		if level <= 0.001 { return Color.secondary.opacity(0.12) }
		let clamped = min(max(level, 0), 1)
		let hue = 0.33 - 0.25 * clamped   // 0.33 绿 → 0.08 橙红
		return Color(hue: hue, saturation: 0.75, brightness: 0.85, opacity: 0.35 + 0.6 * clamped)
	}
}
