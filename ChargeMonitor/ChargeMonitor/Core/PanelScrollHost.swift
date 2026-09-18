import AppKit
import SwiftUI

/// 滚动活动：面板卡片区正在被滚动时为 true。
/// 用途：动效门、monitor 暂缓发布。打开面板时 reset()。
@MainActor
final class PanelScrollActivity: ObservableObject {
	static let shared = PanelScrollActivity()

	@Published private(set) var isScrolling = false
	private var idleTask: Task<Void, Never>?

	func reset() {
		idleTask?.cancel()
		idleTask = nil
		isScrolling = false
	}

	func noteScrollActivity() {
		if !isScrolling {
			isScrolling = true
		}
		idleTask?.cancel()
		idleTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: PanelScrollIdle.idleNanoseconds)
			if !Task.isCancelled {
				self.isScrolling = false
			}
		}
	}
}

/// 面板内容宿主：在自建 NSPanel 上承载整棵 SwiftUI 树。
///
/// layout 里**不**无条件 DFS 整树（滚动时会每帧执行）；仅当
/// 「窗口挂上后异步扫过一次」或「子孙 NSScrollView 集合签名变化」时才拧旋钮。
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
