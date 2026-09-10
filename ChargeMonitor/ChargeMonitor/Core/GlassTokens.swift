import SwiftUI

/// 液态玻璃表面 token：实现与可读性证明测试共用同一份数值——
/// 测试（测试/main.swift 可读性证明块）用 ReadabilityProof 证明这组参数在
/// 任意壁纸亮度全域的最坏对比度达标；改这里 = 改观感 + 改证明，同步发生。
/// 数值是材质模型近似（glassEffect 材质按 alpha 混合建模，模糊去高频不改均值）
nonisolated enum GlassTokens {
	/// 常规玻璃材质模型（近似）：glassEffect 自带材质的 (相对亮度, 透明度)
	nonisolated static func baseGlass(isDark: Bool) -> (luminance: Double, alpha: Double) {
		isDark ? (luminance: 0.05, alpha: 0.5) : (luminance: 0.85, alpha: 0.5)
	}

	/// 原生 clear 玻璃材质模型（近似，v1.24.0「液态玻璃」档）：比 regular 更透明、自身亮度贡献更小——
	/// 壁纸几乎原样参与合成（模糊去高频不改均值的近似对 clear 同样成立）
	nonisolated static func clearGlass(isDark: Bool) -> (luminance: Double, alpha: Double) {
		isDark ? (luminance: 0.10, alpha: 0.20) : (luminance: 0.90, alpha: 0.15)
	}

	/// 外壳壳层 tint：浅色补白（托住黑字）、深色补黑（压住亮壁纸保白字）。
	/// v1.24.0 材质档位：浅色液态玻璃/均衡走纯原生玻璃（tint 0），厚重补白 0.74；
	/// 深色三档以黑 tint 浓度拉开（0.76/0.70/0.82，白字 AAA 物理下限内的档差）。
	/// 26 路径即 glassEffect tint 浓度；也是 15–25/证明模型的近似叠加层。
	nonisolated static func shellFloorTint(isDark: Bool, material: PanelMaterial = .balanced) -> (luminance: Double, alpha: Double) {
		(luminance: isDark ? 0.0 : 1.0, alpha: material.floorAlpha(isDark: isDark))
	}

	/// 卡片分区填充（v1.24.0 材质化）：浅色=白纱（黑字需要亮面）、深色=黑纱（白字需要暗面）。
	/// 浓度随档位（浅 0.30/0.29/0.42，深 0.50/0.40/0.10），全部经证明表锁定。
	/// 「增加对比度」在档位浓度上加倍并钳到 0.5（仅深色厚重 0.10→0.20 不触钳）
	nonisolated static func cardSectionFill(increased: Bool, isDark: Bool, material: PanelMaterial = .balanced) -> Color {
		let alpha = min(material.cardFillAlpha(isDark: isDark) * (increased ? 2 : 1), 0.5)
		if isDark { return Color.black.opacity(alpha) }
		return Color.white.opacity(alpha)
	}

	/// 卡片填充的证明模型（与上面颜色同源：浅色白纱 lum 1.0；深色黑纱 lum 0.0）
	nonisolated static func cardSectionFillModel(increased: Bool, isDark: Bool, material: PanelMaterial = .balanced) -> (luminance: Double, alpha: Double) {
		let alpha = min(material.cardFillAlpha(isDark: isDark) * (increased ? 2 : 1), 0.5)
		if isDark { return (luminance: 0.0, alpha: alpha) }
		return (luminance: 1.0, alpha: alpha)
	}

	/// 控制行玻璃药丸的 tint（v1.24.1）：行文字坐药丸，tint 即文字的第一道墙——
	/// 浅色白 0.5（黑字最坏 12:1 AAA）、深色黑 0.9（白字最坏 8:1 AAA，证明见测试）。
	/// 药丸本体仍是 clear interactive 玻璃（控件=玻璃件，浮在壳层上，与材质档位无关）
	nonisolated static func controlPillTint(isDark: Bool) -> (luminance: Double, alpha: Double) {
		isDark ? (luminance: 0.0, alpha: 0.9) : (luminance: 1.0, alpha: 0.5)
	}

	/// 降低透明度时的不透明底（自适应外观），替代全部玻璃与地板
	nonisolated static func opaqueSurface(isDark: Bool) -> (luminance: Double, alpha: Double) {
		isDark ? (luminance: 0.03, alpha: 1.0) : (luminance: 0.87, alpha: 1.0)
	}

	/// 玻璃上的标签文字透明度：系统 secondary 在透底上最坏 2.7:1 不达 AA；
	/// primary 85% 最坏 4.5:1 达标（证明见测试）
	nonisolated static let labelOnGlassAlpha: Double = 0.85

	/// 玻璃上的标签文字色：primary 85%，随外观自适应
	nonisolated static var labelOnGlass: Color { .primary.opacity(labelOnGlassAlpha) }
}

// 液态玻璃材质 token 与可用性感知修饰符（macOS 26 玻璃 / 15–25 原质感降级，双路径）。
// 裁决规则：玻璃让一步，可读性不让步——文本、数字、图表是内容层，永不坐在玻璃上；
// 玻璃只给外壳（一整块板）、控件（悬停/按压有弹性高光）、徽章与仪表（tint 着色）。
// 卡片在 26 上降为玻璃板上的极淡分区+发丝线，不各自成玻璃（避免"玻璃汤"）。

