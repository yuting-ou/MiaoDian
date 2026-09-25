import AppKit
import Combine
import Darwin
import SwiftUI

// 面板渲染成本量具（仅开发用，不进构建产物）：把真面板装进真窗口（屏幕外）、驱动真
// NSScrollView 按帧节奏滚动，量主线程每帧忙多久，以及"面板只是开着"要烧多少。
//
// 为什么需要它：用户报"滑动特别掉帧"，而"掉帧"是主观词。上一轮我按感觉把头部呼吸点
// 划成"不用关"、按感觉卸过陪滚探针，手里没有一把尺，所以改完还是卡。
//
// 能力边界（读它的数之前先看，别把这张表当"不卡证明"）：
//   ✓ 量得到：**每格**（一次位移 + 其后一段 runloop 排空）主线程忙时的分布、静置期占空比、
//     宿主 layout 轮次在时间上的分布、整段滚动状态翻转次数、空转步数
//     （单位必须是"每格"：一格会摊成十几帧，除以帧数等于把尖峰自己糊平——v2.9.15 第一版就栽过）
//   ✗ 量不到 GPU：玻璃/模糊的合成代价不在这条轴上。它只能证"这个改动省了 X µs/格"
//     或"这里不是热点"；"顺不顺"最终仍要眼睛验收
//   ✗ 窗口摆在屏幕外（-6000）会把每拍成本放大约 2×（同族量具实测过这个形状）：
//     绝对值只当参考，结论一律用"同机同偏好同卡片集、改动前后各跑一次"的差值
//   ✗ **一个进程里活着的 SwiftUI 图形对象会互相污染静置读数**：多建一个面板图（哪怕
//     只是量自然高的探针）就让 ⓪ 静置占空从 6~7% 变成 18~19%。所以静置只看
//     `idle` 模式那条单图路径；①②③ 只在同一次运行内互比
//   ✗ 单次操作的忙时常常低于 CLOCK_THREAD_CPUTIME_ID 的分辨率（实测恒 0）：
//     所以每帧忙时是"一整段滚动窗口的总忙时 ÷ 帧数"，不是逐帧读表
//   ✗ 数 layout 轮次要 runtime 换掉 PanelHostingView.layout 的 IMP。已实测这件仪器
//     本身不改变成本（装/不装计数器：静置 17.1% vs 18.5% 占空，同表交替），
//     但它是"看别人干活"而不是"别人干活"，别把它当被测对象
//
// 用法：bash 工具/滚动成本.sh [静置秒=10] [每种节奏步数=40]
// 口径：改动前后各跑一次同一命令；比 ①②③ 的"每帧总忙"和"翻转次数"，以及 ⓪ 的占空比

/// 宿主 layout() 轮次与探针计数（@convention(c) 的替身不能捕获上下文，一律走全局）
nonisolated(unsafe) var layoutPasses = 0
nonisolated(unsafe) var originalLayoutIMP: IMP?
nonisolated(unsafe) var hostLayoutSwizzled = false
nonisolated(unsafe) var publishCount = 0
nonisolated(unsafe) var publishSubs: [AnyCancellable] = []

/// 数"面板这段时间在反复重排多少轮"。PanelHostingView 是 final，不能继承加计数，
/// 于是把它的 layout IMP 换成"先自增再转调原实现"
func swizzleHostLayout() {
	guard !hostLayoutSwizzled else { return }
	hostLayoutSwizzled = true
	let selector = NSSelectorFromString("layout")
	guard let method = class_getInstanceMethod(PanelHostingView.self, selector) else {
		print("  ✗ 拿不到 PanelHostingView.layout，轮次计数不可用")
		return
	}
	typealias Impl = @convention(c) (AnyObject, Selector) -> Void
	originalLayoutIMP = method_getImplementation(method)
	let replacement: Impl = { target, command in
		layoutPasses += 1
		guard let raw = originalLayoutIMP else { return }
		unsafeBitCast(raw, to: Impl.self)(target, command)
	}
	method_setImplementation(method, unsafeBitCast(replacement, to: IMP.self))
}

/// 滚动状态翻转计数
final class FlipCounter {
	var flips = 0
	var cancellable: AnyCancellable?
}

@main
struct ScrollCostProbe {
	/// 一帧预算：120Hz ProMotion 8.3ms（报告里不直接拿每格比它，见 report 的口径注释）
	static let frameBudget120: Double = 8_300_000

