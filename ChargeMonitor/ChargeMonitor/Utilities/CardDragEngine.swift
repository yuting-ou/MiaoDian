import SwiftUI

/// 华容网格拖拽状态机（面板级单份状态，随 BatteryPopoverView 生命周期）。
/// 把手按住即拖 → DragGesture 跟手 → 落点实时驱动 flow 插入预览 → 松手提交持久化。
/// 数据层复用 PanelFlow 纯函数（已测）；这里只管手势时序与几何计算。
nonisolated struct CardDragState {
	// 正被拖动的卡片
	var card: String
	// 手势位移（窗口坐标增量）
	var translation: CGSize = .zero
	// 拖动开始瞬间该卡的窗口坐标 frame——预览重排后探针会刷新 frame 表，
	// 但不能回灌落点计算（防反馈振荡）
	var originFrame: CGRect = .zero
	// 起拖那一刻指针的真实位置（把手长在卡片顶部中央，卡片中心≠手的位置：
	// 旧实现用"卡中心+位移"当落点，拖一张 200pt 高的图表卡，系统算的点在手下方 ~100pt，
	// 用户看到的就是"才拖一点就跳好几格"——v2.1.2 人体工学修正）
	var startPoint: CGPoint = .zero

	/// 激活判定：位移超过 6pt 才算真拖（纯按住不动=悬停预览态）
	var isDragging: Bool {
		hypot(translation.width, translation.height) > 6
	}

	/// 指针当前位置（窗口坐标）= 起拖点 + 位移，即手指真正所在处
	var pointer: CGPoint {
		CGPoint(x: startPoint.x + translation.width, y: startPoint.y + translation.height)
	}
}

