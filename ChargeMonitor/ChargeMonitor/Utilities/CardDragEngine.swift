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
