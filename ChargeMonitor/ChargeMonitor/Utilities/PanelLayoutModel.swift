import CoreGraphics
import Foundation

// 面板布局模型（纯逻辑，进单元测试面）：把 BatteryPopoverView 里的三样判定搬出视图——
// 自动模式贪心双列的分列策略、华容网格拖拽状态机的转移规则、布局编辑态的语义。
//
// 纪律（与 PanelFlow / CardDragEngine 同一套）：
// ① 只搬判定不搬状态：状态仍由视图持有（失效范围一个节点都不变），本文件全是纯函数与
//    值类型，可单独构造夹具验证；
// ② 不重复造轮子：行插入/归一/段落走 PanelFlow，落点几何走 CardDropResolver，
//    抓起态的位移与指针换算走 CardDragState（三者都已进测试面）；
// ③ 不引入任何动画、时长、视觉常量与几何：这里只决定"写什么值"，不决定"怎么动"。
// 注：本文件进测试编译面，注释里不要写属性包装器字面量（测试/run_tests.sh 会按字面把宏宿主整体排除）。

// MARK: - 自动模式分列（贪心双列）

/// 自动模式（v1.13 贪心双列）的分列策略。面板打开期间的分配是会话冻结状态：
/// 已有卡不滑动不换位，后到的卡只追加到较矮列——避免曲线数据陆续到位时整个面板在
/// 眼皮底下洗牌；关闭面板后清空，下次打开重新配平。高度门已证实行式密铺出厂态超屏
/// （+12% 起），列式是物理最优，故这里保留贪心配平而不是行式对齐。
nonisolated enum PanelColumnPlan {
	/// 首次分列（无历史分配）：按顺序把每张卡塞进当前较矮的那列。
	/// 平局给左列（`leftHeight <= rightHeight`）——与旧实现逐字一致，别改成 `<`。
	nonisolated static func balanced<ID: Hashable>(
		_ cards: [(id: ID, height: CGFloat)]
	) -> (left: [ID], right: [ID]) {
		var left: [ID] = []
		var right: [ID] = []
		var leftHeight: CGFloat = 0
		var rightHeight: CGFloat = 0
		for card in cards {
			if leftHeight <= rightHeight {
				left.append(card.id)
				leftHeight += card.height
			} else {
				right.append(card.id)
				rightHeight += card.height
			}
		}
		return (left, right)
	}

	/// 沿用已有分配：还在场的卡保持原列原顺序；新到的追加到当前较矮列；消失的卡剔除。
	/// 两列都空（首次进入，或历史分配全被剔除）时退回贪心配平。
	/// 高度按本次枚举出的声明高现算，不缓存历史高度——卡片条件可见性一变，配平要跟着变。
	nonisolated static func merged<ID: Hashable>(
		_ cards: [(id: ID, height: CGFloat)],
		left: [ID],
		right: [ID]
	) -> (left: [ID], right: [ID]) {
		let valid = Set(cards.map(\.id))
		let knownLeft = left.filter { valid.contains($0) }
		let knownRight = right.filter { valid.contains($0) }
		if knownLeft.isEmpty, knownRight.isEmpty {
			return balanced(cards)
		}

		let heightByID = Dictionary(cards.map { ($0.id, $0.height) }, uniquingKeysWith: { a, _ in a })
		var resultLeft = knownLeft
		var resultRight = knownRight
		var leftHeight = knownLeft.reduce(0) { $0 + (heightByID[$1] ?? 0) }
		var rightHeight = knownRight.reduce(0) { $0 + (heightByID[$1] ?? 0) }

		let placed = Set(knownLeft + knownRight)
		for card in cards where !placed.contains(card.id) {
			if leftHeight <= rightHeight {
				resultLeft.append(card.id)
				leftHeight += card.height
			} else {
				resultRight.append(card.id)
				rightHeight += card.height
			}
		}
		return (resultLeft, resultRight)
	}
}

// MARK: - 华容网格拖拽状态机（转移规则）

