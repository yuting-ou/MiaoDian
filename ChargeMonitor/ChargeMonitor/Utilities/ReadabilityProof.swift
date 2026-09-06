import SwiftUI

/// 可读性证明纯函数组（WCAG 2.x 对比度模型 + 玻璃合成的亮度近似）。
/// 近似声明：材质的高斯模糊去高频不改均值，对"亮度分离度"判定是保守近似；
/// 玻璃对壁纸的合成按线性 alpha 混合建模（sRGB）。所有亮度均为 WCAG 相对亮度。
/// 用途：表面 token × 文字色 × 外观 × 辅助开关 的最坏情况对比度证明——
/// 对任意壁纸亮度成立（解析取端点，不依赖截图抽查），纳入测试门无人值守可跑。
nonisolated enum ReadabilityProof {
	/// WCAG 相对亮度（sRGB 通道线性化后加权）
	nonisolated static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
		func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
		return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
	}

	/// 单层玻璃（自身相对亮度 L、透明度 α）压在壁纸亮度 t 上的合成亮度
	nonisolated static func compositedLuminance(glassLuminance: Double, glassAlpha: Double, backdropLuminance: Double) -> Double {
		glassAlpha * glassLuminance + (1 - glassAlpha) * backdropLuminance
	}

	/// 文字对单层玻璃的最坏对比度：合成亮度对壁纸亮度仿射（单调），
	/// 最小值必在壁纸亮度端点 [0,1] 取得
	nonisolated static func worstCaseContrast(textLuminance: Double, glassLuminance: Double, glassAlpha: Double) -> Double {
		let dark = compositedLuminance(glassLuminance: glassLuminance, glassAlpha: glassAlpha, backdropLuminance: 0)
		let bright = compositedLuminance(glassLuminance: glassLuminance, glassAlpha: glassAlpha, backdropLuminance: 1)
		return min(contrast(textLuminance, dark), contrast(textLuminance, bright))
	}

	/// 两亮度的 WCAG 对比度
	nonisolated static func contrast(_ a: Double, _ b: Double) -> Double {
		let hi = max(a, b), lo = min(a, b)
		return (hi + 0.05) / (lo + 0.05)
	}

	/// 多层玻璃叠加（自上而下每层 (相对亮度, 透明度)）压在壁纸亮度 t 上的合成亮度范围。
	/// 每层合成都是对 t 的仿射函数，仿射的仿射仍是仿射——最坏值在 t 端点取得，
	/// 故返回端点亮度的 (min, max) 即覆盖全域壁纸的最坏情况
	nonisolated static func stackedLuminanceRange(
		layers: [(luminance: Double, alpha: Double)],
		backdropRange: ClosedRange<Double> = 0...1
	) -> (min: Double, max: Double) {
		func stack(_ t: Double) -> Double {
			var b = t
			for layer in layers.reversed() {
				b = layer.alpha * layer.luminance + (1 - layer.alpha) * b
			}
			return b
		}
		let lo = stack(backdropRange.lowerBound)
		let hi = stack(backdropRange.upperBound)
		return (min(lo, hi), max(lo, hi))
	}

	/// 文字对合成亮度范围的最坏对比度
	nonisolated static func contrast(textLuminance: Double, against range: (min: Double, max: Double)) -> Double {
		min(contrast(textLuminance, range.min), contrast(textLuminance, range.max))
	}
}
