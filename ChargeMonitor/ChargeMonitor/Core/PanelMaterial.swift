import SwiftUI

/// 面板材质三档（v1.24.0 重设计）：三档映射 Apple 原生玻璃的不同真实选项，而非同一块玻璃上的白纱浓淡。
/// v1.20.0 的教训：三档只差同块 `.regular` 玻璃上的白/黑纱 alpha（浅 0.30→0.74，深三档同参），
/// 被玻璃自身霜感吃掉，肉眼不可辨；深色更是像素级相同——「三种面板状态没有差异」的根源。
/// v1.24.0：材质本体即档位——通透=`.clear`（原生最透）、均衡=`.regular`（原生标准）、
/// 厚重=`.regular`+高浓度 tint。档差由玻璃变体+壳层 tint+卡面浓度三重承担，证明表锁定。
/// 深色也拉开（0.76/0.70/0.82 黑 tint，壳层穿透摆幅 0.19/0.15/0.09 单调）：白字 AAA 的物理下限
/// 仍在（文字面必须暗），通透感体现在壁纸可见度而非绝对亮度——这是深色玻璃的诚实形态。
/// 可读性分工：内容文字坐卡面（各档卡面按证明锁 ≥7 AAA）；壳层不再直露文字
/// （编辑条/托盘 v1.24.0 起坐卡纱，控制行 v1.24.1 起坐玻璃药丸——tint 即文字的墙），
/// 玻璃在四周流动、内容坐稳定面。
/// 「降低透明度」「增加对比度」系统开关优先级高于档位（外层分支处理）。
nonisolated enum PanelMaterial: String, Codable, CaseIterable, Sendable, Identifiable {
	case clear       // 通透：原生 clear 玻璃，壁纸轮廓与流动最清晰
	case balanced    // 均衡：原生 regular 玻璃（系统默认面板材质）
	case solid       // 厚重：原生 regular + 高浓度 tint，接近实色

	var id: String { rawValue }

	var title: String {
		switch self {
		case .clear: return "通透"
		case .balanced: return "均衡"
		case .solid: return "厚重"
		}
	}

	var detail: String {
		switch self {
		case .clear: return "原生 clear 玻璃，壁纸清晰透出，玻璃感最强"
		case .balanced: return "原生 regular 玻璃，系统默认浓度（推荐）"
		case .solid: return "玻璃加浓 tint，接近实色，杂乱背景最稳"
		}
	}

	/// 26 玻璃路径的壳层材质档位（映射原生 glassEffect 浓度选项）
	nonisolated var shellGlassVariant: ShellGlassVariant {
		switch self {
		case .clear: return .clear
		case .balanced: return .regular
		case .solid: return .regularTinted
		}
	}

	/// 该档允许的内容区背景穿透摆幅上限（浅色档位定义本身，证明表按此锁；深色统一 ≤0.12）
	nonisolated var interferenceTolerance: Double {
		switch self {
		case .clear: return 0.62
		case .balanced: return 0.38
		case .solid: return 0.10
		}
	}

	/// 目检注入口：`MIAODIAN_DEBUG_MATERIAL=<clear|balanced|solid>` 启动时覆盖配置档位，
	/// 供三档×双外观无人值守截图验收。与 MIAODIAN_DEBUG_OPEN_PANEL / --miao-visual 同族，
	/// v2.0.0 与 --miao-visual 一并移除。
	nonisolated static var debugOverride: PanelMaterial? {
		ProcessInfo.processInfo.environment["MIAODIAN_DEBUG_MATERIAL"].flatMap(Self.init(rawValue:))
	}

	/// 壳层 tint 浓度（证明模型里的叠加层；26 路径即 glassEffect tint，alpha=0 不施）。
	/// 浅色通透/均衡走纯原生玻璃（0）托「苹果纯正」；厚重补白 0.74。
	/// 深色白字 AAA 硬约束下以黑 tint 拉档差：0.76/0.70/0.82——卡面亮度上限随之单调
	/// （0.098/0.095/0.085，见证明表），通透感由玻璃变体承担（壳层穿透率 0.19/0.15/0.09 严格单调）。
	nonisolated func floorAlpha(isDark: Bool) -> Double {
		switch self {
		case .clear: return isDark ? 0.76 : 0.0
		case .balanced: return isDark ? 0.70 : 0.0
		case .solid: return isDark ? 0.82 : 0.74
		}
	}

	/// 卡面纱 alpha：所有文字的第一道墙（v1.24.0 起壳层无直露文字）。
	/// 浅色白纱（黑字需要亮面）：0.30/0.29/0.42；深色黑纱（白字需要暗面）：0.50/0.40/0.10。
	/// 六组参数全部经证明表锁定（卡面文字 ≥7 AAA + 亮面下限 + 穿透按档阈值）。
	nonisolated func cardFillAlpha(isDark: Bool) -> Double {
		switch self {
		case .clear: return isDark ? 0.50 : 0.30
		case .balanced: return isDark ? 0.40 : 0.29
		case .solid: return isDark ? 0.10 : 0.42
		}
	}
}

/// 壳层玻璃档位到原生 SwiftUI 玻璃 API 的映射（macOS 26 glassEffect 的浓度选项）。
/// 通透=`.clear`、均衡=`.regular`、厚重=`.regular`+GlassTokens 浓 tint——
/// 三档是 Apple 材质系统里的不同真实浓度，不是同一块玻璃调 alpha。
nonisolated enum ShellGlassVariant {
	case clear
	case regular
	case regularTinted
}
