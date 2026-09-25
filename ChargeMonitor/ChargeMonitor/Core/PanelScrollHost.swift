import AppKit
import SwiftUI

/// 滚动活动：面板卡片区正在被滚动时为 true。
/// 用途：动效门、monitor 暂缓发布。打开面板时 reset()。
@MainActor
final class PanelScrollActivity: ObservableObject {
	static let shared = PanelScrollActivity()

	@Published private(set) var isScrolling = false
	private var idleTask: Task<Void, Never>?
	/// 用 `systemUptime`（开机以来的单调秒数）而不是 `Date`：`Task.sleep` 走的是连续时钟，
	/// 混用墙钟时一旦用户改系统时间/休眠唤醒把 Date 往回拨，"剩余量"就永远算不满，
	/// 面板会卡在滚动态里出不来（v2.9.15 审查 round2 抓到）
	private var lastActivityUptime = ProcessInfo.processInfo.systemUptime

	/// 距最后一次滚动过了多久（纳秒）。单调时钟相减不会为负；万一为负按 0 处理
	private func elapsedSinceLastActivityNanoseconds() -> UInt64 {
		let seconds = max(0, ProcessInfo.processInfo.systemUptime - lastActivityUptime)
		return UInt64(seconds * 1_000_000_000)
	}

	func reset() {
		idleTask?.cancel()
		idleTask = nil
		isScrolling = false
		lastActivityUptime = ProcessInfo.processInfo.systemUptime
	}

	/// 滚动事件可以每帧一次：这里只做一次赋值——每事件取消并重建 Task，
	/// 等于让"滚动本身"再叠一层主线程开销（120Hz 下每帧一个 Task）。
	/// 唯一的延时任务醒来后自己比对时间戳，没到静默时长就继续睡。
	func noteScrollActivity() {
		lastActivityUptime = ProcessInfo.processInfo.systemUptime
		if !isScrolling {
			isScrolling = true
		}
		guard idleTask == nil else { return }
		idleTask = Task { @MainActor in
			while true {
				// 睡前读一次，只为算"还差多少到点"；判定用的是醒来后那一次（下面 wokeAt）。
				// 固定再睡一整轮会把实际恢复窗口变成 400~800ms 的随机数，
				// 把手与动画的回来时间就没法承诺（v2.9.15 审查抓到）
				let elapsed = elapsedSinceLastActivityNanoseconds()
				try? await Task.sleep(nanoseconds: PanelScrollIdle.sleepNanoseconds(
					elapsedSinceLastActivityNanoseconds: elapsed
				))
				// 被 reset 取消就直接退出，**不要**去清 idleTask：那时它可能已指向新开的那个任务
				if Task.isCancelled { return }
				// 醒来再读一次：睡着期间可能又来了滚动事件
				let wokeAt = elapsedSinceLastActivityNanoseconds()
				if PanelScrollIdle.shouldClearScrolling(elapsedNanoseconds: wokeAt) {
					isScrolling = false
					idleTask = nil
					return
				}
			}
		}
	}
}

/// 面板内容宿主：在自建 NSPanel 上承载整棵 SwiftUI 树。
///
/// layout() 每轮都会扫一遍子孙找 NSScrollView（签名不变时不拧旋钮）。**这条扫描不是性能问题**：
/// 面板 AppKit 树只有 80~90 个节点，实测整树 DFS 低于本量具的时钟分辨率
/// （`bash 工具/滚动成本.sh`），v2.9.15 曾怀疑它是掉帧大户、加过节流与"只在值不同才写"，
/// 改完静置占空 16.9% → 17.8%（没动），故回滚——别再来查这一处。掉帧的两处真凶见
/// `PanelScrollIdle`（翻转代价）与 `PanelMotionGate.holdsDecorativeAnimation`（墙钟动画）。
@MainActor
final class PanelHostingView: NSHostingView<AnyView> {
	private var scrollObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
	private var lastTuneSignature = 0
	private var didScheduleInitialTune = false

	deinit {
		for token in scrollObservers.values {
			NotificationCenter.default.removeObserver(token)
		}
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard window != nil, !didScheduleInitialTune else { return }
		didScheduleInitialTune = true
		// 等 SwiftUI 把 ScrollView 建进树里再拧
		DispatchQueue.main.async { [weak self] in
			self?.tuneScrollDescendants()
		}
	}

	override func layout() {
		super.layout()
		// 仅在滚动视图集合签名变化时补扫（ScrollView 晚入树的情况）
		// —— 绝不在每帧 layout 里无条件 DFS
		retuneIfScrollViewSetChanged()
	}

	private func retuneIfScrollViewSetChanged() {
		var found: [NSScrollView] = []
		Self.collectScrollViews(in: self) { found.append($0) }
		let signature = found.reduce(0) { $0 ^ ObjectIdentifier($1).hashValue }
		guard signature != lastTuneSignature else { return }
		tuneScrollDescendants()
	}

	private func tuneScrollDescendants() {
		var found: [NSScrollView] = []
		Self.collectScrollViews(in: self) { found.append($0) }
		lastTuneSignature = found.reduce(0) { $0 ^ ObjectIdentifier($1).hashValue }

		var seen = Set<ObjectIdentifier>()
		for scroll in found {
			let id = ObjectIdentifier(scroll)
			seen.insert(id)
			scroll.drawsBackground = false
			scroll.horizontalScrollElasticity = .none
			// 纵向橡皮筋 = 苹果手感；由 PanelScrollElasticity 统一裁决
			scroll.verticalScrollElasticity = PanelScrollElasticity.allowsVerticalBounce ? .allowed : .none
			guard scrollObservers[id] == nil else { continue }
			scroll.contentView.postsBoundsChangedNotifications = true
			let token = NotificationCenter.default.addObserver(
				forName: NSView.boundsDidChangeNotification,
				object: scroll.contentView,
				queue: .main
			) { _ in
				MainActor.assumeIsolated {
					PanelScrollActivity.shared.noteScrollActivity()
				}
			}
			scrollObservers[id] = token
		}
		for (id, token) in scrollObservers where !seen.contains(id) {
			NotificationCenter.default.removeObserver(token)
			scrollObservers[id] = nil
		}
	}

	private static func collectScrollViews(in root: NSView, visit: (NSScrollView) -> Void) {
		if let scroll = root as? NSScrollView {
			visit(scroll)
		}
		for sub in root.subviews {
			collectScrollViews(in: sub, visit: visit)
		}
	}
}
