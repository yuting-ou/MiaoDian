import SwiftUI

/// 华容道拖拽状态机（面板级单份状态，随 BatteryPopoverView 生命周期）。
/// 长按 ≥0.35s 激活 → DragGesture 跟手 → 落点实时驱动布局预览 → 松手提交持久化。
/// 数据层复用 PanelLayoutEditor 纯函数（已测）；这里只管手势时序与几何计算。
nonisolated struct CardDragState {
	// 正被拖动的卡片
	var card: String
	// 手势位移（窗口坐标增量）
	var translation: CGSize = .zero
	// 拖动开始时该卡的原始位置（列, 行），松手失败回弹用
	var originColumn: PanelLayoutEditor.Column
	var originRow: Int

	/// 激活判定：位移超过 6pt 才算真拖（纯长按不动=悬停预览态）
	var isDragging: Bool {
		hypot(translation.width, translation.height) > 6
	}
}

/// 落点几何：把拖动卡片的中心点换算成 (目标列, 插入行)。
/// rows 预存每列每卡的 frame（窗口坐标），由渲染层用 GeometryReader 采集。
nonisolated enum CardDropResolver {
	nonisolated struct FrameTable {
		var left: [String: CGRect] = [:]
		var right: [String: CGRect] = [:]
	}

	nonisolated static func resolve(
		point: CGPoint,
		table: FrameTable
	) -> (column: PanelLayoutEditor.Column, before: String?)? {
		// 命中判定：点落在哪列的某张卡片竖直区间内（横向按列中心带划分）
		for (column, frames) in [("L", table.left), ("R", table.right)] {
			let sorted = frames.sorted { $0.value.minY < $1.value.minY }
			guard let first = sorted.first else { continue }
			// 列横向带：以该列卡片 frame 的水平范围外扩 20pt
			let minX = (sorted.map { $0.value.minX }.min() ?? 0) - 20
			let maxX = (sorted.map { $0.value.maxX }.max() ?? 0) + 20
			guard point.x >= minX, point.x <= maxX else { continue }
			// 顶于首卡上沿 → 插到最前
			if point.y < first.value.midY {
				return (column == "L" ? .left : .right, sorted.first?.key)
			}
			for f in sorted {
				if point.y <= f.value.maxY {
					// 落在卡片下半 → 插到它之后（返回它的后一张作锚点）
					let idx = sorted.firstIndex { $0.key == f.key }!
					let next = sorted.indices.contains(idx + 1) ? sorted[idx + 1].key : nil
					return (column == "L" ? .left : .right, next)
				}
			}
			// 超过最后一张 → 追加末尾
			return (column == "L" ? .left : .right, nil)
		}
		return nil
	}
}


extension CardDropResolver.FrameTable {
	/// 两列 frame 合并视图
	nonisolated func allFrames() -> [String: CGRect] {
		left.merging(right) { _, new in new }
	}

	nonisolated func framesFor(_ id: String, column: PanelLayoutEditor.Column) -> [CGRect] {
		(column == .left ? left[id] : right[id]).map { [$0] } ?? []
	}
}

/// frame 采集探针：卡片背景里安静地把自己在窗口坐标系的 frame 写进共享表
struct CardFrameProbe: View {
	let id: String
	@Binding var table: CardDropResolver.FrameTable
	let column: PanelLayoutEditor.Column

	var body: some View {
		GeometryReader { geo in
			Color.clear
				.onAppear {
					set(geo.frame(in: .global))
				}
				.onChange(of: geo.frame(in: .global)) { _, new in
					set(new)
				}
		}
	}

	private func set(_ frame: CGRect) {
		if column == .left {
			table.left[id] = frame
		} else {
			table.right[id] = frame
		}
	}
}