/// 落点几何：把指针位置换算成 flow 插入点。
/// frames 预存每张卡的窗口坐标 frame（由渲染层 CardFrameProbe 采集）；
/// 密铺渲染顺序 = flow 顺序，按 (minY, minX) 排序即视觉自上而下、自左而右。
nonisolated enum CardDropResolver {
	nonisolated struct FrameTable {
		var frames: [String: CGRect] = [:]
	}

	/// 横向容差：板面水平范围外扩半列宽。旧值 30pt 太窄——往边上甩一下想换列，
	/// 反而被判"出界丢弃回弹"，像面板在拒绝用户
	nonisolated static let horizontalSlack: CGFloat = 140

	/// 落点判定：返回插到某卡之前 / 追加末尾；nil = 落点在板面横向范围之外（丢弃回弹）。
	/// excluding 排除被拖卡片自身——它的预览 frame 不参与锚定，否则"锚点是自己"
	/// 会在摘除后失配、被误判为追加末尾。
	nonisolated static func resolve(
		point: CGPoint,
		table: FrameTable,
		excluding: String? = nil
	) -> PanelFlow.DropTarget? {
		let kept = table.frames.filter { $0.key != excluding }
		guard !kept.isEmpty else { return nil }
		// 视觉顺序：自上而下、自左而右（密铺渲染序 = flow 序）
		let sorted = kept.sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }
		// 横向出界：外扩半列宽之外才判丢弃
		let minX = (kept.map { $0.value.minX }.min() ?? 0) - horizontalSlack
		let maxX = (kept.map { $0.value.maxX }.max() ?? 0) + horizontalSlack
		guard point.x >= minX, point.x <= maxX else { return nil }
		// 首卡之上 / 末卡之下：整体前插 / 追加末尾（不必再选锚卡）
		if point.y < (kept.map { $0.value.minY }.min() ?? 0) { return .before(sorted.first!.key) }
		if point.y > (kept.map { $0.value.maxY }.max() ?? 0) { return .end }

		// 列感知锚定：按"行差为主、列差为辅"选最近一张卡。
		// 旧实现只沿 Y 扫描、从不看 X：指针停在右列卡的上半部，会返回"插到左列卡之前"
		// ——用户"明明拖到右边了它跑左边"。行差用区间距离（落在卡内即 0），
		// 列差权重压低（0.35）保证同一行内 Y 仍是主导，只有明显偏列时才改判
		let anchor = sorted.min { lhs, rhs in
			let a = anchorScore(point, lhs.value), b = anchorScore(point, rhs.value)
			if a == b { return (lhs.value.minY, lhs.value.minX) < (rhs.value.minY, rhs.value.minX) }
			return a < b
		}!
		guard let index = sorted.firstIndex(where: { $0.key == anchor.key }) else { return nil }
		// 落在锚卡上半 → 插到它之前；下半 → 插到它之后（用下一张作锚点，末卡则追加）
		if point.y < anchor.value.midY { return .before(anchor.key) }
		return index + 1 < sorted.count ? .before(sorted[index + 1].key) : .end
	}

	/// 落点指示线几何：插到某卡之前 → 该卡上沿外 4pt；追加末尾 → 末卡下沿外 4pt。
	/// 让位预览已说明"会插在哪"，但指针快速移动时那一格空隙不好盯——2pt 线更确定。
	/// 与 resolve 同一套排除规则：被拖卡自身不参与锚定（线不该画在它原位）。
	/// 返回 (左缘 x, 线的 y, 线宽)；nil = 锚点不在表里（如空板）
	nonisolated static func indicatorLine(
		for target: PanelFlow.DropTarget,
		table: FrameTable,
		excluding: String? = nil
	) -> (x: CGFloat, y: CGFloat, width: CGFloat)? {
		let kept = table.frames.filter { $0.key != excluding }
			.sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }
		switch target {
			case .before(let key):
				guard let f = kept.first(where: { $0.key == key })?.value else { return nil }
				return (f.minX, f.minY - 4, f.width)
			case .end:
				guard let last = kept.last?.value else { return nil }
				return (last.minX, last.maxY + 4, last.width)
		}
	}

	/// 指针到某 frame 的锚定代价：行方向（Y）区间距离平方 + 列方向（X）区间距离平方 ×0.35。
	/// 区间内距离记 0，故"卡在哪一行"由是否落在行带决定，"这一行的哪一列"由 X 偏差决定
	private nonisolated static func anchorScore(_ point: CGPoint, _ frame: CGRect) -> CGFloat {
		func gap(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
			if v < lo { return lo - v }
			if v > hi { return v - hi }
			return 0
		}
		let dy = gap(point.y, frame.minY, frame.maxY)
		let dx = gap(point.x, frame.minX, frame.maxX)
		return dy * dy + dx * dx * 0.35
	}
}

/// 板面坐标空间名：frame 探针与拖拽手势共用。
/// **必须用内容坐标系而不是 .global**——面板卡片区滚动时，每张卡的 global frame
/// 每帧变化，探针 onChange 写回视图状态表 → 整棵面板跟着重算 → 滑动掉帧。
/// 内容系下卡片相对位置在滚动时不变，探针只在真正重排（拖拽预览/折叠/列变更）时写表。
/// 注意：本文件进单元测试面，注释里不要写属性包装器字面量（run_tests.sh 会按字面排除宏宿主）。
enum BoardSpace {
	static let name = "MiaoDianBoard"
}

/// frame 采集探针：卡片背景里安静地把自己在**板面坐标系**的 frame 写进共享表
struct CardFrameProbe: View {
	let id: String
	@Binding var table: CardDropResolver.FrameTable

	var body: some View {
		GeometryReader { geo in
			Color.clear
				.onAppear {
					table.frames[id] = geo.frame(in: .named(BoardSpace.name))
				}
				.onChange(of: geo.frame(in: .named(BoardSpace.name))) { _, new in
					table.frames[id] = new
				}
		}
	}
}

/// 华容网格密铺容器（v1.17.3 丝滑重排）：以卡自身为身份平铺，按 masonryPlan 摆放——
/// 宽卡（full）独占整行，两张半宽卡（pair）并排；行高 = 行内最高卡（顶对齐）。
/// 重排时子视图身份不变、只有 placeSubviews 的坐标变化，配合容器级
/// `.animation(value: 行布局)`，所有卡片沿弹簧滑到新位——位移动画替代跳格子。
/// 与旧行栈渲染的像素契约：行间距 8、卡间距 10、半宽各占 (宽-10)/2。
struct PanelMasonryLayout: Layout {
	let segments: [PanelFlow.Segment]
	/// 全藏光时的板面高度（编辑模式保持高度用）
	let emptyHeight: CGFloat

