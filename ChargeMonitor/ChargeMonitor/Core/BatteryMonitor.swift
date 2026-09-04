import AppKit
import Combine
import Foundation
import IOKit.ps

@MainActor
final class BatteryMonitor: ObservableObject {
	@Published private(set) var snapshot = BatterySnapshot()
	@Published private(set) var significantEnergyApps: [SignificantEnergyApp] = []
	@Published private(set) var powerSamples: [PowerSample] = []
	@Published private(set) var temperatureSamples: [TemperatureSample] = []
	@Published private(set) var drainEstimate: DrainRateEstimate?
	@Published private(set) var bluetoothDevices: [BluetoothDeviceBattery] = []
	// 电池身份证：出厂静态信息，启动读一次（读不到为 nil，卡片自动隐藏）
	@Published private(set) var batteryIdentity: BatteryIdentity?
	
	private let batteryReader: IOKitBatteryReader
	private let energyReader: SignificantEnergyReader
	private let bluetoothReader = BluetoothBatteryReader()
	
	private var drainEstimator = DrainRateEstimator()
	private var lastBluetoothPoll = Date.distantPast
	private var bluetoothRefreshStartedAt: Date?
	
	private var pollingTask: Task<Void, Never>?
	// 高耗电采样一轮没算完就先跳过本轮，避免队列越积越长
	private var energyComputationInFlight = false
	// 电源变化通知的即时刷新限流：最短间隔 1 秒，防通知风暴
	private var lastEventRefresh = Date.distantPast
	// 上次通知时看到的供电来源：通知不区分"什么变了"，靠来源翻转过滤遥测抖动
	private var lastNotifiedPowerSource: PowerSourceType?
	// IOPS 电源变化通知的 run loop 源（保活引用；应用生命周期内不移除）
	private var powerSourceChangeSource: CFRunLoopSource?
	// 面板是否打开：高耗电应用累计只应在面板打开期间计时（列表也只在那时刷新）
	private(set) var isPopoverOpen = false
	
	private let activeInterval: TimeInterval = 2
	private let backgroundInterval: TimeInterval = 10
	// 功耗曲线保留最近 5 分钟
	private let powerSampleWindow: TimeInterval = 5 * 60
	// 采样间隔超过这个值说明系统睡眠过（正常后台才 10 秒），断开重画
	private let powerSampleGapSeconds: TimeInterval = 30
	// 温度变化慢，曲线看最近 30 分钟，15 秒记一点足够
	private let temperatureSampleWindow: TimeInterval = 30 * 60
	private let temperatureSampleMinInterval: TimeInterval = 15
	private let temperatureSampleGapSeconds: TimeInterval = 5 * 60
	// 外设电量变化慢，30 秒轮询一次即可
	private let bluetoothPollInterval: TimeInterval = 30
	
	init(
		batteryReader: IOKitBatteryReader? = nil,
		energyReader: SignificantEnergyReader? = nil
	) {
		self.batteryReader = batteryReader ?? IOKitBatteryReader()
		self.energyReader = energyReader ?? SignificantEnergyReader()
		// 身份信息是静态的，启动读一次即可；IOKit 注册表读取是微秒级，不卡主线程
		batteryIdentity = self.batteryReader.readIdentity()
		startPollingLoopIfNeeded()
		registerPowerSourceNotifications()
	}
	
	func startPolling() {
		isPopoverOpen = true
		startPollingLoopIfNeeded()
		// 面板打开时立刻刷新一次外设电量，不等轮询周期
		refreshBluetoothDevicesIfNeeded(force: true)
	}
	
	func stopPolling() {
		isPopoverOpen = false
		// 清空高耗电列表：它只代表"面板打开期间"的采样，
		// 留着旧值会让耗电异常提醒在面板关闭几小时后点名过时的应用
		// （重新打开面板后 2 秒轮询会很快重新积累出结果）
		significantEnergyApps = []
		startPollingLoopIfNeeded()
	}
	
	private func startPollingLoopIfNeeded() {
		guard pollingTask == nil else { return }
		
		pollingTask = Task { [weak self] in
			while let self, !Task.isCancelled {
				await self.refresh()
				let interval = self.isPopoverOpen ? self.activeInterval : self.backgroundInterval
				try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
			}
		}
	}
	
