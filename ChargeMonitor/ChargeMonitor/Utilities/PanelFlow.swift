import Foundation

/// 面板卡片自定义布局（华容网格 v4）：显式行存储，双射靠存储本身成立——
/// 一行 = 一张独占整行的卡（宽块），或两张并排的半宽卡；不存在任何布局算法。
/// 用户意图（阅读序、去留、宽窄）全部显式落在 rows/hidden 里，渲染即存储（预览=落盘=重开）。
/// left/right 是 v1.13 旧档字段，仅作解码回退（按索引对齐成 rows），新写入一律清零。
/// 自动模式（panelLayout == nil）不走本模型：v1.13 贪心双列已验证高度最优（973pt 塞得下屏幕），
/// 行式自定义由用户实时可见、自己买单——高度门已证明宽卡默认出厂不可行（独占行最少 +20%）。
nonisolated struct PanelLayout: Codable, Equatable, Sendable {
	/// 显式行：1 张（独占整行）或 2 张（并排半宽）；卡片 id 有序，去重不变式全板生效
	var rows: [[String]]? = nil
	var left: [String] = []
	var right: [String] = []
	var hidden: [String] = []

	init(rows: [[String]]? = nil, left: [String] = [], right: [String] = [], hidden: [String] = []) {
		self.rows = rows
		self.left = left
		self.right = right
		self.hidden = hidden
	}

	/// 生效行表：优先 rows，v1.13 旧档回退（两列按索引对齐成行，列内相对序保留）
	nonisolated var effectiveRows: [[String]] {
		rows ?? PanelFlow.alignColumns(left: left, right: right)
	}
}