	/// 单格宽度：整行=板宽；半宽=(板宽-缝)/2
	private func cellWidth(boardWidth: CGFloat, rowWidth: Int) -> CGFloat {
		rowWidth == 1 ? boardWidth : (boardWidth - 10) / 2
	}

	/// 单格横向起点：整行贴左缘；半宽按列位（0=左缘，1=左宽+缝）
	private func cellX(boardMinX: CGFloat, boardWidth: CGFloat, column: Int, rowWidth: Int) -> CGFloat {
		rowWidth == 1 ? boardMinX : boardMinX + CGFloat(column) * (cellWidth(boardWidth: boardWidth, rowWidth: 2) + 10)
	}

	/// 各行行高 = 行内子视图按各自格子宽度提议后的最大自然高度
	private func rowHeights(plan: [PanelFlow.MasonryCell], boardWidth: CGFloat, subviews: Subviews) -> [CGFloat] {
		plan.groupedByRow().map { row in
			row.reduce(CGFloat(0)) { acc, cell in
				let sv = subviews.first { $0[CardIDKey.self] == cell.card }
				let h = sv?.sizeThatFits(ProposedViewSize(width: cellWidth(boardWidth: boardWidth, rowWidth: cell.rowWidth), height: nil)).height ?? 0
				return max(acc, h)
			}
		}
	}

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? 0
		let plan = PanelFlow.masonryPlan(segments)
		guard width > 0, !plan.isEmpty, plan.count == subviews.count else {
			return CGSize(width: width, height: emptyHeight)
		}
		let heights = rowHeights(plan: plan, boardWidth: width, subviews: subviews)
		let total = heights.reduce(0, +) + CGFloat(heights.count - 1) * 8
		return CGSize(width: width, height: max(total, 0))
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		let plan = PanelFlow.masonryPlan(segments)
		guard bounds.width > 0, !plan.isEmpty, plan.count == subviews.count else { return }
		let heights = rowHeights(plan: plan, boardWidth: bounds.width, subviews: subviews)
		var y = bounds.minY
		for (rowIndex, row) in plan.groupedByRow().enumerated() {
			for cell in row {
				if let sv = subviews.first(where: { $0[CardIDKey.self] == cell.card }) {
					sv.place(
						at: CGPoint(x: cellX(boardMinX: bounds.minX, boardWidth: bounds.width, column: cell.column, rowWidth: cell.rowWidth), y: y),
						anchor: .topLeading,
						proposal: ProposedViewSize(width: cellWidth(boardWidth: bounds.width, rowWidth: cell.rowWidth), height: heights[rowIndex])
					)
				}
			}
			y += heights[rowIndex] + 8
		}
	}
}

/// 子视图身份键：把卡 id 挂在子视图上，placeSubviews 里按 plan 对号入座。
/// nonisolated：Layout 协议方法是 nonisolated 上下文，键的一致性不能带 MainActor（Swift6 门零警告）。
private nonisolated struct CardIDKey: LayoutValueKey {
	static let defaultValue: String? = nil
}

extension View {
	/// 在 PanelMasonryLayout 里声明本视图对应的卡 id
	func masonryCard(_ id: String) -> some View {
		layoutValue(key: CardIDKey.self, value: id)
	}
}

extension Array where Element == PanelFlow.MasonryCell {
	/// 按行分组（保序）
	nonisolated func groupedByRow() -> [[PanelFlow.MasonryCell]] {
		var result: [[PanelFlow.MasonryCell]] = []
		var current: [PanelFlow.MasonryCell] = []
		var lastRow = -1
		for cell in self {
			if cell.row != lastRow {
				if !current.isEmpty { result.append(current) }
				current = []
				lastRow = cell.row
			}
			current.append(cell)
		}
		if !current.isEmpty { result.append(current) }
		return result
	}
}
