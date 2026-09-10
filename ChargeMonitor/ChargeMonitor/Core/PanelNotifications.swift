import Foundation

/// 面板通知契约：逻辑服务发、面板控制器收。
/// 单独成文件是为让 Services 层不必引用带 SwiftUIMacros 的面板控制器
/// （CLT-only 工具链编不了 macro；测试门也不收视图/面板层文件）。
enum PanelNotifications {
	static let openPanelRequest = Notification.Name("miaodian.openPanelRequested")
}
