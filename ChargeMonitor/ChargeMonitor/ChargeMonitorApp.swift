import AppKit
import SwiftUI

@main
@MainActor
struct ChargeMonitorApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

	init() {
		// 单实例：已有同 bundle ID 进程在先，后来者直接退出
		// 否则会出现双菜单栏图标、重复通知、两个写手竞写同一份设置
		Self.exitIfAnotherInstanceRunning()
	}

	var body: some Scene {
		// 独立偏好设置窗口：面板里 30+ 个开关从子菜单迁到这里，
		// 面板"设置"行通过 showSettingsWindow: 动作打开本窗口。
		// 菜单栏面板本体不走 Scene——MenuBarExtra(.window) 的宿主灰底是 SwiftUI 图层自绘、
		// 无法透明化，玻璃采样不到桌面；改由 AppDelegate 装 NSStatusItem + 透明 NSPanel
		// （见 MenuBarPanelController），充电曲线窗口同理改 AppKit 控制器
		Settings {
			SettingsView(historyRecorder: AppServices.shared.historyRecorder)
		}
	}

	// 单实例保护：查有没有同 bundle ID 的在先进程；有就让后来者提示后退出
	private static func exitIfAnotherInstanceRunning() {
		guard let bundleID = Bundle.main.bundleIdentifier else { return }
		let selfPID = ProcessInfo.processInfo.processIdentifier
		let hasPrior = NSRunningApplication
			.runningApplications(withBundleIdentifier: bundleID)
			.contains { $0.processIdentifier != selfPID }
		guard hasPrior else { return }
		// 弹一句提示再退，免得用户双击后像"点了没反应"
		let alert = NSAlert()
		alert.messageText = "妙电已在菜单栏运行"
		alert.informativeText = "点击菜单栏上的电池图标即可查看电量信息。"
		alert.alertStyle = .informational
		alert.addButton(withTitle: "好")
		_ = alert.runModal()
		exit(0)
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	private var panelController: MenuBarPanelController?

	@MainActor
	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApplication.shared.setActivationPolicy(.accessory)
		let controller = MenuBarPanelController()
		controller.install()
		panelController = controller
	}
}