/// 拖拽状态机的**转移规则**：状态本体（拖拽态、预览布局、落点指示线、把手悬停）仍在视图里，
/// 这里只回答"这一步该写什么"。激活阈值（6pt）在 CardDragState.isDragging，不在这里。
nonisolated enum PanelDragMachine {
	/// 手势分派：没有在拖的卡 → 起拖（播种工作副本、固化起始 frame、让 frame 表开始发变更）；
	/// 同一张卡 → 更新位移；别的卡在拖 → 忽略（幽灵拖拽守卫：不得改写别人的 translation）。
	nonisolated enum Step: Equatable {
		case begin
		case update
		case ignore
	}

	nonisolated static func step(draggingCard: String?, newCard: String) -> Step {
		guard let draggingCard else { return .begin }
		return draggingCard == newCard ? .update : .ignore
	}

	/// 落点指示线（板面坐标）：插到某卡之前 → 该卡上沿外 4pt；追加末尾 → 末卡下沿外 4pt。
	/// 几何本身由 CardDropResolver.indicatorLine 给出，这里只是它的值类型外壳。
	nonisolated struct Indicator: Equatable {
		var x: CGFloat
		var y: CGFloat
		var width: CGFloat
	}

	/// 一次指针移动要写回的结果
	nonisolated enum Preview: Equatable {
		/// 指针出界 / 无锚卡：指示线与预览一起清掉（丢弃回弹语义——松手不得提交上一合法落点）
		case cleared
		/// 合法落点：layout 为 nil 表示"候选与当前基准相同"，此时只动指示线、不写预览
		/// （空写会多一次无谓的失效）
		case placed(indicator: Indicator?, layout: PanelLayout?)
	}

	/// 拖动中按指针重算预览。调用方须先确认 CardDragState.isDragging——未越过激活阈值时
	/// 旧实现一行状态都不写，这里保持同一前提，不做兜底。位移始终以起拖瞬间固化的 frame
	/// 为基准，预览重排刷新 frame 表也不回灌落点计算——防反馈振荡。
	nonisolated static func preview(
		drag: CardDragState,
		base: PanelLayout,
		table: CardDropResolver.FrameTable
	) -> Preview {
		guard let target = CardDropResolver.resolve(point: drag.pointer, table: table, excluding: drag.card) else {
			return .cleared
		}
		let line = CardDropResolver.indicatorLine(for: target, table: table, excluding: drag.card)
		let candidate = PanelFlow.insertLayout(base, card: drag.card, target: target)
		return .placed(
			indicator: line.map { Indicator(x: $0.x, y: $0.y, width: $0.width) },
			layout: candidate == base ? nil : candidate
		)
	}

	/// 松手（onEnded）清理判定：结束卡缺省（兜底通道）或结束卡就是当前拖拽卡时才清拖拽态。
	/// 幽灵手势（别的卡的手势结束）不得清掉正在进行的拖拽，否则预览与指示线凭空消失。
	nonisolated static func clearsOnEnd(draggingCard: String?, endingCard: String?) -> Bool {
		endingCard == nil || draggingCard == endingCard
	}

	/// 松手落盘判定：必须真拖过（越过激活阈值）、结束卡对得上、且有最后一次合法预览。
	/// 返回要提交的预览布局（调用方负责归一后写配置）；nil = 不提交（丢弃回弹/空拖）。
	/// **不用 frame 表重解落点**：探针在布局动画中异步写表，松手时可能是预览前旧序，
	/// 重解会落错槽或静默丢弃；预览布局就是最后一次合法落点的插入结果。
	nonisolated static func commit(
		drag: CardDragState?,
		preview: PanelLayout?,
		endingCard: String?
	) -> PanelLayout? {
		guard let drag, drag.isDragging,
			  endingCard.map({ drag.card == $0 }) ?? true,
			  let preview else { return nil }
		return preview
	}

	/// 把手悬停的写入判定：拖动中一律不写（指针拖卡划过谁谁就放大；且拖动开始后写入的悬停态
	/// 会在松手后让旧卡带着放大复活）；常态进入 → 写卡 id，离开 → 写空。
	nonisolated enum HoverUpdate: Equatable {
		case keep
		case set(String?)
	}

	nonisolated static func hoverUpdate(isDragging: Bool, hovering: Bool, id: String) -> HoverUpdate {
		guard !isDragging else { return .keep }
		return .set(hovering ? id : nil)
	}
}