	static func main() {
		let args = CommandLine.arguments.dropFirst()
		let idleSeconds = args.first.flatMap(Int.init) ?? 10
		let steps = args.dropFirst().first.flatMap(Int.init) ?? 40
		// idle 模式：只量"面板开着不滚"的重排级联，budget=no 时不给滚动预算（树里没有 NSScrollView）
		// 用来判那条 2 秒一簇的级联到底来自滚动容器还是数据发布本身
		if args.first == "idle" {
			idleOnly(scrollable: (args.dropFirst().first ?? "yes") != "no")
			return
		}
		NSApplication.shared.setActivationPolicy(.accessory)

		let monitor = BatteryMonitor()
		let historyRecorder = BatteryHistoryRecorder(monitor: monitor, defaults: .standard, backupDirectory: nil)
		let configurationManager = ConfigurationManager.shared
		let alertController = BatteryAlertController(
			monitor: monitor, configurationManager: configurationManager, historyRecorder: historyRecorder
		)
		let makeRoot: (CGFloat?) -> AnyView = { budget in
			AnyView(BatteryPopoverView(
				monitor: monitor,
				configurationManager: configurationManager,
				historyRecorder: historyRecorder,
				alertController: alertController,
				allowsCardDrag: budget == nil,
				cardBudgetHeight: budget
			))
		}

		print("== 面板渲染成本（真窗口·屏幕外·主线程 CPU；绝对值只认同表对比）==")
		// 两遍布局与生产 MenuBarPanelController 同法：先无预算量自然高，再按预算决定要不要滚
		let natural = fittingSize(of: makeRoot(nil), width: 584)
		let visible = NSScreen.main?.visibleFrame.height ?? 900
		let fit = PanelFit.budget(naturalHeight: natural.height, visibleFrameHeight: visible, chromeHeight: 0)
		// 本机自然高 960 < 可视 987 → 生产态根本不滚。量滚动必须钉矮预算，模拟小屏/单列会滚的用户
		let budget: CGFloat = fit.scrolls ? fit.availableHeight : min(600, natural.height - 120)
		print(String(format: "  自然高 %.0fpt · 可视高 %.0fpt · 本轮预算 %.0fpt · 充电=%d 电量 %@",
					 natural.height, visible, budget,
					 monitor.snapshot.isCharging ? 1 : 0,
					 monitor.snapshot.stateOfChargePercent.map { "\($0)%" } ?? "读不到"))

		let host = PanelHostingView(rootView: makeRoot(budget))
		host.frame = NSRect(x: 0, y: 0, width: 584, height: budget)
		let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 584, height: budget),
							 styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = host
		window.isReleasedWhenClosed = false
		if ProcessInfo.processInfo.environment["NO_SWIZZLE"] == nil {
			swizzleHostLayout()
		}
		window.orderFrontRegardless()
		drain(seconds: 2)   // 让 onAppear 走完（轮询启动、级联落位），否则量的是入场动画

		// ⓪ 静置：轮次按 100ms 分桶。桶齐平 = 自持循环在逐帧转；
		//    一簇爆高其余为 0 = 每次数据 tick 引发一轮重排级联（本轮实测是后者，约 2 秒一簇）
		// 发布计数：分清"900 轮布局"是**发布风暴**（每次 objectWillChange 一轮）
		// 还是**布局不稳**（一次发布摊成几百轮）——两种病的药完全不同
		var monitorPublishes = 0
		var recorderPublishes = 0
		let pubSubs = [
			monitor.objectWillChange.sink { _ in monitorPublishes += 1 },
			historyRecorder.objectWillChange.sink { _ in recorderPublishes += 1 }
		]
		var buckets: [Int] = []
		var last = layoutPasses
		let idleCPU0 = threadCPU()
		let idleWall0 = Date()
		for _ in 0..<(idleSeconds * 10) {
			drain(seconds: 0.1)
			buckets.append(layoutPasses - last)
			last = layoutPasses
		}
		let idleBusy = max(0, threadCPU() - idleCPU0)
		let idleWall = max(0.001, Date().timeIntervalSince(idleWall0))
		print(String(format: "  ⓪ 静置 %ds：主线程忙 %.0fms（%.1f%% 占空）· layout %.0f 轮/秒",
					 idleSeconds, idleBusy * 1000, idleBusy / idleWall * 100, Double(layoutPasses) / idleWall))
		print("  ⓪ layout 分桶（每 100ms）：\(buckets.map { String($0) }.joined(separator: " "))")
		print(String(format: "  ⓪ 同窗口发布计数：monitor %d 次 · historyRecorder %d 次（对照 %.0f 轮布局）",
					 monitorPublishes, recorderPublishes, Double(layoutPasses)))
		pubSubs.forEach { $0.cancel() }

