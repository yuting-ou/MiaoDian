import AppKit
import SwiftUI

// 充电曲线独立窗口：原为 SwiftUI Window 场景，面板改由 NSHostingView 承载后
// @Environment(\.openWindow) 拿不到场景动作，改为 AppKit 窗口控制器直接建窗。
// 单窗口复用：选择仍走 ChargeCurveSelection.shared，面板点哪条记录窗口就展示哪条
@MainActor
final class ChargeCurveWindowController {
	static let shared = ChargeCurveWindowController()
	private var window: NSWindow?

	func show(historyRecorder: BatteryHistoryRecorder) {
		if window == nil {
			let hosting = NSHostingView(rootView: ChargeCurveWindowHost(historyRecorder: historyRecorder))
			let window = NSWindow(
				contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
				styleMask: [.titled, .closable],
				backing: .buffered, defer: false
			)
			window.title = "充电曲线"
			window.isReleasedWhenClosed = false
			window.contentView = hosting
			window.setContentSize(hosting.fittingSize)
			self.window = window
		}
		// 菜单栏应用（LSUIElement）没有 Dock 图标，先激活窗口才会浮到最上层
		NSApp.activate(ignoringOtherApps: true)
		window?.center()
		window?.makeKeyAndOrderFront(nil)
	}
}
