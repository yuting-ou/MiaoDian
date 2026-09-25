import Foundation

/// 文字排版的共用度量（纯函数，进测试面）。
///
/// 为什么单独一个文件：同一套「全角当量 ÷ 可用宽 = 视觉行数」的规则先后被写进
/// 说明行折行计费与卡片高度两处，各写一遍就会各错一遍（本项目反复踩过"两处同源"）。
nonisolated enum PanelTextMetrics {
	/// 一个全角字符的宽度 ≈ 字号；CJK 记 1，其余（数字/拉丁/空格/标点）记 0.52。
	/// 0.52 是按本仓 size-9/11 真组件量出的经验值偏保守档：ASCII 实际约 0.45–0.5em，
	/// 取 0.52 会让行数只多算不少算——高度多给几 pt 只是配平略保守，少给才是真错。
	nonisolated static func fullWidthWeight(_ text: String) -> Double {
		text.reduce(0.0) { $0 + ($1.isASCII ? 0.52 : 1.0) }
	}

	/// 一段文字在 given 宽度、given 字号下要占几个视觉行（至少 1，向上取整）
	nonisolated static func visualLines(text: String, availableWidth: CGFloat, fontSize: CGFloat) -> Int {
		let perLine = Double(availableWidth) / Double(fontSize)
		guard perLine > 0 else { return 1 }
		return max(1, Int(ceil(fullWidthWeight(text) / perLine)))
	}
}