	private func refresh() async {
		let nextSnapshot = await batteryReader.readSnapshot()
		if nextSnapshot != snapshot {
			snapshot = nextSnapshot
		}
		
		// 高耗电列表只有面板在看，后台不做全进程采样（每次要扫遍所有进程）；
		// 重新打开面板后 2 秒轮询会很快重新积累出结果。
		// 主线程只快照在场应用列表，差分与聚合在 actor 上跑，发布回主线程
		if isPopoverOpen, !energyComputationInFlight {
			energyComputationInFlight = true
			let stubs = SignificantEnergyReader.currentRunningAppStubs()
			let stubsByBundleId = Dictionary(stubs.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
			Task { [weak self] in
				guard let self else { return }
				let impacts = await self.energyReader.computeImpacts(apps: stubs)
				self.publishEnergyApps(impacts, stubsByBundleId: stubsByBundleId)
				self.energyComputationInFlight = false
			}
		}
		
		recordPowerSample(from: nextSnapshot)
		recordTemperatureSample(from: nextSnapshot)
		updateDrainEstimate(from: nextSnapshot)
		refreshBluetoothDevicesIfNeeded()
	}
	
	// 把一轮采样结果映射回展示模型：图标等 AppKit 侧信息留在主线程生成
	private func publishEnergyApps(
		_ impacts: [SignificantEnergyReader.ImpactEntry],
		stubsByBundleId: [String: SignificantEnergyReader.RunningAppStub]
	) {
		let selfBundleId = Bundle.main.bundleIdentifier
		let next = impacts.compactMap { entry -> SignificantEnergyApp? in
			guard entry.bundleIdentifier != selfBundleId,
				let stub = stubsByBundleId[entry.bundleIdentifier] else { return nil }
			return SignificantEnergyApp(
				id: entry.bundleIdentifier,
				pid: stub.pid,
				name: stub.displayName
					?? stub.bundleURL?.deletingPathExtension().lastPathComponent
					?? "Unknown",
				bundleIdentifier: entry.bundleIdentifier,
				bundleURL: stub.bundleURL,
				icon: stub.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
				energyImpact: entry.impact
			)
		}
		if next.map(\.id) != significantEnergyApps.map(\.id) {
			significantEnergyApps = next
		}
	}

	// MARK: - 电源变化即时刷新

	// IOPS 电源变化通知：插拔电立刻触发一次采样，不用等轮询周期
	// （通知也会随电量变化等常规数据更新触发，1 秒限流兜底；回调经主线程跑池跳回 MainActor）
	private func registerPowerSourceNotifications() {
		// passRetained：通知源与应用同寿，持引用保证回调永远拿不到悬垂指针
		let context = Unmanaged.passRetained(self).toOpaque()
		guard let source = IOPSNotificationCreateRunLoopSource({ rawContext in
			guard let rawContext else { return }
			let monitor = Unmanaged<BatteryMonitor>.fromOpaque(rawContext).takeUnretainedValue()
			Task { @MainActor in
				await monitor.refreshForPowerEvent()
			}
		}, context)?.takeRetainedValue() else {
			DiagnosticLog.failureOnce("power-source-notify-failed", category: "BatteryMonitor", "电源变化通知注册失败，退回纯轮询刷新")
			return
		}
		CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
		powerSourceChangeSource = source
	}

	// 电源事件触发的即时刷新；应用生命周期内 monitor 与轮询循环同寿，无需注销
	private func refreshForPowerEvent() async {
		guard Date().timeIntervalSince(lastEventRefresh) >= 1 else { return }
		// 通知不区分"什么变了"：电量、瓦数遥测的常规抖动都会触发。先用微秒级的
		// 供电来源比对判断是否真的插拔电，没翻转就忽略——否则等于把 10 秒轮询
		// 变成 1 秒轮询，白白烧电
		let source = batteryReader.readPowerSourceType()
		guard source != nil, source != lastNotifiedPowerSource else { return }
		lastNotifiedPowerSource = source
		lastEventRefresh = Date()
		await refresh()
	}

	private func recordPowerSample(from snapshot: BatterySnapshot) {
		guard let watts = snapshot.currentPowerW, watts > 0 else { return }
		
		let now = Date()
		var samples = powerSamples
		// 距上一个采样太久说明睡眠过，旧数据与现在不连续，清空重画
		// 否则曲线会在断档处拉一条误导性的直线
		if let last = samples.last, now.timeIntervalSince(last.date) > powerSampleGapSeconds {
			samples.removeAll()
		}
		samples.append(PowerSample(date: now, watts: watts))
		samples.removeAll { now.timeIntervalSince($0.date) > powerSampleWindow }
		powerSamples = samples
	}
	
	private func recordTemperatureSample(from snapshot: BatterySnapshot) {
		guard let celsius = snapshot.temperatureC, celsius > 0 else { return }
		
		let now = Date()
		var samples = temperatureSamples
		if let last = samples.last {
			// 睡眠断档后旧数据不连续，清空重画；未到采样间隔则跳过
			if now.timeIntervalSince(last.date) > temperatureSampleGapSeconds {
				samples.removeAll()
			} else if now.timeIntervalSince(last.date) < temperatureSampleMinInterval {
				return
			}
		}
		samples.append(TemperatureSample(date: now, celsius: celsius))
		samples.removeAll { now.timeIntervalSince($0.date) > temperatureSampleWindow }
		temperatureSamples = samples
	}
	
	private func updateDrainEstimate(from snapshot: BatterySnapshot) {
		drainEstimator.record(snapshot: snapshot)
		let next = drainEstimator.estimate()
		if next != drainEstimate {
			drainEstimate = next
		}
	}
	
	// 蓝牙轮询能否发起下一轮（纯函数，供单测）：空闲可发；上一轮超过 staleSeconds
	// 未完成视为卡死放行——子进程看门狗兜底后仍可能因异常路径不回调，不能永久锁死
	nonisolated static func canStartBluetoothRefresh(startedAt: Date?, now: Date, staleSeconds: TimeInterval = 20) -> Bool {
		guard let startedAt else { return true }
		return now.timeIntervalSince(startedAt) > staleSeconds
	}

	private func refreshBluetoothDevicesIfNeeded(force: Bool = false) {
		let now = Date()
		let isDue = force || now.timeIntervalSince(lastBluetoothPoll) >= bluetoothPollInterval
		guard isDue, Self.canStartBluetoothRefresh(startedAt: bluetoothRefreshStartedAt, now: now) else { return }
		lastBluetoothPoll = now
		bluetoothRefreshStartedAt = now
		
		// pmset 子进程读取有耗时，放到后台线程避免卡主线程
		let reader = bluetoothReader
		Task { [weak self] in
			let nextDevices = await Task.detached(priority: .utility) { reader.readDevices() }.value
			guard let self else { return }
			self.bluetoothRefreshStartedAt = nil
			if nextDevices != self.bluetoothDevices {
				self.bluetoothDevices = nextDevices
			}
		}
	}
	
	deinit {
		pollingTask?.cancel()
	}
}
