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
//   ✗ **步数(steps)就是窗口长度**：改 steps 等于换条件——12 格只跨 1~2 个数据发布周期，
//     40 格跨 3~4 个，"平均成本"与"某类样本凑不凑得到"都不一样。A/B 必须钉死同一组参数
//     （v2.9.16 轮里我拿 steps=12 的消融去比 steps=40 的基线，得出过一个假结论）
//   ✗ 事件类样本天生稀少：一次滚动通常只有"起手/停手"两次翻转，②③ 各凑不出 3 条。
//     所以有 ④ 起停序列（连滚几格→停手→再连滚，重复十几组）；单条样本的差值只算线索不算结论
//   ✗ 每格样本要按"这格里发生了哪些事件"分类再比（④ 与每格 2×2 干的就是这件事）：
//     翻转与数据发布常落进同一格，混着数会把 tick 的 300ms 算到翻转头上
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
//      bash 工具/滚动成本.sh idle [yes|no] → 只量「面板开着不滚」的重排级联
// 口径：改动前后各跑一次**同一组参数**；比 ①②③ 的每格分布、④ 的起手/停手/中间三堆、
//      以及 ⓪ 的占空比/级联簇（**只是"连续非零桶"的分布**，没在簇内打发布戳，
//      不能直接当"一簇=一次发布"；与同窗口的发布计数并排读）/发布普查（抽若干字段）

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

