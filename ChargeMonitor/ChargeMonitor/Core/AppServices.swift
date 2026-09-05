import AppKit
import SwiftUI

// 全局服务单例：菜单栏面板改由 AppKit 承载（NSStatusItem + 自建 NSPanel）后，
// 可观察对象不再挂在 App 结构的 @StateObject 上，统一收口到这里——
// 面板、设置窗口、曲线窗口、标签刷新共用同一批实例。
// 懒加载：首次访问时构建（AppDelegate 在单实例守卫之后才触发，不会双开竞写）
@MainActor
final class AppServices {
	static let shared = AppServices()

	let monitor: BatteryMonitor
	let configurationManager: ConfigurationManager
	let historyRecorder: BatteryHistoryRecorder
	let alertController: BatteryAlertController
	let iconAnimator: MenuBarIconAnimator
	let behaviorCoordinator: AppBehaviorCoordinator

	private init() {
		let monitor = BatteryMonitor()
		let configurationManager = ConfigurationManager.shared
		// 先建历史记录器：提醒控制器要用它的睡眠掉电记录和周报数据
		let historyRecorder = BatteryHistoryRecorder(monitor: monitor)
		self.monitor = monitor
		self.configurationManager = configurationManager
		self.historyRecorder = historyRecorder
		self.alertController = BatteryAlertController(
			monitor: monitor,
			configurationManager: configurationManager,
			historyRecorder: historyRecorder
		)
		self.iconAnimator = MenuBarIconAnimator(monitor: monitor, configurationManager: configurationManager)
		self.behaviorCoordinator = AppBehaviorCoordinator(configurationManager: configurationManager)
	}
}
