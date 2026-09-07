import Foundation

/// 通知点按开面板的决策（v1.18.9，纯函数供单测）：
/// 面板不可见 → 打开（用户点通知 = "让我看详情"）；已可见 → 不动
/// （不闪烁、不重播入场动画——用户可能正在看相关卡片）。
nonisolated enum PanelOpenPolicy {
	nonisolated static func shouldOpen(isVisible: Bool) -> Bool {
		!isVisible
	}
}
