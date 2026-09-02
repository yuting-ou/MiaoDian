import AppIntents
import Foundation

// Shortcuts / Spotlight 的电池速览入口。
// 故意自成一体：现场做一次全新 IOKit 读取，不触碰常驻状态——
// 意图的生命周期不与面板耦合，读一次注册表/SMC 是微秒级的事
struct BatteryOverviewIntent: AppIntent {
	static let title: LocalizedStringResource = "电池速览"
	static let description = IntentDescription("查询当前电量、充电状态、剩余时间与电池健康度")

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		let snapshot = await IOKitBatteryReader().readSnapshot()

		var parts: [String] = []
		if let soc = snapshot.stateOfChargePercent {
			parts.append(snapshot.isCharging ? "电量 \(soc)%（充电中）" : "电量 \(soc)%")
		}
		if snapshot.isFull {
			parts.append("已充满")
		} else if snapshot.isCharging, let minutes = snapshot.timeToFullChargeMinutes, minutes > 0 {
			parts.append("约 \(DurationFormatter.chinese(minutes: minutes))后充满")
		} else if snapshot.powerSource == .battery, let minutes = snapshot.timeToEmptyMinutes, minutes > 0 {
			parts.append("还能用约 \(DurationFormatter.chinese(minutes: minutes))")
		}
		if let health = snapshot.healthPercent {
			parts.append("健康度 \(health)%")
		}
		if let temperature = snapshot.temperatureC {
			parts.append(String(format: "温度 %.0f°C", temperature))
		}

		return .result(dialog: IntentDialog(stringLiteral: parts.isEmpty ? "暂无电池数据" : parts.joined(separator: "，")))
	}
}

// 系统快捷指令面板里的固定入口；短语必须带应用名占位符
struct MiaoDianShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: BatteryOverviewIntent(),
			phrases: [
				"用\(.applicationName)查电池",
				"问\(.applicationName)电池怎么样"
			],
			shortTitle: "电池速览",
			systemImageName: "battery.100percent"
		)
	}
}
