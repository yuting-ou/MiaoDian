import AppKit
import Combine
import SwiftUI

// 菜单栏承载：NSStatusItem 图标 + 自建透明 NSPanel。
// 为什么不用 MenuBarExtra(.window)：它的宿主窗口灰底由 SwiftUI 在 RootViewModifier 的
// 图层里绘制（视图树中没有任何 NSVisualEffectView），AppKit 手段够不到——
// 卡片玻璃只能采样那层灰底而非桌面，液态玻璃效果出不来。
// 自建面板窗口底全透明，玻璃直接采样桌面，与预览 harness 同架构（已验证通透）。
// 附带收益：面板可程序化打开（环境变量 MIAODIAN_DEBUG_OPEN_PANEL），视觉验收不再依赖手点图标。
@MainActor
final class MenuBarPanelController: NSObject, NSWindowDelegate {
	private let services = AppServices.shared
	private var statusItem: NSStatusItem?
	private var panel: NSPanel?
	// 面板因失焦刚关闭的时间戳：点菜单栏图标会先触发失焦关闭、再触发点击动作，
	// 不加这道闸就会"关而又开"，看起来像点了没反应
	private var lastClosedAt = Date.distantPast
	private var cancellables: Set<AnyCancellable> = []
	// 调试模式（MIAODIAN_DEBUG_OPEN_PANEL）下面板不因失焦自动关闭：
	// 无人值守截图时终端/前台应用会抢走 key 焦点，正常失焦关会让面板在截图前就消失
	private var debugKeepOpen = false