// MARK: - 布局编辑态（播种 / 落盘 / 收尾）

/// 布局编辑态的语义：编辑开关、工作副本、进入时的种子、隐藏托盘开合。
/// 状态本体仍由视图持有——这里只搬"进入时怎么播种、退出时落不落盘、收尾写哪些值"，
/// 调用方的写入序列与旧实现逐条一致。
nonisolated enum PanelLayoutEdit {
	/// 进入编辑 / 起拖时播种工作副本：已持久化的自定义布局优先；否则把面板打开期间冻结的
	/// 双列按索引对齐成行（列内相对序保留）。归一保证未知/重复/隐藏卡不残留，
	/// 缺失的已知卡追加末尾单行。
	nonisolated static func seed(
		panelLayout: PanelLayout?,
		assignedLeft: [String],
		assignedRight: [String],
		known: Set<String>
	) -> PanelLayout {
		PanelFlow.normalize(
			panelLayout ?? PanelLayout(rows: PanelFlow.alignColumns(left: assignedLeft, right: assignedRight)),
			known: known
		)
	}

	/// 退出编辑（保存）的落盘判定：归一后与种子相同 → nil（不落盘）。
	/// 未改动不落盘是为了防止"进编辑什么都不动、保存后列式对齐变行式平白长高一截"。
	/// 这是「完成」按钮的唯一判据（按钮本身始终可点，改动与否在这里收口）。
	nonisolated static func persistOnExit(
		draft: PanelLayout,
		seed: PanelLayout,
		known: Set<String>
	) -> PanelLayout? {
		let normalized = PanelFlow.normalize(draft, known: known)
		return normalized == seed ? nil : normalized
	}

	/// 「完成」是否有实际改动可保存（= persistOnExit 非 nil）。只读判定，不改按钮可用性。
	nonisolated static func hasChanges(draft: PanelLayout, seed: PanelLayout, known: Set<String>) -> Bool {
		persistOnExit(draft: draft, seed: seed, known: known) != nil
	}

	/// 退出编辑的收尾状态：取消或未改动都不落盘；编辑开关关闭、种子清空、隐藏托盘收起。
	nonisolated struct Exit: Equatable {
		var persist: PanelLayout?
		var isEditing: Bool
		var seed: PanelLayout?
		var trayExpanded: Bool
	}

	nonisolated static func exit(
		draft: PanelLayout,
		seed: PanelLayout?,
		save: Bool,
		known: Set<String>
	) -> Exit {
		Exit(
			persist: save ? seed.flatMap { persistOnExit(draft: draft, seed: $0, known: known) } : nil,
			isEditing: false,
			seed: nil,
			trayExpanded: false
		)
	}
}

// MARK: - 渲染路径判定（行表 / 双列）

/// 华容网格 v4 的渲染路径判定：自定义布局/编辑/拖拽走显式行存储（渲染即存储，
/// 预览=落盘=重开）；纯自动模式走会话冻结的贪心双列独立堆叠（高度最优、不洗牌）。
nonisolated enum PanelLayoutRouting {
	nonisolated struct Source: Equatable {
		/// true = 走行表密铺；false = 走贪心双列
		var usingRows: Bool
		/// 行表来源：拖拽预览 > 编辑/拖拽工作副本 > 已持久化布局 > 空板
		var layout: PanelLayout
	}

	/// 双路径判定与行表来源优先级（逐条对应旧 body 里的两个表达式）。
	/// 注意 usingRows 的第一个条件是"双列"：单列面板即使有自定义布局也不走行表。
	nonisolated static func source(
		twoColumns: Bool,
		isEditing: Bool,
		isDragging: Bool,
		preview: PanelLayout?,
		draft: PanelLayout,
		persisted: PanelLayout?
	) -> Source {
		Source(
			usingRows: twoColumns && (isEditing || isDragging || persisted != nil),
			layout: preview ?? (isEditing || isDragging ? draft : nil) ?? persisted ?? PanelLayout()
		)
	}
}
