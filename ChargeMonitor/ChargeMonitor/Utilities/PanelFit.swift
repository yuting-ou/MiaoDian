import Foundation

/// 面板高度预算（纯函数，无 AppKit/SwiftUI——两遍布局的判定逻辑进测试面，控制器只消费结果）。
/// 背景：实测用户卡片集下面板自然高 1101pt 而可视区只有 987pt——底部约 4 行控制项
/// 压在 Dock 下点不到；间距压缩已到极限（v2.1.2 离屏量具实测），根治只剩"装不下才滚动"。
/// 但滚动会改变宿主布局树（1.1.1 曾在 MenuBarExtra 宿主里加 ScrollView 把卡片渲染成空白），
/// 所以门控必须精确到"真装不下才包"——卡片少的用户走原路径，零行为变化。
nonisolated enum PanelFit {
	/// 顶部余量：面板顶边距菜单栏下缘留 4pt，再留一点呼吸（与定位余量一致）
	nonisolated static let topMargin: CGFloat = 8
	/// 内容区高度地板：屏幕可视区异常矮时也保证至少这么多可看区域——
	/// 宁可短面板滚动，不要点不到的控制项
	nonisolated static let floorHeight: CGFloat = 360

	struct Budget: Equatable {
		/// 可视预算 = 可视区高 − 顶部余量 − 隐形标题栏
		let availableHeight: CGFloat
		/// true = 自然高超出预算 → 卡片区包一层滚动容器
		let scrolls: Bool
		/// 实际采用的内容高（滚动情形钳到预算，普通情形即自然高）
		let contentHeight: CGFloat
	}

	/// chromeHeight：.titled + fullSizeContentView 窗口"隐形标题栏"那条高度
	/// （frame 高 − 内容矩形高）。不扣的话 setContentSize 之后窗口框仍会多出
	/// ~28pt 压进 Dock（实测窗口 1011 vs 内容 979）
	nonisolated static func budget(
		naturalHeight: CGFloat,
		visibleFrameHeight: CGFloat,
		chromeHeight: CGFloat
	) -> Budget {
		let available = max(floorHeight, visibleFrameHeight - topMargin - chromeHeight)
		// 离屏探针测量失败（0/负）不许把面板做成 0 高空白：踩地板，记为「装得下」的最小面板
		let safeNatural = naturalHeight > 0 ? naturalHeight : floorHeight
		let scrolls = safeNatural > available
		return Budget(availableHeight: available, scrolls: scrolls, contentHeight: min(safeNatural, available))
	}
}
