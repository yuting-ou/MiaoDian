import Combine
import Foundation

@MainActor
final class BatteryMonitor: ObservableObject {
	@Published private(set) var snapshot = BatterySnapshot()
	@Published private(set) var significantEnergyApps: [SignificantEnergyApp] = []
	@Published private(set) var powerSamples: [PowerSample] = []
	@Published private(set) var temperatureSamples: [TemperatureSample] = []
	@Published private(set) var drainEstimate: DrainRateEstimate?
	@Published private(set) var bluetoothDevices: [BluetoothDeviceBattery] = []
	
	private let batteryReader: IOKitBatteryReader
	private let energyReader: SignificantEnergyReader
	private let bluetoothReader = BluetoothBatteryReader()
	
	private var drainEstimator = DrainRateEstimator()
	private var lastBluetoothPoll = Date.distantPast
	private var bluetoothRefreshStartedAt: Date?
	
	private var pollingTask: Task<Void, Never>?
	private var isPopoverOpen = false
	
	private let activeInterval: TimeInterval = 2
	private let backgroundInterval: TimeInterval = 5
	// 功耗曲线保留最近 5 分钟
	private let powerSampleWindow: TimeInterval = 5 * 60
	// 采样间隔超过这个值说明系统睡眠过（正常后台才 5 秒），断开重画
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
		startPollingLoopIfNeeded()
	}
	
	func startPolling() {
		isPopoverOpen = true
		startPollingLoopIfNeeded()
		// 面板打开时立刻刷新一次外设电量，不等轮询周期
		refreshBluetoothDevicesIfNeeded(force: true)
	}
	
	func stopPolling() {
		isPopoverOpen = false
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
		// 重新打开面板后 2 秒轮询会很快重新积累出结果
		if isPopoverOpen {
			let nextApps = energyReader.computeSignificantApps()
			if nextApps.map(\.id) != significantEnergyApps.map(\.id) {
				significantEnergyApps = nextApps
			}
		}
		
		recordPowerSample(from: nextSnapshot)
		recordTemperatureSample(from: nextSnapshot)
		updateDrainEstimate(from: nextSnapshot)
		refreshBluetoothDevicesIfNeeded()
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
	
	private func refreshBluetoothDevicesIfNeeded(force: Bool = false) {
		let now = Date()
		let isDue = force || now.timeIntervalSince(lastBluetoothPoll) >= bluetoothPollInterval
		// 空闲可直接发起；上一轮若超过 20 秒未完成，视为卡死也允许重发
		let canStart = bluetoothRefreshStartedAt.map { now.timeIntervalSince($0) > 20 } ?? true
		guard isDue, canStart else { return }
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
