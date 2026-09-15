import AppKit
import SwiftUI

// 离屏验收工具（仅开发用，不进构建产物）：把真面板视图装进 NSHostingView，
// 不显示到屏幕、不抢焦点，直接问它"你要多高"并把版式渲染成 PNG。
//
// 为什么需要它：面板高度是否超出可视区（菜单栏+Dock 之后）是这轮观感整改的关键未知量，
// 而实拍截图依赖显示器亮着——用户不在机器前时屏幕常熄，像素量不到；
// CGWindowList 的宽高数字又实测不可信（报过 526pt，实际 586pt）。
// 能力边界（实测，别误信）：
//   ✓ 能验：布局尺寸/是否超出可视区——fittingSize 由布局引擎直接给出，与显示器状态无关
//   ✗ 不能验：观感。离屏视图不进入窗口 → onAppear 不触发，而面板内容全部挂在
//     CascadeIn 逐层淡入上（未 appear 时透明度为 0），加上玻璃材质不做离屏合成，
//     渲染出来的 PNG 是空白。观感验收仍必须实拍（见 工具/壁纸实测.sh 与报告"待眼睛"清单）。
//
// 用法：bash 工具/离屏验收.sh [宽度pt]   → /tmp/miaodian_render.png + stdout 高度
@main
struct OffscreenAcceptance {
	static func main() {
		let width = CommandLine.arguments.count > 1
			? (Double(CommandLine.arguments[1]) ?? 584) : 584.0

		let monitor = BatteryMonitor()
		let historyRecorder = BatteryHistoryRecorder(monitor: monitor)
		let alertController = BatteryAlertController(
			monitor: monitor,
			configurationManager: ConfigurationManager.shared,
			historyRecorder: historyRecorder
		)
		// 持有引用：NSHostingView 只弱引用 ObservableObject
		_ = alertController

		let root = BatteryPopoverView(
			monitor: monitor,
			configurationManager: ConfigurationManager.shared,
			historyRecorder: historyRecorder,
			alertController: alertController
		)
		.frame(width: width)

		let hosting = NSHostingView(rootView: AnyView(root))
		hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
		hosting.layoutSubtreeIfNeeded()

		let fitting = hosting.fittingSize
		print("面板内容尺寸：\(fitting.width) x \(fitting.height) pt")
		if let screen = NSScreen.main {
			let visible = screen.visibleFrame
			// 面板顶边锚在 visibleFrame 上缘，可用高即窗口顶到可视区底
			print("屏幕 \(screen.frame.width)x\(screen.frame.height)，可视高 \(visible.height)pt → "
				+ (fitting.height <= visible.height ? "✓ 整块落在 Dock 之上" : "✗ 超出 \(String(format: "%.0f", fitting.height - visible.height))pt，底部被 Dock 压住"))
		}

		hosting.frame = NSRect(x: 0, y: 0, width: fitting.width, height: fitting.height)
		hosting.layoutSubtreeIfNeeded()
		guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
			print("无法创建位图上下文"); return
		}
		hosting.cacheDisplay(in: hosting.bounds, to: rep)
		guard let data = rep.representation(using: .png, properties: [:]) else {
			print("PNG 编码失败"); return
		}
		let out = URL(fileURLWithPath: "/tmp/miaodian_render.png")
		try? data.write(to: out)
		print("已渲染 \(out.path)（预期空白：见文件头「能力边界」，观感请走实拍）")
	}
}
