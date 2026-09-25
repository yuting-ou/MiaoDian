import Foundation

/// 卡片声明高度的单一登记表（纯函数，进测试面）。
///
/// 为什么要有它：配平用的声明高原先直接写在 `BatteryPopoverView.visibleCards` 里，
/// 而 `UI/` 不进测试编译面——于是"内容长高了、声明没跟上"这类错在三个卡上各犯一次
/// （今日用电 2.9.11 已修；体检卡、洞察卡本轮修）。规则：**声明高必须是逻辑层里
/// 由数据算出来的函数，常量由 `bash 工具/离屏验收.sh cards` 量真卡回填，不许手写数值**。
nonisolated enum PanelCardHeights {
	/// 洞察卡最多渲染几条——**渲染侧与配平侧共用这一个数**（2.9.14 前渲染 `prefix(3)`、
	/// 配平却按 `count` 全算，7 条洞察时声明虚高 92pt）
	nonisolated static let visibleInsightLines = 3

	// 以下常量全部来自离屏量具（`bash 工具/离屏验收.sh cards`，列宽 275pt、真组件真字体）：
	//   体检卡：无估计项 38pt／有估计项 50pt（"含估计项：…"那行只在有估计项时出现）
	//   洞察卡：1 条 1 行句 36pt；每多一条 1 行句 +14；每条多折一行 +12
	//          （实测量点：1×1 行 36、1×2 行 48、3×1 行 64、3×2 行 102）
	nonisolated static let checkupBaseHeight: CGFloat = 38
	nonisolated static let checkupEstimatedLine: CGFloat = 12
	nonisolated static let insightSingleItemHeight: CGFloat = 36
	nonisolated static let insightExtraItemHeight: CGFloat = 14
	nonisolated static let insightWrappedLineHeight: CGFloat = 12
	/// 洞察正文的可用文字宽：列 275 − 卡片水平内边距 10×2 − 图标 14 − 图标与文字间距 6
	nonisolated static let insightTextWidth: CGFloat = 235
	/// 首条正文 11pt、其余 10pt（与 TrendAndCalendarSections 的字号同源）
	nonisolated static let insightFirstFontSize: CGFloat = 11
	nonisolated static let insightRestFontSize: CGFloat = 10

	/// 体检卡：条件行必须计入，否则真实 38／50 被恒定报成 58
	nonisolated static func checkup(estimatedInputs: [String]) -> CGFloat {
		checkupBaseHeight + (estimatedInputs.isEmpty ? 0 : checkupEstimatedLine)
	}

	/// 洞察卡：先按渲染上限截断，再按**每条正文实际折几行**算高。
	/// 只按条数算会把「每条恰好折两行」的夹具当成普适真相——1 行句虚高 12pt、
	/// 4 行长句少报 26pt，比修之前更歪（v2.9.14 审查抓到）。
	nonisolated static func habitInsight(messages: [String]) -> CGFloat {
		let shown = Array(messages.prefix(visibleInsightLines))
		guard !shown.isEmpty else { return insightSingleItemHeight }
		var height = insightSingleItemHeight
			+ insightExtraItemHeight * CGFloat(shown.count - 1)
		for (index, message) in shown.enumerated() {
			let lines = PanelTextMetrics.visualLines(
				text: message,
				availableWidth: insightTextWidth,
				fontSize: index == 0 ? insightFirstFontSize : insightRestFontSize
			)
			height += insightWrappedLineHeight * CGFloat(max(0, lines - 1))
		}
		return height
	}
}