	func install() {
		let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem.button?.target = self
		statusItem.button?.action = #selector(togglePanel)
		statusItem.button?.sendAction(on: NSEvent.EventTypeMask.leftMouseDown)
		self.statusItem = statusItem

		let panel = GlassPopoverPanel(
			contentRect: NSRect(x: 0, y: 0, width: 292, height: 400),
			styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
			backing: .buffered, defer: false
		)
		panel.titlebarAppearsTransparent = true
		panel.titleVisibility = .hidden
		panel.isMovable = false
		panel.hidesOnDeactivate = false
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.level = .statusBar
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		panel.delegate = self
		self.panel = panel

		// 标签与面板共用数据源：任一状态变化重画按钮（流光/轮换由 iconAnimator 驱动）
		for publisher in [
			services.monitor.objectWillChange,
			services.configurationManager.objectWillChange,
			services.iconAnimator.objectWillChange,
			services.historyRecorder.objectWillChange,
		] {
			publisher.receive(on: RunLoop.main)
				.sink { [weak self] _ in self?.refreshLabel() }
				.store(in: &cancellables)
		}
		refreshLabel()

		// 调试通道：带环境变量启动时自动弹出面板，供无人值守截图验收。
		// 状态项就位时间不定（iBar 回流、系统繁忙都可能拖慢），0.6/2/5s 三次重试兜底；
		// 已可见则跳过，避免重复重建内容打断截图
		if ProcessInfo.processInfo.environment["MIAODIAN_DEBUG_OPEN_PANEL"] != nil {
			debugKeepOpen = true
			for delay in [0.6, 2.0, 5.0] {
				DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
					guard let self, self.panel?.isVisible != true else { return }
					self.showPanel()
				}
			}
		}
	}

	// MARK: - 面板开合

	@objc private func togglePanel() {
		if panel?.isVisible == true {
			closePanel()
		} else {
			// 失焦关闭与按钮动作在同一次点击里先后到达：刚关掉的不要立刻弹回
			guard Date().timeIntervalSince(lastClosedAt) > 0.25 else { return }
			showPanel()
		}
	}

	private func closePanel() {
		guard let panel, panel.isVisible else { return }
		lastClosedAt = Date()
		panel.orderOut(nil)
		// 摘掉内容视图（contentView 非可选，用空视图顶替）：触发 SwiftUI onDisappear → stopPolling，关闭期间零耗
		panel.contentView = NSView()
	}

	// 点面板外任意处 → 失焦即关（与 MenuBarExtra 行为一致）；调试模式豁免
	func windowDidResignKey(_ notification: Notification) {
		if debugKeepOpen { return }
		closePanel()
	}

	private func showPanel() {
		guard let panel, let button = statusItem?.button, let buttonWindow = button.window else { return }
		// 每次打开重建内容视图：@State 全新 → 入场级联动画重播、onAppear 驱动 startPolling，
		// 与 MenuBarExtra"面板每次打开销毁重建"的既有行为一致
		let root = BatteryPopoverView(
			monitor: services.monitor,
			configurationManager: services.configurationManager,
			historyRecorder: services.historyRecorder,
			alertController: services.alertController
		)
		let hosting = NSHostingView(rootView: root)
		panel.contentView = hosting

		let size = hosting.fittingSize
		panel.setContentSize(size)
		// 定位：顶边贴菜单栏图标下缘，右缘与图标右缘对齐；越界时向屏内收
		let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
		let screen = buttonWindow.screen ?? NSScreen.main
		var originX = buttonFrame.maxX - size.width
		if let screen {
			originX = max(originX, screen.frame.minX + 8)
		}
		panel.setFrameTopLeftPoint(NSPoint(x: originX, y: buttonFrame.minY - 4))
		// 先无条件显示再尝试拿 key：调试自动弹出时应用未激活，若直接 makeKeyAndOrderFront
		// 会"拿到 key 又立刻失去"触发失焦秒关；orderFrontRegardless 不依赖 key 状态也能显示
		panel.orderFrontRegardless()
		panel.makeKey()
	}

	// MARK: - 菜单栏标签（8 种显示模式，自 MenuBarExtra label 移植）

	private func refreshLabel() {
		guard let button = statusItem?.button else { return }
		let snapshot = services.monitor.snapshot
		let configuration = services.configurationManager.configuration
		let low = isLowBattery(snapshot)
		let batteryImage = MenuBarIconRenderer.batteryImage(
			percent: snapshot.stateOfChargePercent ?? 0,
			isCharging: snapshot.isCharging,
			isLowBattery: low,
			shimmerPhase: services.iconAnimator.shimmerPhase
		)
		button.image = nil
		button.attributedTitle = NSAttributedString(string: "")

		switch configuration.menuBarContent {
		case .icon:
			button.image = batteryImage
		case .iconAndPercent:
			button.image = batteryImage
			button.imagePosition = .imageLeading
			setTitle(percentText(from: snapshot), low: low)
		case .percent:
			setTitle(menuBarTitle(snapshot), low: low)
		case .temperature:
			// 高温变橙：与高温通知、面板温度行同一套警示语言
			setTitle(menuBarTitle(snapshot), tint: isHotBattery(snapshot) ? .systemOrange : .labelColor)
		case .power:
			setTitle(menuBarTitle(snapshot), low: false)
		case .remainingTime:
			setTitle(menuBarTitle(snapshot), low: low)
		case .sparkline:
			// 近 24 小时电量走势迷你曲线 + 百分比；采样不足时退回纯数字
			let percents = services.historyRecorder.socSamples.suffix(120).map(\.percent)
			if percents.count >= 2 {
				button.image = MenuBarSparklineRenderer.image(percents: Array(percents), isLow: low)
				button.imagePosition = .imageLeading
			}
			setTitle(percentText(from: snapshot), low: low)
		case .rotating:
			// 三页轮换：iconAnimator 推进页码，这里只渲染当前页
			let index = services.iconAnimator.rotationIndex
			setTitle(rotatingPageTitle(index: index, snapshot: snapshot), tint: rotatingTint(index: index, snapshot: snapshot))
		}
	}

	private func setTitle(_ text: String, low: Bool) {
		setTitle(text, tint: low ? .systemRed : .labelColor)
	}

	private func setTitle(_ text: String, tint: NSColor) {
		guard let button = statusItem?.button else { return }
		button.attributedTitle = NSAttributedString(string: text, attributes: [
			.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
			.foregroundColor: tint,
		])
	}

	// 轮换页的警示色跟随当前页内容：电量页低电变红，温度页高温变橙
	private func rotatingTint(index: Int, snapshot: BatterySnapshot) -> NSColor {
		switch index {
		case 0 where isLowBattery(snapshot): return .systemRed
		case 1 where isHotBattery(snapshot): return .systemOrange
		default: return .labelColor
		}
	}

	private func rotatingPageTitle(index: Int, snapshot: BatterySnapshot) -> String {
		switch index {
		case 1:
			return snapshot.temperatureC.map { String(format: "%.0f°", $0) } ?? "—°"
		case 2:
			return (snapshot.currentPowerW ?? snapshot.chargingPowerW).map { String(format: "%.1fW", $0) } ?? "—W"
		default:
			let percent = percentText(from: snapshot)
			return snapshot.isCharging ? "⚡︎\(percent)" : percent
		}
	}

	private func menuBarTitle(_ snapshot: BatterySnapshot) -> String {
		switch services.configurationManager.configuration.menuBarContent {
		case .percent, .icon, .iconAndPercent, .sparkline, .rotating:
			let percent = percentText(from: snapshot)
			return snapshot.isCharging ? "⚡︎\(percent)" : percent
		case .temperature:
			return snapshot.temperatureC.map { String(format: "%.0f°", $0) } ?? "—°"
		case .power:
			let watts = snapshot.currentPowerW ?? snapshot.chargingPowerW
			return watts.map { String(format: "%.1fW", $0) } ?? "—W"
		case .remainingTime:
			// 充电看还要多久充满，用电池看还能用多久；估算没出来时退回百分比
			if snapshot.isCharging, !snapshot.isFull,
			   let minutes = snapshot.timeToFullChargeMinutes, minutes > 0 {
				return "⚡︎\(Self.clockStyle(minutes))"
			}
			if snapshot.powerSource == .battery, !snapshot.isCharging {
				if let minutes = snapshot.timeToEmptyMinutes, minutes > 0 {
					return Self.clockStyle(minutes)
				}
				if let minutes = services.monitor.drainEstimate?.estimatedMinutesRemaining, minutes > 0 {
					return Self.clockStyle(minutes)
				}
			}
			return percentText(from: snapshot)
		}
	}

	// 低电量：电量≤用户设定阈值且靠电池供电，与低电量通知、面板红徽章条件统一
	private func isLowBattery(_ snapshot: BatterySnapshot) -> Bool {
		guard let percent = snapshot.stateOfChargePercent else { return false }
		return percent <= services.configurationManager.configuration.lowBatteryThresholdPercent && snapshot.powerSource == .battery
	}

	private func isHotBattery(_ snapshot: BatterySnapshot) -> Bool {
		(snapshot.temperatureC ?? 0) >= Double(services.configurationManager.configuration.highTemperatureThresholdC)
	}

	private func percentText(from snapshot: BatterySnapshot) -> String {
		snapshot.stateOfChargePercent.map { "\($0)%" } ?? "—%"
	}

	// 菜单栏寸土寸金，用 "3:25" 这种时钟式写法而非"3小时25分钟"
	private static func clockStyle(_ minutes: Int) -> String {
		String(format: "%d:%02d", minutes / 60, minutes % 60)
	}
}

// 非激活面板：弹出时不抢 App 激活态（菜单栏应用不该让前台易主），但要能接收点击与键盘
private final class GlassPopoverPanel: NSPanel {
	override var canBecomeKey: Bool { true }
}