		guard let scroll = findScrollView(in: host) else {
			print("  ✗ 树里没有 NSScrollView → ①②③ 无从测量")
			return
		}
		let clip = scroll.contentView
		print(String(format: "  卡片区：内容高 %.0fpt · 可视高 %.0fpt · NSView 树 %d 个",
					 clip.documentView?.frame.height ?? 0, clip.bounds.height, countViews(in: host)))
		report("① 连滚 4ms/帧（触控板）",
			   runScroll(scroll: scroll, clip: clip, window: window, steps: steps * 10, pace: 0.004))
		report("② 逐格 150ms/帧（滚轮）",
			   runScroll(scroll: scroll, clip: clip, window: window, steps: steps, pace: 0.150))
		report("③ 逐格 500ms/帧（慢慢一格一格）",
			   runScroll(scroll: scroll, clip: clip, window: window, steps: steps / 2 + 1, pace: 0.500))
		window.orderOut(nil)
	}

	/// 只量静置：budget=no（不可滚）与 yes（钉矮到 600pt）各跑一次，比对 100ms 分桶
	static func idleOnly(scrollable: Bool) {
		NSApplication.shared.setActivationPolicy(.accessory)
		let monitor = BatteryMonitor()
		let historyRecorder = BatteryHistoryRecorder(monitor: monitor, defaults: .standard, backupDirectory: nil)
		let configurationManager = ConfigurationManager.shared
		let alertController = BatteryAlertController(
			monitor: monitor, configurationManager: configurationManager, historyRecorder: historyRecorder
		)
		let root = AnyView(BatteryPopoverView(
			monitor: monitor, configurationManager: configurationManager,
			historyRecorder: historyRecorder, alertController: alertController,
			allowsCardDrag: !scrollable, cardBudgetHeight: scrollable ? 600 : nil
		))
		let host = PanelHostingView(rootView: root)
		host.frame = NSRect(x: 0, y: 0, width: 584, height: 600)
		let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 584, height: 600),
							 styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = host
		window.isReleasedWhenClosed = false
		swizzleHostLayout()
		publishSubs = [
			monitor.objectWillChange.sink { _ in publishCount += 1 },
			historyRecorder.objectWillChange.sink { _ in publishCount += 1 },
		]
		window.orderFrontRegardless()
		drain(seconds: 2)
		var buckets: [Int] = []
		var last = layoutPasses
		let cpu0 = threadCPU()
		let wall0 = Date()
		for _ in 0..<100 {
			drain(seconds: 0.1)
			buckets.append(layoutPasses - last)
			last = layoutPasses
		}
		let busy = max(0, threadCPU() - cpu0)
		let wall = max(0.001, Date().timeIntervalSince(wall0))
		print(String(format: "  idle(scrollable=%@)：%.1f%% 占空 · %.0f 轮/秒 · 发布 %@ 次",
					 scrollable ? "yes" : "no", busy / wall * 100, Double(layoutPasses) / wall,
					 String(publishCount)))
		print("  分桶：" + buckets.map { String($0) }.joined(separator: " "))
		window.orderOut(nil)
	}

	// MARK: - 一条节奏

	struct ScrollRun {
		var perFrame = 0.0
		/// 滚动窗口内主线程占空比
		var duty = 0.0
		/// 每一格（一次位移 + 排空）的忙时样本
		var perNotch: [Double] = []
		/// 有多少步实际没产生位移（顶死/空转）——非 0 就说明这条腿量的不是滚动
		var stuckSteps = 0
		var flips = 0
		var moved: CGFloat = 0
		var stillScrolling = false
		var steps = 0
	}

	/// 按给定节奏滚 steps 帧：每帧滚 5pt、强制 display、再让 runloop 呼吸 pace 秒
	static func runScroll(scroll: NSScrollView, clip: NSClipView, window: NSWindow,
						  steps: Int, pace: TimeInterval) -> ScrollRun {
		clip.scroll(to: .zero)
		scroll.reflectScrolledClipView(clip)
		drain(seconds: 0.6)   // 把复位造成的重排排出去，别算进第一帧
		let counter = FlipCounter()
		counter.cancellable = PanelScrollActivity.shared.$isScrolling
			.removeDuplicates()
			.dropFirst()     // 订阅即回放当前值，那不算一次翻转
			.sink { _ in counter.flips += 1 }
		var perNotch: [Double] = []
		let cpu0 = threadCPU()
		let wall0 = Date()
		let maxY = max(0, (clip.documentView?.frame.height ?? 0) - clip.bounds.height)
		var direction: CGFloat = 1
		var stuck = 0
		for _ in 0..<steps {
			// 一格 = 一次位移 + 之后 pace 秒的 runloop 排空（翻转的活就落在这一格里）
			// 到底/到顶就反向：单向滚会在十几格后顶死，之后的"步数"量的其实是不滚的静置
			var y = clip.bounds.origin.y + direction * 5
			if y >= maxY || y <= 0 {
				direction = -direction
				y = clip.bounds.origin.y + direction * 5
			}
			let before = clip.bounds.origin.y
			let notchCPU0 = threadCPU()
			clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
			scroll.reflectScrolledClipView(clip)
			window.contentView?.displayIfNeeded()
			drain(seconds: pace)
			perNotch.append(max(0, threadCPU() - notchCPU0))
			if abs(clip.bounds.origin.y - before) < 0.5 { stuck += 1 }
		}
		let busy = max(0, threadCPU() - cpu0)
		let wall = max(0.001, Date().timeIntervalSince(wall0))
		return ScrollRun(perFrame: busy / Double(max(1, steps)), duty: busy / wall, perNotch: perNotch,
						 stuckSteps: stuck, flips: counter.flips,
						 moved: clip.bounds.origin.y,
						 stillScrolling: PanelScrollActivity.shared.isScrolling, steps: steps)
	}

	static func report(_ label: String, _ run: ScrollRun) {
		// 口径：**每格**（一次位移 + 其后 pace 秒排空）而不是每帧——一步触控板滚动会摊成十几帧，
		// 拿每格去除帧数会把它糊平成"看着不大"的数。分布才说明集中与否：一格里若真有 49ms，
		// 那 49ms 是连续烧在少数几帧上的（超预算的是那几帧），不是平摊
		// 格式串与参数个数必须一一对应：多一个 %@ 就是把 Double 当对象发给 objc → 直接段错误（实测）
		let sorted = run.perNotch.sorted()
		func q(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] * 1000 }
		print(String(format: "  %@每格忙时 均值 %@ · p50 %@ · p95 %@ · 峰值 %@ · 占空 %.0f%% · 整段翻转 %d 次 · 空转 %d 步 · 收尾滚动态 %@",
					 label.padding(toLength: 30, withPad: " ", startingAt: 0),
					 fmtMs(run.perFrame * 1000), fmtMs(q(0.5)), fmtMs(q(0.95)), fmtMs(q(1.0)),
					 run.duty * 100, run.flips, run.stuckSteps, run.stillScrolling ? "true" : "false"))
	}

	// MARK: - 小工具

	static func fittingSize(of view: AnyView, width: CGFloat) -> NSSize {
		let host = NSHostingView(rootView: view)
		host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
		host.layoutSubtreeIfNeeded()
		return host.fittingSize
	}

	/// 线程 CPU 时间（秒）：只算真正占着 CPU 的时间，不含 sleep
	static func threadCPU() -> Double {
		var ts = timespec()
		guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) == 0 else { return 0 }
		return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
	}

	static func fmtMs(_ v: Double) -> String {
		v >= 1 ? String(format: "%.1fms", v) : String(format: "%.0fµs", v * 1000)
	}

	/// 跑掉一段墙钟时间（让 onAppear / 通知 / 渲染真的被处理）
	static func drain(seconds: Double) {
		let end = Date().addingTimeInterval(seconds)
		while Date() < end {
			RunLoop.current.run(until: Date().addingTimeInterval(0.001))
		}
	}

	static func findScrollView(in root: NSView) -> NSScrollView? {
		if let scroll = root as? NSScrollView { return scroll }
		for sub in root.subviews {
			if let found = findScrollView(in: sub) { return found }
		}
		return nil
	}

	static func countViews(in root: NSView) -> Int {
		1 + root.subviews.reduce(0) { $0 + countViews(in: $1) }
	}
}
