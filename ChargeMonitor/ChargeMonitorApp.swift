import AppKit
import SwiftUI

@main
@MainActor
struct ChargeMonitorApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@StateObject private var monitor: BatteryMonitor
	@StateObject private var configurationManager: ConfigurationManager
	@StateObject private var behaviorCoordinator: AppBehaviorCoordinator
	@StateObject private var alertController: BatteryAlertController
	@StateObject private var historyRecorder: BatteryHistoryRecorder
	@StateObject private var iconAnimator: MenuBarIconAnimator
	
	init() {
		let monitor = BatteryMonitor()
		let configurationManager = ConfigurationManager.shared
		
		_monitor = StateObject(wrappedValue: monitor)
		_configurationManager = StateObject(wrappedValue: configurationManager)
		_behaviorCoordinator = StateObject(
			wrappedValue: AppBehaviorCoordinator(
				configurationManager: configurationManager
			)
		)
		// 先建历史记录器，提醒控制器要用它的睡眠掉电记录和周报数据
		let historyRecorder = BatteryHistoryRecorder(monitor: monitor)
		_historyRecorder = StateObject(wrappedValue: historyRecorder)
		_alertController = StateObject(
			wrappedValue: BatteryAlertController(
				monitor: monitor,
				configurationManager: configurationManager,
				historyRecorder: historyRecorder
			)
		)
		_iconAnimator = StateObject(
			wrappedValue: MenuBarIconAnimator(monitor: monitor, configurationManager: configurationManager)
		)
	}
	
	var body: some Scene {
		MenuBarExtra {
			BatteryPopoverView(
				monitor: monitor,
				configurationManager: configurationManager,
				historyRecorder: historyRecorder,
				alertController: alertController
			)
		} label: {
			menuBarLabel
		}
		.menuBarExtraStyle(.window)
	}
	
	// 菜单栏标签：自绘精确电量图标 + 等宽数字，避免宽度抖动
	// 充电期间由 iconAnimator 推进流光相位，播放扫光动画
	@ViewBuilder
	private var menuBarLabel: some View {
		let snapshot = monitor.snapshot
		let batteryImage = MenuBarIconRenderer.batteryImage(
			percent: snapshot.stateOfChargePercent ?? 0,
			isCharging: snapshot.isCharging,
			isLowBattery: isLowBattery(snapshot),
			shimmerPhase: iconAnimator.shimmerPhase
		)
		
		switch configurationManager.configuration.menuBarContent {
		case .icon:
			Image(nsImage: batteryImage)
		case .iconAndPercent:
			HStack(spacing: 3) {
				Image(nsImage: batteryImage)
				Text(percentText(from: snapshot))
					.font(.system(size: 12, weight: .medium).monospacedDigit())
					// 低电量时图标已变红，数字也跟着变红保持一致
					.foregroundStyle(isLowBattery(snapshot) ? Color.red : Color.primary)
			}
		case .percent:
			Text(menuBarTitle)
				.font(.system(size: 12, weight: .medium).monospacedDigit())
				// 纯文字模式没有图标可染色，低电量时让数字变红提醒
				.foregroundStyle(isLowBattery(snapshot) ? Color.red : Color.primary)
		case .temperature:
			Text(menuBarTitle)
				.font(.system(size: 12, weight: .medium).monospacedDigit())
				// 高温时数字变橙提醒，与高温通知、面板温度行同一套警示语言
				.foregroundStyle(isHotBattery(snapshot) ? Color.orange : Color.primary)
		case .power:
			Text(menuBarTitle)
				.font(.system(size: 12, weight: .medium).monospacedDigit())
		case .remainingTime:
			Text(menuBarTitle)
				.font(.system(size: 12, weight: .medium).monospacedDigit())
				// 低电量时剩余时间本身就是最该红的数字
				.foregroundStyle(isLowBattery(snapshot) ? Color.red : Color.primary)
		case .sparkline:
			// 近 24 小时电量走势迷你曲线 + 百分比；采样不足时退回纯数字
			let lowBattery = isLowBattery(snapshot)
			let percents = historyRecorder.socSamples.suffix(120).map(\.percent)
			if percents.count >= 2 {
				HStack(spacing: 3) {
					Image(nsImage: MenuBarSparklineRenderer.image(percents: Array(percents), isLow: lowBattery))
					Text(percentText(from: snapshot))
						.font(.system(size: 12, weight: .medium).monospacedDigit())
						.foregroundStyle(lowBattery ? Color.red : Color.primary)
				}
			} else {
				Text(percentText(from: snapshot))
					.font(.system(size: 12, weight: .medium).monospacedDigit())
					.foregroundStyle(lowBattery ? Color.red : Color.primary)
			}
		case .rotating:
			Text(menuBarTitle)
				.font(.system(size: 12, weight: .medium).monospacedDigit())
				.foregroundStyle(rotatingTint(snapshot))
		}
	}
	
	// 轮换页的警示色跟随当前页内容：电量页低电变红，温度页高温变橙
	private func rotatingTint(_ snapshot: BatterySnapshot) -> Color {
		switch iconAnimator.rotationIndex {
		case 0 where isLowBattery(snapshot): return .red
		case 1 where isHotBattery(snapshot): return .orange
		default: return .primary
		}
	}
	
	// 低电量：电量≤用户设定阈值且靠电池供电，与低电量通知、面板红徽章条件统一
	// （插着电源时即使暂停充电，电量也不会掉，不拉红色警报）
	private func isLowBattery(_ snapshot: BatterySnapshot) -> Bool {
		guard let percent = snapshot.stateOfChargePercent else { return false }
		return percent <= configurationManager.configuration.lowBatteryThresholdPercent && snapshot.powerSource == .battery
	}
	
	// 高温：≥用户设定阈值，与高温通知阈值统一
	private func isHotBattery(_ snapshot: BatterySnapshot) -> Bool {
		(snapshot.temperatureC ?? 0) >= Double(configurationManager.configuration.highTemperatureThresholdC)
	}
	
	private func percentText(from snapshot: BatterySnapshot) -> String {
		snapshot.stateOfChargePercent.map { "\($0)%" } ?? "—%"
	}
	
	private var menuBarTitle: String {
		let snapshot = monitor.snapshot
		switch configurationManager.configuration.menuBarContent {
		case .percent, .icon, .iconAndPercent, .sparkline:
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
				if let minutes = monitor.drainEstimate?.estimatedMinutesRemaining, minutes > 0 {
					return Self.clockStyle(minutes)
				}
			}
			return percentText(from: snapshot)
		case .rotating:
			// 三页轮换：电量 → 温度 → 功耗，缺数据的页退回电量
			switch iconAnimator.rotationIndex {
			case 1:
				if let temperature = snapshot.temperatureC {
					return String(format: "%.0f°", temperature)
				}
			case 2:
				if let watts = snapshot.currentPowerW ?? snapshot.chargingPowerW {
					return String(format: "%.1fW", watts)
				}
			default:
				break
			}
			let percent = percentText(from: snapshot)
			return snapshot.isCharging ? "⚡︎\(percent)" : percent
		}
	}
	
	// 菜单栏寸土寸金，用 “3:25” 这种时钟式写法而非“3小时25分钟”
	private static func clockStyle(_ minutes: Int) -> String {
		String(format: "%d:%02d", minutes / 60, minutes % 60)
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApplication.shared.setActivationPolicy(.accessory)
	}
}
