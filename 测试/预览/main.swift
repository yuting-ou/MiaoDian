import AppKit
import SwiftUI

// 液态玻璃预览 harness（仅开发工具，不进构建产物——build.sh 只收集 ChargeMonitor/ChargeMonitor/**）。
// 菜单栏图标被 iBar 隐藏、LSUIElement 无法前台激活，真实面板无法无人值守点开；
// 这里把真面板视图装进一个半透明普通窗口，用真实 UserDefaults 数据渲染，供截图验收。
// 注意：普通窗口 ≠ MenuBarExtra(.window) 宿主，预览通过只是必要条件，发版前仍需真实面板终验。

final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
	private var window: NSWindow?
	// 持有依赖对象：NSHostingView 只弱引用 ObservableObject，释放了面板就空转
	private var monitor: BatteryMonitor?
	private var historyRecorder: BatteryHistoryRecorder?
	private var alertController: BatteryAlertController?

	func applicationDidFinishLaunching(_ notification: Notification) {
		let monitor = BatteryMonitor()
		let configurationManager = ConfigurationManager.shared
		let historyRecorder = BatteryHistoryRecorder(monitor: monitor)
		let alertController = BatteryAlertController(
			monitor: monitor,
			configurationManager: configurationManager,
			historyRecorder: historyRecorder
		)
		self.monitor = monitor
		self.historyRecorder = historyRecorder
		self.alertController = alertController

		let root = BatteryPopoverView(
			monitor: monitor,
			configurationManager: configurationManager,
			historyRecorder: historyRecorder,
			alertController: alertController
		)
		let hosting = NSHostingView(rootView: root)
		// 面板内容可能比屏幕还高（卡片全开时 ~1000pt）：预览外套滚动视图，
		// 只为把底部控制行滚进截图视野——真实面板不滚动，这里与产品布局无关
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 584, height: 800))
		scroll.documentView = hosting
		scroll.hasVerticalScroller = true
		scroll.drawsBackground = false

		let window = NSWindow(
			contentRect: NSRect(x: 240, y: 200, width: 584, height: 800),
			styleMask: [.titled, .closable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		// 透底：玻璃效果采样窗口后面的桌面，与 MenuBarExtra 面板同条件
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = true
		window.contentView = scroll
		// 高度取内容自然高与屏幕可用高的较小值，保证底部不被 Dock 吞掉
		let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
		window.setContentSize(NSSize(width: hosting.fittingSize.width, height: min(hosting.fittingSize.height, visible.height - 20)))
		window.center()
		window.makeKeyAndOrderFront(nil)
		self.window = window

		NSApp.activate(ignoringOtherApps: true)
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}
}

let app = NSApplication.shared
let delegate = PreviewAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
