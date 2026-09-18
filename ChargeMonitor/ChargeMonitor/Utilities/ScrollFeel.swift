import Foundation

/// 滚动手感（纯函数）：区分触控板与鼠标滚轮。
///
/// 触控板 `hasPreciseScrollingDeltas=true`，系统按像素滚动已跟手，一律原样放过。
/// 鼠标滚轮是行步进（一格约 ±1），在玻璃卡片区里「转很多圈才动一点」——
/// 换算成像素步长后合成精确滚动事件，让滚轮与触控板走同一条像素路径。
nonisolated enum ScrollFeel {
	/// 鼠标滚轮一格（deltaY=±1）对应的垂直像素。
	/// 校准：SwiftUI ScrollView 默认行高偏小，密集卡片下用户体感是「不动」；
	/// 60pt/格 ≈ 一次中等幅度翻过 1–2 张卡，与系统原生列表的滚轮手感同量级。
	nonisolated static let mousePixelStep: CGFloat = 60

	/// 幅度地板：惯性尾巴（|delta|→0）不放大，避免与系统惯性叠成过冲。
	nonisolated static let minWheelDelta: CGFloat = 0.15

	/// 是否应放大：仅非精确滚动（鼠标滚轮）且幅度有效。
	nonisolated static func shouldAmplify(hasPreciseScrollingDeltas: Bool, deltaY: CGFloat) -> Bool {
		!hasPreciseScrollingDeltas && abs(deltaY) >= minWheelDelta
	}

	/// 鼠标滚轮 deltaY → 像素位移。
	/// 符号与 `scrollingDeltaY` 一致（系统已按「自然滚动」偏好预处理方向），合成事件沿用即可。
	nonisolated static func pixelDelta(forWheel deltaY: CGFloat, step: CGFloat = mousePixelStep) -> CGFloat {
		deltaY * step
	}
}

/// 滚动静默判定（纯函数，进测试面）：触控板 bounds 变化停手多久视为 idle
nonisolated enum PanelScrollIdle {
	/// 最后一次 bounds 变化后静默多久视为停手
	nonisolated static let idleMilliseconds: UInt64 = 80
	nonisolated static var idleNanoseconds: UInt64 { idleMilliseconds * 1_000_000 }

	nonisolated static func shouldClearScrolling(elapsedNanoseconds: UInt64) -> Bool {
		elapsedNanoseconds >= idleNanoseconds
	}
}

/// 纵向弹性策略（纯函数）：到顶/到底是否允许橡皮筋回弹。
/// 橡皮筋是 macOS/苹果手感的一部分（液态玻璃面板也靠它「有生命」）。
/// 滚动掉帧主因已改由「数据发布冻结 + 去掉陪滚 GeometryReader」承担；
/// 回弹默认**保留**。若未来实测边界仍掉帧，再单独收这一刀。
nonisolated enum PanelScrollElasticity {
	nonisolated static let allowsVerticalBounce = true
}

/// 滚动文档几何（纯函数）：测量后如何撑高 document、如何钳制 scroll offset。
/// updateNSView 每次数据刷新都会重测——若先把 hosting 高度打成 10 再量，
/// clipView 会把 origin 钳回 0，用户看到「滑到中间又被拽回顶部」。
nonisolated enum PanelScrollGeometry {
	/// document 高：至少与视口同高（装不满也不留空转），否则取测量高
	nonisolated static func documentHeight(measured: CGFloat, viewport: CGFloat) -> CGFloat {
		max(measured, max(viewport, 0))
	}

	/// 把将要保留的 scrollY 钳进 [0, content-viewport]
	nonisolated static func clampedScrollY(current: CGFloat, contentHeight: CGFloat, viewport: CGFloat) -> CGFloat {
		let maxY = max(0, contentHeight - max(viewport, 0))
		return min(max(current, 0), maxY)
	}
}