/// 发布计数（一格里有几次 @Published 落地）
final class PublishCounter {
	var n = 0
	var subs: [AnyCancellable] = []
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
		// 注：想用 `.environment(\.accessibilityReduceMotion, true)` 从外部注入"减少动态效果"
		// 来判别级联是不是动画帧——这条路不通：该键在 EnvironmentValues 里只读
		// （编译报 "cannot convert to WritableKeyPath"），只能改系统设置，那是用户的地盘，不碰。
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
		// 发布普查：抽若干字段数一遍，找出"这轮到底是谁在发"——
		// 每次 @Published 赋值都发一次，哪怕值没变；先看见才谈得上修。
		// 两个坑（审查抓到）：① `Published` 订阅即回放当前值，那**不是一次发布**，必须 dropFirst；
		// ② 这些订阅活到下面所有窗口，所以计数窗口要按"实测秒数"报，别写死 idleSeconds
		var census: [(name: String, count: Int)] = []
		func tally<T: Equatable>(_ name: String, _ publisher: AnyPublisher<T, Never>) -> AnyCancellable {
			census.append((name, 0))
			let idx = census.count - 1
			return publisher.dropFirst().removeDuplicates().sink { _ in census[idx].count += 1 }
		}
		func raw<T>(_ name: String, _ publisher: AnyPublisher<T, Never>) -> AnyCancellable {
			census.append((name, 0))
			let idx = census.count - 1
			return publisher.dropFirst().sink { _ in census[idx].count += 1 }
		}
		let pubSubs = [
			monitor.objectWillChange.sink { _ in monitorPublishes += 1 },
			historyRecorder.objectWillChange.sink { _ in recorderPublishes += 1 },
			raw("monitor.snapshot", monitor.$snapshot.eraseToAnyPublisher()),
			raw("monitor.powerSamples", monitor.$powerSamples.eraseToAnyPublisher()),
			raw("monitor.temperatureSamples", monitor.$temperatureSamples.eraseToAnyPublisher()),
			raw("monitor.drainEstimate", monitor.$drainEstimate.eraseToAnyPublisher()),
			raw("monitor.bluetoothDevices", monitor.$bluetoothDevices.eraseToAnyPublisher()),
			raw("monitor.significantEnergyApps", monitor.$significantEnergyApps.eraseToAnyPublisher()),
			raw("recorder.hourlyTempStats", historyRecorder.$hourlyTempStats.eraseToAnyPublisher()),
			raw("recorder.hourlyDrainStats", historyRecorder.$hourlyDrainStats.eraseToAnyPublisher()),
			raw("recorder.socSamples", historyRecorder.$socSamples.eraseToAnyPublisher()),
			raw("recorder.dailyHistory", historyRecorder.$dailyHistory.eraseToAnyPublisher()),
			raw("recorder.appEnergy", historyRecorder.$appEnergy.eraseToAnyPublisher()),
			tally("recorder.hourlyTempStats(去重)", historyRecorder.$hourlyTempStats.eraseToAnyPublisher()),
			tally("monitor.drainEstimate(去重)", monitor.$drainEstimate.eraseToAnyPublisher()),
		]
		var buckets: [Int] = []
		// 同窗口 CPU 分桶（ms）：一簇非零桶 ≈ 一次发布引发的级联。两列并排就能读出
		// "一次发布值多少毫秒主线程"——静置占空与"停手补发"的卡顿是同一个源头
		var cpuBuckets: [Int] = []
		var last = layoutPasses
		let idleCPU0 = threadCPU()
		let idleWall0 = Date()
		var lastCPUms = idleCPU0 * 1000
		for _ in 0..<(idleSeconds * 10) {
			drain(seconds: 0.1)
			buckets.append(layoutPasses - last)
			last = layoutPasses
			let cpuMs = threadCPU() * 1000
			cpuBuckets.append(Int(cpuMs - lastCPUms))
			lastCPUms = cpuMs
		}
		// 先把静置窗口的订阅全部停下再打印：否则下面的节奏窗口会继续往同一批计数器里加，
		// 打印出来的"静置 N 秒"就成了横跨两个窗口的账（审查抓到过这个错位）
		let censusEndCPU = threadCPU()
		pubSubs.forEach { $0.cancel() }
		let idleBusy = max(0, censusEndCPU - idleCPU0)
		let idleWall = max(0.001, Date().timeIntervalSince(idleWall0))
		print(String(format: "  ⓪ 静置 %.1fs：主线程忙 %.0fms（%.1f%% 占空）· layout %.0f 轮/秒",
					 idleWall, idleBusy * 1000, idleBusy / idleWall * 100, Double(layoutPasses) / idleWall))
		// 代表性别自检：开头那次打印可能赶在首帧 IO 之前，"电量读不到"若贯穿整窗，
		// 这块表量的就是空态面板——绝对值与"用户手里那块板"不可比（v2.9.15 的数就吃过这个暗亏）
		print("  ⓪ 窗口末状态：电量 \(monitor.snapshot.stateOfChargePercent.map { "\($0)%" } ?? "仍读不到")"
			+ " · 功率采样 \(monitor.powerSamples.count) 点 · 温度采样 \(monitor.temperatureSamples.count) 点"
			+ " · 面板高 \(Int(fittingSize(of: makeRoot(budget), width: 584).height))pt")
		print("  ⓪ layout 分桶（每 100ms）：\(buckets.map { String($0) }.joined(separator: " "))")
		print("  ⓪ CPU 分桶（ms，同窗口同刻度）：\(cpuBuckets.map { String($0) }.joined(separator: " "))")
		// 把"连续非零的 layout 桶"并成一簇。注意：**这只是分布，不是一条簇=一次发布**——
		// 没在簇里打到达戳，一次级联若被一个零桶劈开就会数成两簇（如实标注，别拿它当因果）
		var clusters: [(rounds: Int, cpuMs: Int)] = []
		var rounds = 0
		var clusterCPU = 0
		var open = false
		for i in buckets.indices {
			if buckets[i] > 0 {
				rounds += buckets[i]
				clusterCPU += i < cpuBuckets.count ? cpuBuckets[i] : 0
				open = true
			} else if open {
				clusters.append((rounds, clusterCPU))
				rounds = 0; clusterCPU = 0; open = false
			}
		}
		if open { clusters.append((rounds, clusterCPU)) }   // 末尾被窗口切到的半簇也如实列出
		let sortedClusterCPU = clusters.map { $0.cpuMs }.sorted()
		let sortedClusterRounds = clusters.map { $0.rounds }.sorted()
		print("  ⓪ 级联簇 \(clusters.count) 个（非零桶并簇；未与发布对齐，仅供分布对比）："
			+ clusters.map { "\($0.cpuMs)ms/\($0.rounds)轮" }.joined(separator: " ")
			+ "｜中位 \(sortedClusterCPU.isEmpty ? 0 : sortedClusterCPU[sortedClusterCPU.count / 2])ms "
			+ "\(sortedClusterRounds.isEmpty ? 0 : sortedClusterRounds[sortedClusterRounds.count / 2]) 轮")
		print("  ⓪ 发布普查（抽若干字段；raw=每次赋值都算，去重=值真变了才算，两者之差=白发的发布）："
			+ census.filter { $0.count > 0 }.map { "\($0.name)=\($0.count)" }.joined(separator: " · "))
		print(String(format: "  ⓪ 同窗口发布计数：monitor %d 次 · historyRecorder %d 次（对照 %.0f 轮布局）",
					 monitorPublishes, recorderPublishes, Double(layoutPasses)))

