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
		// 单实例：已有同 bundle ID 进程在先，后来者直接退出
		// 否则会出现双菜单栏图标、重复通知、两个写手竞写同一份设置
		Self.exitIfAnotherInstanceRunning()
		
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

		// 独立偏好设置窗口：面板里 30+ 个开关从子菜单迁到这里，
		// 面板"设置"行通过 openSettings() 打开本窗口
		Settings {
			SettingsView(historyRecorder: historyRecorder)
		}

		// 充电曲线独立窗口：面板点击会话行时打开（单窗口复用，选择走共享对象）。
		// 不用 sheet——sheet 挂在菜单栏弹窗的窗口上，关闭时面板会跟着跳动；
		// 独立窗口与设置窗口同一条路径，稳定且能带到前台
		Window("充电曲线", id: "charge-curve") {
			ChargeCurveWindowHost(historyRecorder: historyRecorder)
		}
		.windowResizability(.contentSize)
		.defaultLaunchBehavior(.suppressed)
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
			// 三页文本常驻（仅当前页可见），容器宽度取最宽一页，
			// 避免每 5 秒轮换时菜单栏项因内容宽度不同而左右挪动
			ZStack {
				rotatingPage(index: 0, snapshot: snapshot)
				rotatingPage(index: 1, snapshot: snapshot)
				rotatingPage(index: 2, snapshot: snapshot)
			}
		}
	}
	
	// 轮换显示的单页文本；非当前页 opacity 0 常驻占位，并从朗读里剔除
	@ViewBuilder
	private func rotatingPage(index: Int, snapshot: BatterySnapshot) -> some View {
		let isActive = iconAnimator.rotationIndex == index
		Text(rotatingPageTitle(index: index, snapshot: snapshot))
			.font(.system(size: 12, weight: .medium).monospacedDigit())
			.foregroundStyle(rotatingTint(index: index, snapshot: snapshot))
			.opacity(isActive ? 1 : 0)
			.accessibilityHidden(!isActive)
	}

	// 轮换页的警示色跟随当前页内容：电量页低电变红，温度页高温变橙
	private func rotatingTint(index: Int, snapshot: BatterySnapshot) -> Color {
		switch index {
		case 0 where isLowBattery(snapshot): return .red
		case 1 where isHotBattery(snapshot): return .orange
		default: return .primary
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
				if let minutes = monitor.drainEstimate?.estimatedMinutesRemaining, minutes > 0 {
					return Self.clockStyle(minutes)
				}
			}
			return percentText(from: snapshot)
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
		// 弹一句提示再退，免得用户双击后像“点了没反应”
		let alert = NSAlert()
		alert.messageText = "妙电已在菜单栏运行"
		alert.informativeText = "点击菜单栏上的电池图标即可查看电量信息。"
		alert.alertStyle = .informational
		alert.addButton(withTitle: "好")
		_ = alert.runModal()
		exit(0)
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