/// 华容网格纯函数：所有布局变更走这里（不变式：每张卡在 rows ∪ hidden 中至多出现一次；
/// 行内 1–2 张；无任何高度/几何输入——布局与估算彻底解耦）。
nonisolated enum PanelFlow {
	/// 一行渲染形态：full = 独占整行（宽块/落单拉通），pair = 两张半宽卡并排
	nonisolated enum Segment: Equatable, Hashable {
		case full(String)
		case pair(left: String, right: String)
	}

	/// 渲染预备：行表 → 段落。条件不可见的卡跳过（位置保留在存储里）；
	/// 双行只剩一张可见卡时自动拉通整行（不留半空行）。纯函数，渲染顺序 = 行序 = 阅读序。
	nonisolated static func renderSegments(_ rows: [[String]], available: Set<String>) -> [Segment] {
		rows.compactMap { row in
			let visible = row.filter { available.contains($0) }
			switch visible.count {
			case 2: return .pair(left: visible[0], right: visible[1])
			case 1: return .full(visible[0])
			default: return nil
			}
		}
	}

	/// 落点语义：插到某张卡之前，或追加末尾（由 CardDropResolver 产出）
	nonisolated enum DropTarget: Equatable {
		case before(String)
		case end
	}

	/// v1.13 两列 → 行表（按索引对齐；列内相对序保留，一次性质的对齐迁移）
	nonisolated static func alignColumns(left: [String], right: [String]) -> [[String]] {
		let count = max(left.count, right.count)
		return (0..<count).map { i in
			[left.indices.contains(i) ? left[i] : nil, right.indices.contains(i) ? right[i] : nil]
				.compactMap { $0 }
		}
	}

	/// 从行表摘除 card（隐藏/移动前置步骤）
	nonisolated static func extract(_ rows: [[String]], card: String) -> [[String]] {
		rows.compactMap { row in
			let filtered = row.filter { $0 != card }
			return filtered.isEmpty ? nil : filtered
		}
	}

	/// 拖拽落位：摘除 card 后插到 anchor 之前——card 与 anchor 结对新行（card 占 anchor 前一位），
	/// 原同伴溢出为下一行单行（局部、确定、无算法）。anchor 缺失/nil = 追加末尾单行。
	nonisolated static func insert(_ rows: [[String]], card: String, before anchor: String?) -> [[String]] {
		var r = extract(rows, card: card)
		guard let anchor, anchor != card, let (ri, _) = locate(r, id: anchor) else {
			return r + [[card]]
		}
		let row = r[ri]
		if row.count == 1 {
			// 单行（宽块）：card 与 anchor 结对收窄，card 占前位（插入语义 = 在 anchor 之前）
			r[ri] = [card, anchor]
			return r
		}
		// 双行：card 与 anchor 结对，原同伴溢出为下一行单行
		let displaced = row.first { $0 != anchor } ?? anchor
		r[ri] = [card, anchor]
		return r[...ri] + [[displaced]] + r[(ri + 1)...]
	}

	/// 定位：card 所在行与行内下标
	nonisolated static func locate(_ rows: [[String]], id: String) -> (row: Int, col: Int)? {
		for (ri, row) in rows.enumerated() {
			if let ci = row.firstIndex(of: id) { return (ri, ci) }
		}
		return nil
	}

	/// 宽窄切换（行表直改）：半宽 → 拉宽独占整行（宽行插在同伴行之前，保持"拖谁谁在前"的
	/// 阅读序；同伴与下一行首卡结对）；宽块 → 收窄并回相邻行（优先下行）。相邻行也不存在时返回 nil。
	nonisolated static func toggleWide(_ rows: [[String]], card: String) -> [[String]]? {
		guard let (ri, _) = locate(rows, id: card) else { return nil }
		let row = rows[ri]
		if row.count == 2 {
			let mate = row.first { $0 != card } ?? card
			var r = extract(rows, card: card)
			guard let mi = locate(r, id: mate)?.row else { return nil }
			if mi + 1 < r.count, !r[mi + 1].isEmpty {
				// 同伴与下一行首卡结对，下一行剩余溢出
				let next = r[mi + 1]
				r[mi] = [mate, next[0]]
				if next.count == 2 { r[mi + 1] = [next[1]] } else { r.remove(at: mi + 1) }
			}
			r.insert([card], at: min(mi, r.count))
			return r
		}
		// 宽 → 半宽：与相邻行首卡结对（优先下行），原首卡的同伴溢出为单行
		if ri + 1 < rows.count, !rows[ri + 1].isEmpty {
			var r = rows
			r.remove(at: ri)
			let next = r[ri]
			r[ri] = [next[0], card]
			if next.count == 2 { r.insert([next[1]], at: ri + 1) }
			return r
		}
		if ri > 0, !rows[ri - 1].isEmpty {
			var r = rows
			r.remove(at: ri)
			let prev = r[ri - 1]
			r[ri - 1] = [prev[0], card]
			if prev.count == 2 { r.insert([prev[1]], at: ri) }
			return r
		}
		return nil
	}

	/// 拖拽落位（DropTarget 直连）：摘除 card 后按落点重排行表
	nonisolated static func insertLayout(_ layout: PanelLayout, card: String, target: DropTarget) -> PanelLayout {
		let anchor: String? = {
			if case .before(let id) = target { return id }
			return nil
		}()
		var l = layout
		l.rows = insert(l.effectiveRows, card: card, before: anchor)
		l.left = []
		l.right = []
		return l
	}

	/// 宽窄切换（PanelLayout 版）：拉宽/收窄并写回行存储；无法切换返回 nil
	nonisolated static func toggleWide(_ layout: PanelLayout, card: String) -> PanelLayout? {
		guard let newRows = toggleWide(layout.effectiveRows, card: card) else { return nil }
		var l = layout
		l.rows = newRows
		l.left = []
		l.right = []
		return l
	}

	/// 藏起卡片：从行表摘除，进 hidden 托盘
	nonisolated static func hide(_ layout: PanelLayout, card: String) -> PanelLayout {
		var l = layout
		l.rows = extract(l.effectiveRows, card: card)
		l.left = []
		l.right = []
		if !l.hidden.contains(card) { l.hidden.append(card) }
		return l
	}

	/// 从托盘捞回：追加为末尾单行（宽块入场醒目，位置可拖/可并微调）
	nonisolated static func unhide(_ layout: PanelLayout, card: String) -> PanelLayout {
		var l = layout
		l.hidden.removeAll { $0 == card }
		l.rows = extract(l.effectiveRows, card: card) + [[card]]
		l.left = []
		l.right = []
		return l
	}

	/// 归一：未知 id 丢弃、全板去重、隐藏卡不残留、行空剔除；缺失的已知卡片按序追加为末尾单行；
	/// 旧字段清零（首次归一即升级为行存储）。结果幂等。
	nonisolated static func normalize(_ layout: PanelLayout, known: Set<String>) -> PanelLayout {
		var l = layout
		var seen = Set<String>()
		l.rows = l.effectiveRows
			.map { row in
				row.filter { known.contains($0) && !l.hidden.contains($0) && seen.insert($0).inserted }
			}
			.filter { !$0.isEmpty }
		var hiddenSeen = Set<String>()
		l.hidden = l.hidden.filter { known.contains($0) && hiddenSeen.insert($0).inserted }
		l.left = []
		l.right = []
		let placed = Set((l.rows ?? []).flatMap { $0 }).union(l.hidden)
		for id in known.sorted() where !placed.contains(id) {
			l.rows?.append([id])
		}
		return l
	}
}
