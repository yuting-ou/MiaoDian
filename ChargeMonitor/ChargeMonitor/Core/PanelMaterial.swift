import SwiftUI

/// 面板材质三档（v1.20.0，用户可选）：通透 / 均衡（默认）/ 厚重。
/// 每档 = (壳层地板 alpha, 卡片白纱 alpha) 的参数组合（浅色外观），全部经证明表锁定：
/// 卡面黑字 AAA、亮背景卡面 ≥0.88、穿透摆幅按档阈值（通透 0.24 / 均衡 0.18 / 厚重 0.10）。
/// 深色外观三档同参（地板 0.81 黑 / 卡 0.045 白）——白字 AAA 要求深色面板近不透明，
/// 通透空间物理不存在；深色的通透感来自材质模糊本身，设置 UI 已注明。
/// 「降低透明度」「增加对比度」系统开关优先级高于档位（外层分支处理，档位只在玻璃路径内生效）。
nonisolated enum PanelMaterial: String, Codable, CaseIterable, Sendable, Identifiable {
	case clear       // 通透：壁纸几乎直接透出
	case balanced    // 均衡：默认，背景轮廓可辨（与 v1.19.3 观感一致）
	case solid       // 厚重：接近实色，杂乱背景最稳

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
		case .clear: return "壁纸清晰透出，玻璃感最强"
		case .balanced: return "背景轮廓可辨，内容清晰（推荐）"
		case .solid: return "接近实色，杂乱背景最稳"
		}
	}

	/// 该档允许的内容区背景穿透摆幅上限（档位定义本身，证明表按此锁）
	nonisolated var interferenceTolerance: Double {
		switch self {
		case .clear: return 0.33
		case .balanced: return 0.18
		case .solid: return 0.10
		}
	}

	/// 壳层地板 alpha：浅色按档位区分（0.30/0.50/0.74）；深色固定 0.81（白字 AAA 硬约束）
	nonisolated func floorAlpha(isDark: Bool) -> Double {
		guard !isDark else { return 0.81 }
		switch self {
		case .clear: return 0.30
		case .balanced: return 0.50
		case .solid: return 0.74
		}
	}

	/// 卡片白纱 alpha：浅色按档位区分（0.24/0.29/0.42）；深色固定 0.045
	nonisolated func cardFillAlpha(isDark: Bool) -> Double {
		guard !isDark else { return 0.045 }
		switch self {
		case .clear: return 0.33
		case .balanced: return 0.29
		case .solid: return 0.42
		}
	}
}