		// 发布节奏归属（另开 6s 窗口）：每次发布到达时，报"距上次发布过了多少 ms、
		// 这期间烧掉多少轮布局"。用来分清一簇 ~900 轮是"每发一次各摊一轮级联"
		// 还是"多次发布被 SwiftUI 合并成一轮"——前者该减发布次数，后者减了也没用。
		var rhythm: [String] = []
		var lastRhythmAt = Date()
		var lastRhythmPasses = layoutPasses
		let rhythmSubs = [
			monitor.objectWillChange.dropFirst().sink { _ in
				let now = Date()
				rhythm.append(String(format: "M+%.0fms/%d轮",
									 now.timeIntervalSince(lastRhythmAt) * 1000,
									 layoutPasses - lastRhythmPasses))
				lastRhythmAt = now
				lastRhythmPasses = layoutPasses
			},
			historyRecorder.objectWillChange.dropFirst().sink { _ in
				let now = Date()
				rhythm.append(String(format: "R+%.0fms/%d轮",
									 now.timeIntervalSince(lastRhythmAt) * 1000,
									 layoutPasses - lastRhythmPasses))
				lastRhythmAt = now
				lastRhythmPasses = layoutPasses
			},
		]
		drain(seconds: 6)
		rhythmSubs.forEach { $0.cancel() }
		print("  ⓪ 发布节奏（6s，'+距上次ms/期间轮数'，M=monitor R=recorder）：\(rhythm.joined(separator: " "))")
		let lateRounds = rhythm.compactMap { Int($0.split(separator: "/").last.map { $0.dropLast() } ?? "") }
		if lateRounds.count > 3 {
			let tail = lateRounds.dropFirst(2).reduce(0, +)
			print(String(format: "  ⓪ 归属：稳定后 %d 次发布共摊 %d 轮 ≈ 每次发布 %.0f 轮",
						 lateRounds.count - 2, tail, Double(tail) / Double(lateRounds.count - 2)))
		}

