import Foundation

/// 面板卡片自定义布局（华容道）：用户在「编辑布局」模式里决定每张卡片的位置与去留。
/// left/right 是两列的卡片 id 有序表（CardID 的字符串形式），hidden 是被用户藏起的卡片。
/// 未出现在表中的卡片按语义顺序追加（normalize）；条件不可见的卡片保留位置、渲染时跳过。
nonisolated struct PanelLayout: Codable, Equatable, Sendable {
	var left: [String]
	var right: [String]
	var hidden: [String] = []

	init(left: [String] = [], right: [String] = [], hidden: [String] = []) {
		self.left = left
		self.right = right
		self.hidden = hidden
	}
}

/// 布局编辑纯函数：所有变更走这里（去重不变式：每张卡至多出现一次）。
/// 移动/换列按"锚点卡片"定位，折叠等条件性隐藏由渲染层跳过，不进编辑器。
nonisolated enum PanelLayoutEditor {
	nonisolated enum Column: CaseIterable { case left, right }
	nonisolated enum Direction { case up, down, left, right }

	nonisolated static func cards(_ layout: PanelLayout, column: Column) -> [String] {
		column == .left ? layout.left : layout.right
	}

	nonisolated private static func setCards(_ layout: inout PanelLayout, column: Column, _ cards: [String]) {
		if column == .left { layout.left = cards } else { layout.right = cards }
	}

	/// 核心：把 card 摘除后插到目标列锚点卡片之前（锚点为空则追加到末尾）
	nonisolated static func move(
		_ layout: PanelLayout,
		card: String,
		toColumn target: Column,
		before anchor: String?
	) -> PanelLayout {
		var l = layout
		l.left.removeAll { $0 == card }
		l.right.removeAll { $0 == card }
		var targetCards = cards(l, column: target)
		let index: Int
		if let anchor, let i = targetCards.firstIndex(of: anchor) {
			index = i
		} else {
			index = targetCards.count
		}
		targetCards.insert(card, at: index)
		setCards(&l, column: target, targetCards)
		return l
	}

	/// 方向移动：上/下=列内换位（到边界原样返回）；左/右=换到另一列同序位置
	nonisolated static func shift(_ layout: PanelLayout, card: String, direction: Direction) -> PanelLayout {
		guard let column: Column = layout.left.contains(card) ? .left : (layout.right.contains(card) ? .right : nil) else {
			return layout
		}
		var columnCards = cards(layout, column: column)
		guard let index = columnCards.firstIndex(of: card) else { return layout }
		switch direction {
		case .up:
			guard index > 0 else { return layout }
			columnCards.swapAt(index, index - 1)
		case .down:
			guard index < columnCards.count - 1 else { return layout }
			columnCards.swapAt(index, index + 1)
		case .left, .right:
			let target: Column = column == .left ? .right : .left
			let other = cards(layout, column: target)
			let insertAt = min(index, other.count)
			return move(layout, card: card, toColumn: target, before: insertAt < other.count ? other[insertAt] : nil)
		}
		var l = layout
		setCards(&l, column: column, columnCards)
		return l
	}

	/// 藏起卡片：从两列摘除，进 hidden 托盘（正常模式不渲染）
	nonisolated static func hide(_ layout: PanelLayout, card: String) -> PanelLayout {
		var l = layout
		l.left.removeAll { $0 == card }
		l.right.removeAll { $0 == card }
		if !l.hidden.contains(card) { l.hidden.append(card) }
		return l
	}

	/// 从托盘捞回：插到指定列末尾
	nonisolated static func unhide(_ layout: PanelLayout, card: String, to column: Column) -> PanelLayout {
		var l = layout
		l.hidden.removeAll { $0 == card }
		return move(l, card: card, toColumn: column, before: nil)
	}

	/// 归一：按 known 集合过滤未知 id、每列去重、把缺失的已知卡片按序追加到左列末尾
	/// （新卡片类型升级进来 / 历史布局里删掉的卡片），结果幂等
	nonisolated static func normalize(_ layout: PanelLayout, known: Set<String>) -> PanelLayout {
		var l = layout
		func clean(_ ids: [String]) -> [String] {
			var seen = Set<String>()
			return ids.filter { known.contains($0) && seen.insert($0).inserted }
		}
		l.left = clean(l.left)
		l.right = clean(l.right)
		l.hidden = clean(l.hidden)
		let placed = Set(l.left).union(l.right).union(l.hidden)
		for id in known.sorted() where !placed.contains(id) {
			l.left.append(id)
		}
		return l
	}

	/// 从自动配平结果播种（用户第一次进编辑布局模式时，继承当前排布作为起点）
	nonisolated static func seed(left: [String], right: [String]) -> PanelLayout {
		PanelLayout(left: left, right: right)
	}
}
