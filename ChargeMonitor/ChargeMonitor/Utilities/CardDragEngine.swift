import SwiftUI

/// 华容网格拖拽状态机（面板级单份状态，随 BatteryPopoverView 生命周期）。
/// 把手按住即拖 → DragGesture 跟手 → 落点实时驱动 flow 插入预览 → 松手提交持久化。
/// 数据层复用 PanelFlow 纯函数（已测）；这里只管手势时序与几何计算。
nonisolated struct CardDragState {
	// 正被拖动的卡片
	var card: String
	// 手势位移（窗口坐标增量）
	var translation: CGSize = .zero
	// 拖动开始瞬间该卡的窗口坐标 frame——落点计算的固定基准，
	// 预览重排后探针会刷新 frame 表，但不能回灌落点计算（防反馈振荡）
	var originFrame: CGRect = .zero

	/// 激活判定：位移超过 6pt 才算真拖（纯按住不动=悬停预览态）
	var isDragging: Bool {
		hypot(translation.width, translation.height) > 6
	}

	/// 指针当前位置（窗口坐标）= 起始卡中心 + 位移
	var pointer: CGPoint {
		CGPoint(x: originFrame.midX + translation.width, y: originFrame.midY + translation.height)
	}
}

/// 落点几何：把指针位置换算成 flow 插入点。
/// frames 预存每张卡的窗口坐标 frame（由渲染层 CardFrameProbe 采集）；
/// 密铺渲染顺序 = flow 顺序，按 (minY, minX) 排序即视觉自上而下、自左而右。
nonisolated enum CardDropResolver {
	nonisolated struct FrameTable {
		var frames: [String: CGRect] = [:]
	}

	/// 落点判定：返回插到某卡之前 / 追加末尾；nil = 落点在板面横向范围之外（丢弃回弹）。
	/// excluding 排除被拖卡片自身——它的预览 frame 不参与锚定，否则"锚点是自己"
	/// 会在摘除后失配、被误判为追加末尾。
	nonisolated static func resolve(
		point: CGPoint,
		table: FrameTable,
		excluding: String? = nil
	) -> PanelFlow.DropTarget? {
		let sorted = table.frames
			.filter { $0.key != excluding }
			.sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }
		guard let first = sorted.first else { return nil }
		// 横向出界判定：全部卡片 frame 的水平范围外扩 30pt 之外视为丢弃
		let minX = (sorted.map { $0.value.minX }.min() ?? 0) - 30
		let maxX = (sorted.map { $0.value.maxX }.max() ?? 0) + 30
		guard point.x >= minX, point.x <= maxX else { return nil }
		// 顶于首卡上沿 → 插到最前
		if point.y < first.value.midY {
			return .before(first.key)
		}
		for (index, frame) in sorted.enumerated() {
			guard point.y <= frame.value.maxY else { continue }
			// 落在卡片下半 → 插到它之后（返回它的下一张作锚点）
			if point.y >= frame.value.midY {
				return index + 1 < sorted.count ? .before(sorted[index + 1].key) : .end
			}
			return .before(frame.key)
		}
		// 超过最后一张 → 追加末尾
		return .end
	}
}

/// frame 采集探针：卡片背景里安静地把自己在窗口坐标系的 frame 写进共享表
struct CardFrameProbe: View {
	let id: String
	@Binding var table: CardDropResolver.FrameTable

	var body: some View {
		GeometryReader { geo in
			Color.clear
				.onAppear {
					table.frames[id] = geo.frame(in: .global)
				}
				.onChange(of: geo.frame(in: .global)) { _, new in
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