		guard let scroll = findScrollView(in: host) else {
			print("  ✗ 树里没有 NSScrollView → ①②③ 无从测量")
			return
		}
		let clip = scroll.contentView
		print(String(format: "  卡片区：内容高 %.0fpt · 可视高 %.0fpt · NSView 树 %d 个",
					 clip.documentView?.frame.height ?? 0, clip.bounds.height, countViews(in: host)))
		report("① 连滚 4ms/帧（触控板）",
			   runScroll(scroll: scroll, clip: clip, window: window, monitor: monitor, recorder: historyRecorder,
						 steps: steps * 10, pace: 0.004))
		report("② 逐格 150ms/帧（滚轮）",
			   runScroll(scroll: scroll, clip: clip, window: window, monitor: monitor, recorder: historyRecorder,
						 steps: steps, pace: 0.150))
		report("③ 逐格 500ms/帧（慢慢一格一格）",
			   runScroll(scroll: scroll, clip: clip, window: window, monitor: monitor, recorder: historyRecorder,
						 steps: steps / 2 + 1, pace: 0.500))
		// ④ 起停序列：连滚几格→停到手→再连滚，把"起手/停手"两类翻转各凑 reps 个样本
		//    （②③ 的翻转样本各只有 1~2 条，够不着结论）
		reportSeries("④ 起停序列（每组连滚 3 格 150ms + 停 0.7s，共 \(max(6, steps / 2)) 组）",
					 runFlipSeries(scroll: scroll, clip: clip, window: window, monitor: monitor,
								   recorder: historyRecorder,
								   reps: max(6, steps / 2), notches: 3, pace: 0.15, gap: 0.7))
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
		/// 与 perNotch 一一对齐：这一格里滚动态翻转了几次
		var flipsPerNotch: [Int] = []
		/// 与 perNotch 一一对齐：这一格里落了几次 @Published 发布
		/// （不记这个，"含翻转的格"会把恰好同格的数据级联算成翻转的账——本轮实测错过一次）
		var publishesPerNotch: [Int] = []
		/// 有多少步实际没产生位移（顶死/空转）——非 0 就说明这条腿量的不是滚动
		var stuckSteps = 0
		var flips = 0
		var publishes = 0
		var moved: CGFloat = 0
		var stillScrolling = false
		var steps = 0
		/// 这条腿的步长（秒）——发布级联要按它算"拖尾几格"
		var pace: TimeInterval = 0
	}

	/// 按给定节奏滚 steps 帧：每帧滚 5pt、强制 display、再让 runloop 呼吸 pace 秒
	static func runScroll(scroll: NSScrollView, clip: NSClipView, window: NSWindow,
						  monitor: BatteryMonitor, recorder: BatteryHistoryRecorder,
						  steps: Int, pace: TimeInterval) -> ScrollRun {
		clip.scroll(to: .zero)
		scroll.reflectScrolledClipView(clip)
		drain(seconds: 0.6)   // 把复位造成的重排排出去，别算进第一帧
		let counter = FlipCounter()
		counter.cancellable = PanelScrollActivity.shared.$isScrolling
			.removeDuplicates()
			.dropFirst()     // 订阅即回放当前值，那不算一次翻转
			.sink { _ in counter.flips += 1 }
		// 同格子里还可能落进数据 tick 的级联——不分开就会把 tick 的账算到翻转头上（本轮实测错过）
		let pubs = PublishCounter()
		pubs.subs = [
			monitor.objectWillChange.sink { _ in pubs.n += 1 },
			recorder.objectWillChange.sink { _ in pubs.n += 1 },
		]
		var perNotch: [Double] = []
		var flipsPerNotch: [Int] = []
		var publishesPerNotch: [Int] = []
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
			let flips0 = counter.flips
			let pubs0 = pubs.n
			clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
			scroll.reflectScrolledClipView(clip)
			window.contentView?.displayIfNeeded()
			drain(seconds: pace)
			perNotch.append(max(0, threadCPU() - notchCPU0))
			flipsPerNotch.append(counter.flips - flips0)
			publishesPerNotch.append(pubs.n - pubs0)
			if abs(clip.bounds.origin.y - before) < 0.5 { stuck += 1 }
		}
		let busy = max(0, threadCPU() - cpu0)
		let wall = max(0.001, Date().timeIntervalSince(wall0))
		pubs.subs.forEach { $0.cancel() }
		return ScrollRun(perFrame: busy / Double(max(1, steps)), duty: busy / wall, perNotch: perNotch,
						 flipsPerNotch: flipsPerNotch, publishesPerNotch: publishesPerNotch,
						 stuckSteps: stuck, flips: counter.flips, publishes: pubs.n,
						 moved: clip.bounds.origin.y,
						 stillScrolling: PanelScrollActivity.shared.isScrolling, steps: steps, pace: pace)
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
		func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
		// 2×2 归属。两个坑都踩过，所以口径写死在这里：
		//   ① 翻转与数据 tick 会落进同一格 → 必须分类，不能混着数；
		//   ② **发布"到达"和它"烧完"不在同一格**：一次级联 ~320ms，150ms 的腿里要摊到后 2~3 格。
		//      只按到达那一格标记，就会把级联记到后面的"无发"格里，得出"发布不贵、闲格很贵"的假话。
		//      所以这里把发布**向后拖尾** carry = ⌈级联时长 / 步长⌉ 格。
		let carry = max(0, Int((0.32 / max(run.pace, 0.001)).rounded(.up)))
		func publishedAtOrBefore(_ i: Int) -> Bool {
			var k = max(0, i - carry)
			while k <= i {
				if k < run.publishesPerNotch.count && run.publishesPerNotch[k] > 0 { return true }
				k += 1
			}
			return false
		}
		func cell(_ label: String, _ pred: (Int) -> Bool) -> String {
			var xs: [Double] = []
			for i in run.perNotch.indices where i < run.flipsPerNotch.count && i < run.publishesPerNotch.count {
				if pred(i) { xs.append(run.perNotch[i]) }
			}
			let s = xs.sorted()
			return "\(label) n=\(xs.count) 均值 \(fmtMs(mean(xs) * 1000)) p50 \(fmtMs(s.isEmpty ? 0 : s[s.count / 2] * 1000)) 峰值 \(fmtMs((s.last ?? 0) * 1000))"
		}
		let hasFlip: (Int) -> Bool = { run.flipsPerNotch[$0] > 0 }
		let hasPub: (Int) -> Bool = { publishedAtOrBefore($0) }
		// 六格全列出来（缺格也会让 n 加不到 steps，看不出被谁吞了）：翻转次数×发布拖尾
		print("    └ 归属（发布按拖尾 \(carry) 格摊宽；步长 \(String(format: "%.0f", run.pace * 1000))ms）｜"
			+ cell("翻1·无发", { run.flipsPerNotch[$0] == 1 && !hasPub($0) })
			+ "｜" + cell("翻1+发", { run.flipsPerNotch[$0] == 1 && hasPub($0) })
			+ "｜" + cell("翻2+·无发", { run.flipsPerNotch[$0] >= 2 && !hasPub($0) })
			+ "｜" + cell("翻2++发", { run.flipsPerNotch[$0] >= 2 && hasPub($0) })
			+ "｜" + cell("无翻+发", { !hasFlip($0) && hasPub($0) })
			+ "｜" + cell("都不含", { !hasFlip($0) && !hasPub($0) }))
	}

	// MARK: - 起停序列（一次翻转值多少，靠重复起停凑样本）

	/// 每组 = 起手格（1 格，期待 false→true）→ 若干中间格（期待无翻转）→
	/// 停手窗（gap，期待 true→false）→ **等长静置对照窗**（再 gap，此时不该有任何翻转）。
	/// 每个窗口都**真的去数翻转次数与方向**：名不副实的样本单独计 miss，不混进统计
	/// （上一版按"位置"推断哪一格是起手/停手，审查抓到：一旦级联把主线程占住，
	///  true→false 可能落在停手窗之外，标签就成了瞎话）。
	struct FlipSeries {
		/// 一个窗口 = 一段忙时 + 窗内到达的发布条数 + 窗内真发生的翻转方向。
		/// `contaminated` = 本窗**或上一窗**有发布到达：一次级联 ~320ms，
		/// 上一窗尾部到达的发布，它烧掉的账会落进本窗——只按"本窗到达"分堆，
		/// 就会把带尾巴的窗算进"无发布"那堆（审查抓到的同一个坑，④ 里也会犯）
		struct Sample {
			var cost: Double
			var pubs: Int
			var contaminated = false
			var flippedToTrue = false
			var flippedToFalse = false
			var anyFlip = false
		}
		var start: [Sample] = []
		var stop: [Sample] = []
		var middle: [Sample] = []
		var control: [Sample] = []
		var startMiss = 0      // 起手格里没数到 false→true
		var stopMiss = 0       // 停手窗里没数到 true→false
		var controlFlip = 0    // 对照窗里竟有翻转（说明上一窗没清干净）
	}

	/// 按方向数翻转（sink 收到的是新值：true=起手，false=停手）
	final class PolarityCounter {
		var toTrue = 0
		var toFalse = 0
		var cancellable: AnyCancellable?
	}

	static func runFlipSeries(scroll: NSScrollView, clip: NSClipView, window: NSWindow,
							  monitor: BatteryMonitor, recorder: BatteryHistoryRecorder,
							  reps: Int, notches: Int, pace: TimeInterval, gap: TimeInterval) -> FlipSeries {
		var s = FlipSeries()
		let pubs = PublishCounter()
		pubs.subs = [
			monitor.objectWillChange.dropFirst().sink { _ in pubs.n += 1 },
			recorder.objectWillChange.dropFirst().sink { _ in pubs.n += 1 },
		]
		let flips = PolarityCounter()
		flips.cancellable = PanelScrollActivity.shared.$isScrolling
			.removeDuplicates().dropFirst()
			.sink { value in if value { flips.toTrue += 1 } else { flips.toFalse += 1 } }
		let maxY = max(0, (clip.documentView?.frame.height ?? 0) - clip.bounds.height)
		var direction: CGFloat = 1
		func step() -> FlipSeries.Sample {
			var y = clip.bounds.origin.y + direction * 5
			if y >= maxY || y <= 0 {
				direction = -direction
				y = clip.bounds.origin.y + direction * 5
			}
			let cpu0 = threadCPU()
			let p0 = pubs.n
			let t0 = flips.toTrue
			clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
			scroll.reflectScrolledClipView(clip)
			window.contentView?.displayIfNeeded()
			drain(seconds: pace)
			return FlipSeries.Sample(
				cost: max(0, threadCPU() - cpu0),
				pubs: pubs.n - p0,
				flippedToTrue: flips.toTrue > t0,
				anyFlip: flips.toTrue > t0
			)
		}
		func idleWindow() -> FlipSeries.Sample {
			let cpu0 = threadCPU()
			let p0 = pubs.n
			let f0 = flips.toFalse
			let t0 = flips.toTrue
			drain(seconds: gap)
			return FlipSeries.Sample(
				cost: max(0, threadCPU() - cpu0),
				pubs: pubs.n - p0,
				flippedToFalse: flips.toFalse > f0,
				anyFlip: flips.toFalse > f0 || flips.toTrue > t0
			)
		}
		// 发布级联会跨窗烧（一次 ~320ms，而窗口只有 gap 秒）：本窗"干净"不等于上一窗的
		// 尾巴没伸进来。所以分堆用「本窗或上一窗有发布到达」，并把拖尾单独说清楚
		var prevPubs = 0
		func classify(_ sample: FlipSeries.Sample) -> FlipSeries.Sample {
			var copy = sample
			copy.contaminated = sample.pubs > 0 || prevPubs > 0
			prevPubs = sample.pubs
			return copy
		}
		for _ in 0..<reps {
			// 起手格：真数到 false→true 才算一条样本，否则记 miss（不混进统计）
			let start = classify(step())
			if start.flippedToTrue { s.start.append(start) } else { s.startMiss += 1 }
			for _ in 0..<max(0, notches - 1) { s.middle.append(classify(step())) }
			// 停手窗：真数到 true→false 才算
			let stop = classify(idleWindow())
			if stop.flippedToFalse { s.stop.append(stop) } else { s.stopMiss += 1 }
			// 等长静置对照：同样长、同样排空，不该再有翻转
			let control = classify(idleWindow())
			s.control.append(control)
			if control.anyFlip { s.controlFlip += 1 }
		}
		flips.cancellable?.cancel()
		pubs.subs.forEach { $0.cancel() }
		return s
	}

	static func reportSeries(_ label: String, _ s: FlipSeries) {
		func stat(_ xs: [FlipSeries.Sample], requiringPub want: Bool? = nil) -> String {
			let picked = xs.filter { want == nil ? true : $0.contaminated == want! }
			let costs = picked.map { $0.cost }.sorted()
			func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
			let all = xs.map { $0.cost }
			return "n=\(picked.count)/\(xs.count) 均值 \(fmtMs(mean(costs) * 1000))"
				+ " p50 \(fmtMs(costs.isEmpty ? 0 : costs[costs.count / 2] * 1000))"
				+ " 峰值 \(fmtMs((costs.last ?? 0) * 1000))"
				+ (all.isEmpty ? "" : "（全体均值 \(fmtMs(mean(all) * 1000))）")
		}
		print("  \(label)")
		print("    起手格 false→true \(stat(s.start))（名不副实 \(s.startMiss) 格，已剔除）")
		print("    停手窗 true→false \(stat(s.stop))（没等到翻转 \(s.stopMiss) 窗，已剔除）")
		print("      ├ 停手·受发布污染 \(stat(s.stop, requiringPub: true))")
		print("      └ 停手·不受污染 \(stat(s.stop, requiringPub: false))")
		print("    等长静置对照 \(stat(s.control))（对照里竟有翻转 \(s.controlFlip) 窗）")
		print("      ├ 对照·受发布污染 \(stat(s.control, requiringPub: true))")
		print("      └ 对照·不受污染 \(stat(s.control, requiringPub: false))")
		print("    中间格（连滚中） \(stat(s.middle))")
		print("    读法：「不受污染」两行相减 ≈ 停手这件事自己的代价；"
			+ "污染 = 本窗**或上一窗**有发布到达（一次级联 ~320ms 会跨过窗口边界，只按本窗到达分堆会漏）")
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
