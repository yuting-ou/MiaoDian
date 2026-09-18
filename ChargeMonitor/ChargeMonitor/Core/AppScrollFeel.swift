import AppKit

/// 应用内滚轮跟手：本地监视 scrollWheel，把鼠标滚轮的行步进换成像素步长后重投。
///
/// 为什么不在 SwiftUI ScrollView 上调参：macOS 的 SwiftUI 滚动宿主不暴露灵敏度；
/// 触控板与鼠标共用同一条滚动路径，差别只在 `hasPreciseScrollingDeltas`。
/// 把非精确事件换成 `units: .pixel` 的合成事件后，ScrollView 走与触控板相同的
/// 像素滚动路径——步长由 `ScrollFeel.mousePixelStep` 决定，方向沿用系统预处理后的 deltaY。
///
/// 作用范围：本进程全部窗口（面板卡片区、设置 Form）。合成事件是精确滚动，
/// 本监视器只放大非精确事件，不会自我递归。
@MainActor
enum AppScrollFeel {
	private static var monitor: Any?

	static func install() {
		guard monitor == nil else { return }
		monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
			handle(event)
		}
	}

	static func uninstall() {
		guard let monitor else { return }
		NSEvent.removeMonitor(monitor)
		self.monitor = nil
	}

	private static func handle(_ event: NSEvent) -> NSEvent? {
		guard ScrollFeel.shouldAmplify(
			hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
			deltaY: event.scrollingDeltaY
		) else {
			return event
		}
		let pixels = ScrollFeel.pixelDelta(forWheel: event.scrollingDeltaY)
		let wheel1 = Int32(pixels.rounded())
		// 量化后为 0（极轻的惯性尾巴 × 步长仍不足 1px）时放过，避免吞事件却不滚
		guard wheel1 != 0 else { return event }
		guard let cgEvent = CGEvent(
			scrollWheelEvent2Source: nil,
			units: .pixel,
			wheelCount: 1,
			wheel1: wheel1,
			wheel2: 0,
			wheel3: 0
		) else {
			// 合成失败：退回系统行滚动，宁可步进小也不要静止
			return event
		}
		// CGEvent.location 是屏幕坐标；拿不到窗口时无法对齐，退回系统行滚动
		//（合成事件若落到别的窗口上，等于帮用户滚了别的 App）
		guard let window = event.window else { return event }
		cgEvent.location = window.convertToScreen(
			NSRect(origin: event.locationInWindow, size: .zero)
		).origin
		cgEvent.post(tap: .cghidEventTap)
		// 吞掉原始行滚动，避免与合成像素滚动叠加成双倍
		return nil
	}
}
