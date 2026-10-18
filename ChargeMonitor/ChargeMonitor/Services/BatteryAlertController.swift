import AppKit
import Combine
import Foundation
import UserNotifications

// 电池状态提醒：充满、低电量及预判、高温及骤升、慢充、保养拔电、外设低电、
// 耗电异常、睡眠掉电、健康里程碑、充满预告、每周周报
// 采用边沿触发——进入状态时只提醒一次，离开状态后重置；
// 每类提醒有独立开关，夜间免打扰时段非紧急通知不发
@MainActor
// 继承 NSObject 是为满足 UNUserNotificationCenterDelegate 的对象协议要求
final class BatteryAlertController: NSObject, ObservableObject {
	// 开了提醒但系统通知权限被拒：提醒实际发不出去，面板上要给出警告
	@Published private(set) var isNotificationPermissionDenied = false
	// 系统优化充电正在保养线附近反复暂停（与用户的保养提醒"打架"）
	@Published private(set) var isOptimizedChargingHolding = false
	// C2 共存确实生效过：本机读到过系统暂缓签名且电平覆盖保养线（= 我们真的静默过提醒）。
	// 洞察文案据此二选一措辞——读不到签名的机器上我们不静默，就不能说"不再重复提醒"（诚实边界）
	@Published private(set) var hasSilencedCareForSystemHold = false
	
	private var cancellables: Set<AnyCancellable> = []
	private var configuration = AppConfiguration.default
	private var didRequestAuthorization = false
	// 耗电异常提醒要结合电源状态和高耗电应用名，留一份引用现取
	private weak var monitor: BatteryMonitor?
	// 周报数据从用电历史/充电记录里汇总
	private weak var historyRecorder: BatteryHistoryRecorder?
	private var lastSnapshot = BatterySnapshot()
	// 标记键、延后窗口、去重日、冷却、周月报记账全走 defaults。
	// 可注入 = 单测 / 量具能落临时域；否则一轮跑过 lastWeeklyDigestDate
	// 落进**开发机**，第二轮真假红看执行顺序（与 ConfigurationManager 同源的注入同理）
	private let defaults: UserDefaults
	// 里程碑 seen 的写回走 init 传入的同一个 ConfigurationManager（配设置页同源）；
	// 原先这里裸写 .shared，且该成员压根不存在——依赖靠的是全局偶合
	private let configurationManager: ConfigurationManager
	// 时间来源全走注入的时钟：免打扰小时、骤升窗口、周月报名册、延后窗口
	// 原先这些位置直接读系统时钟，单测钉不住"凌晨误报/周月报每秒重发"。
	// 注入后测试可推进假钟把这三条钉死；生产恒 .live，行为逐字不变
	private let clock: HistoryClock
	
	private var didNotifyFull = false
	private var didNotifyLowBattery = false
	private var didNotifyHighTemperature = false
	private var didNotifySlowCharge = false
	private var didNotifyChargeCare = false
	private var didNotifyHighDrain = false
	private var didNotifyLowForecast = false
	private var didNotifyFullForecast = false
	private var didNotifyTempSurge = false
	// 已提醒过低电的外设名，回升到重置线以上才移除
	private var notifiedLowDevices: Set<String> = []
	// 温度骤升检测：最近几分钟的温度环形缓存
	private var recentTemps: [(date: Date, celsius: Double)] = []
	// 保养线附近的充电暂停边沿时间戳：系统优化充电的指纹
	private var carePauseEdges: [Date] = []
	private var wasChargingNearCareLine = false
	// C2 系统共存：本次插电会话内系统是否已在保养线处按住充电（拔电重置）。
	// 一旦观察到系统替用户做了"到线即停"，本会话不再重复喊"可以拔了"
	private var didObserveSystemHoldAtLine = false
	
	// 阈值大多由用户在设置里调，重置线随阈值派生，避免临界抖动
	// 睡眠掉电的时长/掉电/折算阈值与新鲜度窗在 HistoryAlertEvaluators（判定与常量同源）
	// 已报过的那一觉（按 wakeDate 记）：醒来 10 分钟内重启应用不能把同一条通知再发一遍
	private static let sleepDrainAlertedKey = "lastSleepDrainAlertWakeDate"
	// 低电预判与温度骤升的窗口/阈值在 DrainAlertEvaluators（判定与常量同源）
	private static let healthMilestoneKey = "healthMilestoneLastSeen"
	private static let weeklyDigestDateKey = "lastWeeklyDigestDate"
	private static let monthlyDigestDateKey = "lastMonthlyDigestDate"
	// 电量计校准提醒的冷却键；30 天冷却窗在 HistoryAlertEvaluators（判定与常量同源）
	private static let gaugeCalibrationAlertKey = "gaugeCalibrationAlertedAt"
	// 保养提醒"延后一会儿"的标记：到点前不再提醒，到点后重新武装
	private static let chargeCareSnoozeKey = "chargeCareSnoozeUntil"
	// 可交互通知类别：保养提醒可延后，慢充可复制诊断信息
	nonisolated static let chargeCareCategoryID = "charge-care"
	nonisolated static let slowChargeCategoryID = "slow-charge"

	init(monitor: BatteryMonitor, configurationManager: ConfigurationManager, historyRecorder: BatteryHistoryRecorder? = nil, defaults: UserDefaults = .standard, clock: HistoryClock = .live) {
		// NSObject 的 two-phase init：存储属性须在 super.init() 前就位（configurationManager/clock 是 let 非可选）
		self.monitor = monitor
		self.historyRecorder = historyRecorder
		self.configurationManager = configurationManager
		self.defaults = defaults
		self.clock = clock
		super.init()
		// 注册可交互通知类别并接管通知中心回调（面板打开时前台横幅也靠它）
		Self.registerNotificationCategories()
		UNUserNotificationCenter.current().delegate = self
		configurationManager.$configuration
			.sink { [weak self] configuration in
				guard let self else { return }
				self.configuration = configuration
				if self.isEnabled { self.requestAuthorizationIfNeeded() }
			}
			.store(in: &cancellables)
		
		monitor.$snapshot
			.sink { [weak self] snapshot in
				self?.evaluate(snapshot)
			}
			.store(in: &cancellables)
		
		monitor.$bluetoothDevices
			.sink { [weak self] devices in
				self?.evaluateBluetoothDevices(devices)
			}
			.store(in: &cancellables)
		
		monitor.$drainEstimate
			.sink { [weak self] estimate in
				self?.evaluateHighDrain(estimate)
			}
			.store(in: &cancellables)
		
		// 睡眠掉电记录更新时检查是否异常；启动时从磁盘捧出的旧记录靠时间窗口过滤
		historyRecorder?.sleep.$lastSleepDrain
			.compactMap { $0 }
			.removeDuplicates()
			.sink { [weak self] record in
				self?.evaluateSleepDrain(record)
			}
			.store(in: &cancellables)

		// H3：健康样本更新时评估降幅/循环异常
		historyRecorder?.health.$healthSamples
			.removeDuplicates()
			.sink { [weak self] _ in
				guard let self, let snap = self.monitor?.snapshot else { return }
				self.evaluateHealthAnomalies(snapshot: snap)
			}
			.store(in: &cancellables)

		// 电量跳变攒够阈值时提醒校准电量计
		historyRecorder?.soc.$socJumpEvents
			.removeDuplicates()
			.sink { [weak self] events in
				self?.evaluateGaugeCalibration(events)
			}
			.store(in: &cancellables)
	}
	
	private var isEnabled: Bool {
		configuration.enabledOptions.contains(.alerts)
	}
	
	// 总开关 + 细分开关都开才发这类提醒
	private func alertEnabled(_ kind: DisplayOption) -> Bool {
		isEnabled && configuration.enabledOptions.contains(kind)
	}
	
	private func requestAuthorizationIfNeeded() {
		guard !didRequestAuthorization else { return }
		didRequestAuthorization = true
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
			if let error {
				DiagnosticLog.failureOnce("notification-auth-failed", category: "BatteryAlertController", "通知授权失败：\(error.localizedDescription)")
			}
			Task { @MainActor in self?.refreshAuthorizationStatus() }
		}
	}
	
	// 用户随时可能在系统设置里改权限，每次打开面板时重新查一次
	func refreshAuthorizationStatus() {
		UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
			let denied = settings.authorizationStatus == .denied
			Task { @MainActor in
				guard let self, self.isNotificationPermissionDenied != denied else { return }
				self.isNotificationPermissionDenied = denied
			}
		}
	}
	
	private func evaluate(_ snapshot: BatterySnapshot) {
		lastSnapshot = snapshot
		trackOptimizedChargingPause(snapshot)
		guard isEnabled else { return }
		evaluateFull(snapshot)
		evaluateLowBattery(snapshot)
		evaluateHighTemperature(snapshot)
		evaluateTempSurge(snapshot)
		evaluateSlowCharge(snapshot)
		evaluateChargeCare(snapshot)
		evaluateFullForecast(snapshot)
		evaluateHealthMilestone(snapshot)
		evaluateHealthAnomalies(snapshot: snapshot)
		// 同一觉重试：免打扰吞掉后靠这里补发（wakeDate 去重 + 新鲜度窗防轰炸）
		if let pendingSleep = historyRecorder?.lastSleepDrain {
			evaluateSleepDrain(pendingSleep)
		}
		checkWeeklyDigest()
		checkMonthlyDigest()
	}
	
	// 边沿判定在 `ThresholdAlertEvaluators`（纯逻辑，可测）；这里只做外壳三件事：
	// 读配置成值、驱动判定、**发送成功才**提交置位（回写先于 shouldSend 分支，与保养那台同形）
	private func evaluateFull(_ snapshot: BatterySnapshot) {
		let result = FullChargeAlertEvaluator.evaluate(.init(
			snapshot: snapshot,
			isReminderEnabled: alertEnabled(.alertFull),
			didNotify: didNotifyFull
		))
		didNotifyFull = result.didNotify
		guard result.shouldSend else { return }
		if send(
			id: "battery-full",
			title: "电池已充满",
			body: "电量 100%，可以拔掉电源了"
		) {
			didNotifyFull = true
		}
	}

	private func evaluateLowBattery(_ snapshot: BatterySnapshot) {
		let result = LowBatteryAlertEvaluator.evaluate(.init(
			snapshot: snapshot,
			thresholdPercent: configuration.lowBatteryThresholdPercent,
			isReminderEnabled: alertEnabled(.alertLowBattery),
			didNotify: didNotifyLowBattery
		))
		didNotifyLowBattery = result.didNotify
		guard result.shouldSend else { return }
		// urgent 走免打扰旁路必投递；统一走 if send 形态防未来语义变化引入静默吞（v1.19.1）
		if send(
			id: "battery-low",
			title: "电量不足",
			body: "当前电量 \(snapshot.stateOfChargePercent ?? 0)%，请及时连接电源",
			urgent: true
		) {
			didNotifyLowBattery = true
		}
	}

	private func evaluateHighTemperature(_ snapshot: BatterySnapshot) {
		let result = HighTemperatureAlertEvaluator.evaluate(.init(
			snapshot: snapshot,
			thresholdCelsius: configuration.highTemperatureThresholdC,
			isReminderEnabled: alertEnabled(.alertHighTemperature),
			didNotify: didNotifyHighTemperature
		))
		didNotifyHighTemperature = result.didNotify
		guard result.shouldSend else { return }
		if send(
			id: "battery-hot",
			title: "电池温度偏高",
			body: String(format: "当前 %.1f°C，建议移到通风处，避免边充电边高负荷使用", snapshot.temperatureC ?? 0)
		) {
			didNotifyHighTemperature = true
		}
	}
	
	// 保养拔电提醒：想养电池的人，充到设定线（默认 80%）提醒一次可以拔了
	private func evaluateChargeCare(_ snapshot: BatterySnapshot) {
		// 状态判定已抽到 ChargeCareAlertEvaluator（纯逻辑、不碰 UN/send）。这里只做三件
		// 外壳做的事：把持久化与时钟读成值、驱动判定、**发送成功才**提交状态。
		// 这样"该不该发"第一次能在不构造 UN 外壳的情况下被真代码测试（见 evaluator 头部注释）。
		let result = ChargeCareAlertEvaluator.evaluate(
			ChargeCareAlertEvaluator.Input(
				snapshot: snapshot,
				isReminderEnabled: configuration.enabledOptions.contains(.chargeCareReminder),
				thresholdPercent: configuration.chargeCareThresholdPercent,
				state: ChargeCareAlertEvaluator.State(
					didObserveSystemHoldAtLine: didObserveSystemHoldAtLine,
					hasSilencedCareForSystemHold: hasSilencedCareForSystemHold,
					didNotifyChargeCare: didNotifyChargeCare
				),
				snoozeUntil: defaults.object(forKey: Self.chargeCareSnoozeKey) as? Date,
				now: clock.now()
			)
		)
		didObserveSystemHoldAtLine = result.state.didObserveSystemHoldAtLine
		hasSilencedCareForSystemHold = result.state.hasSilencedCareForSystemHold
		// 三个状态**全部**回写，一个都不能漏：拔电或 SOC 掉到重置线以下时 evaluator 会把
		// didNotifyChargeCare 清零，这里若不提交，Controller 里旧的 true 会继续挡在下一次
		// 充电的 guard 前——"提醒过一次就再也提醒不了"。回写必须早于下面的 shouldSend 分支，
		// 否则清零同样被提前 return 吞掉
		didNotifyChargeCare = result.state.didNotifyChargeCare
		guard result.shouldSend else { return }
		// 只有 send 成功（真投递）才置位；被免打扰/失败吞掉时下一条快照仍会重试
		if send(
			id: "charge-care",
			title: "已充到 \(snapshot.stateOfChargePercent ?? 0)%",
			body: "想保养电池的话，现在就可以拔电源了",
			category: Self.chargeCareCategoryID
		) {
			didNotifyChargeCare = true
		}
	}
	
	// 检测"系统优化充电在保养线附近反复暂停"：6 小时内 ≥3 次边沿即认定系统在替你
	// 保养电池——此时用户的保养提醒和系统是同一件事的两种表达，提示二选一
	private func trackOptimizedChargingPause(_ snapshot: BatterySnapshot) {
		let threshold = configuration.chargeCareThresholdPercent
		if ChargeCareAlertEvaluator.isCarePauseEdge(previousCharging: wasChargingNearCareLine, snapshot: snapshot, threshold: threshold) {
			carePauseEdges.append(clock.now())
		}
		wasChargingNearCareLine = snapshot.isCharging
		let cutoff = clock.now().addingTimeInterval(-6 * 3600)
		carePauseEdges.removeAll { $0 < cutoff }
		let holding = carePauseEdges.count >= 3
		if holding != isOptimizedChargingHolding {
			isOptimizedChargingHolding = holding
		}
	}

	// 外设低电：每个设备独立边沿触发，充回阈值+5 以上才允许再次提醒
	private func evaluateBluetoothDevices(_ devices: [BluetoothDeviceBattery]) {
		// 判定在 DeviceLowAlertEvaluator（纯逻辑、可测）；外壳先写回升重置后的集合，
		// 再对本次该发的设备逐个发送——只有发送成功才入集合，免打扰被吞时下轮补发。
		let result = DeviceLowAlertEvaluator.evaluate(.init(
			devices: devices,
			thresholdPercent: configuration.deviceLowThresholdPercent,
			isReminderEnabled: alertEnabled(.alertDeviceLow),
			notifiedDevices: notifiedLowDevices
		))
		notifiedLowDevices = result.notifiedDevices
		for device in result.devicesToNotify {
			if send(
				id: "device-low-\(device.name)",
				title: "外设电量不足",
				body: "\(device.name) 只剩 \(device.percent)%，记得充电"
			) {
				notifiedLowDevices.insert(device.name)
			}
		}
	}
	
	// 掉电窗口口径：与 DrainRateEstimate.windowSeconds 同源，避免短窗仍写「最近一小时」
	nonisolated static func drainWindowText(_ estimate: DrainRateEstimate?) -> String {
		guard let window = estimate?.windowSeconds, window > 0, window < 3600 else {
			return "最近一小时"
		}
		let minutes = max(1, window / 60)
		return "最近 \(minutes) 分钟"
	}

	// 耗电异常：掉电速度突然飙高时提醒，顺带点名高耗电应用
	// 典型场景：合盖没合好塞进包里烧电，或某个应用后台发疯
	private func evaluateHighDrain(_ estimate: DrainRateEstimate?) {
		guard isEnabled else { return }
		evaluateLowForecast(estimate)
		// 判定在 HighDrainAlertEvaluator（纯逻辑、可测）；外壳只读值、回写边沿、
		// 组装正文并在发送成功后才置位。
		let result = HighDrainAlertEvaluator.evaluate(.init(
			powerSource: lastSnapshot.powerSource,
			ratePerHour: estimate?.percentPerHour,
			thresholdPerHour: configuration.highDrainThresholdPerHour,
			isReminderEnabled: alertEnabled(.alertHighDrain),
			didNotify: didNotifyHighDrain
		))
		didNotifyHighDrain = result.didNotify
		guard result.shouldSend, let rate = estimate?.percentPerHour else { return }
		// 口径与 estimate.windowSeconds 同源：短窗时不得仍写「最近一小时」
		var body = String(format: "%@掉电 %.0f%%/小时，比平时快不少", Self.drainWindowText(estimate), rate)
		if let culprit = monitor?.significantEnergyApps.first?.name, !culprit.isEmpty {
			body += "，「\(culprit)」正在高耗电"
		}
		if send(id: "high-drain", title: "掉电有点快", body: body) {
			didNotifyHighDrain = true
		}
	}
	
	// 低电预判：还没到警示线，但按当前掉速撞线在即，提前喊一声好找插座
	private func evaluateLowForecast(_ estimate: DrainRateEstimate?) {
		// 判定与距线分钟数都在 LowForecastAlertEvaluator（纯逻辑、可测）；
		// 外壳只读值、回写边沿、组装正文并在发送成功后才置位。
		let result = LowForecastAlertEvaluator.evaluate(.init(
			snapshot: lastSnapshot,
			ratePerHour: estimate?.percentPerHour,
			thresholdPercent: configuration.lowBatteryThresholdPercent,
			isReminderEnabled: alertEnabled(.alertLowForecast),
			didNotify: didNotifyLowForecast
		))
		didNotifyLowForecast = result.didNotify
		guard result.shouldSend, let minutes = result.minutesToThreshold else { return }
		if send(
			id: "low-forecast",
			title: "电量快要告急",
			body: "按当前掉电速度，约 \(Int(minutes)) 分钟后就到 \(configuration.lowBatteryThresholdPercent)% 了，附近有插座就充上吧"
		) {
			didNotifyLowForecast = true
		}
	}
	
	// 充满预告：插电开充后预告一声几点能充满，一次性不骚扰
	private func evaluateFullForecast(_ snapshot: BatterySnapshot) {
		// 判定在 FullForecastAlertEvaluator（纯逻辑、可测）；外壳只读值、回写边沿、
		// 组装正文并在发送成功后才置位。
		let result = FullForecastAlertEvaluator.evaluate(.init(
			snapshot: snapshot,
			isReminderEnabled: alertEnabled(.alertFullForecast),
			didNotify: didNotifyFullForecast
		))
		didNotifyFullForecast = result.didNotify
		guard result.shouldSend, let minutes = result.minutes else { return }
		if send(
			id: "full-forecast",
			title: "开始充电",
			body: "预计 \(DurationFormatter.clockText(afterMinutes: minutes)) 充满（还需 \(DurationFormatter.chinese(minutes: minutes))）"
		) {
			didNotifyFullForecast = true
		}
	}
	
	// 温度骤升：不等到高温线，短时间内快速升温就先提个醒
	private func evaluateTempSurge(_ snapshot: BatterySnapshot) {
		// 判定与环形缓存在 TempSurgeAlertEvaluator（纯逻辑、可测）；外壳只把缓存
		// 读成值、回写状态、组装正文并在发送成功后才置位。缺温度时 evaluator
		// 原样返回状态——缓存不清，等下一拍有读数再比。
		let result = TempSurgeAlertEvaluator.evaluate(.init(
			temperatureCelsius: snapshot.temperatureC,
			now: clock.now(),
			isReminderEnabled: alertEnabled(.alertTempSurge),
			state: TempSurgeAlertEvaluator.State(
				recentTemps: recentTemps.map { TempSurgeAlertEvaluator.Sample(date: $0.date, celsius: $0.celsius) },
				didNotify: didNotifyTempSurge
			)
		))
		recentTemps = result.state.recentTemps.map { ($0.date, $0.celsius) }
		didNotifyTempSurge = result.state.didNotify
		guard result.shouldSend,
			  let baseline = result.baselineCelsius,
			  let celsius = snapshot.temperatureC
		else { return }
		if send(
			id: "temp-surge",
			title: "温度上升较快",
			body: String(format: "5 分钟内从 %.1f°C 升到 %.1f°C，留意下是不是在跑重任务或散热不良", baseline, celsius)
		) {
			didNotifyTempSurge = true
		}
	}
	
	// 健康度里程碑：跌破 90/85/80 各提醒一次，基准持久化防重启后重发。
	// 判定在 HealthMilestoneAlertEvaluator（纯逻辑、可测）；两种写回时机分开：
	// milestoneToPersist 是非发送路径马上写的（首次/回升/开关关着穿越），
	// shouldSend 那条必须等 send 成功后才落基准。
	private func evaluateHealthMilestone(_ snapshot: BatterySnapshot) {
		let result = HealthMilestoneAlertEvaluator.evaluate(.init(
			healthPercent: snapshot.healthPercent,
			isReminderEnabled: alertEnabled(.alertHealthMilestone),
			storedMilestone: defaults.integer(forKey: Self.healthMilestoneKey),
			milestones: HealthMilestoneAlertEvaluator.defaultMilestones
		))
		if let persist = result.milestoneToPersist {
			defaults.set(persist, forKey: Self.healthMilestoneKey)
		}
		guard result.shouldSend,
			  let lowest = result.lowestCrossed,
			  let health = result.healthPercent
		else { return }
		let crossedList = result.crossedMilestones.map(String.init).joined(separator: "/")
		let suffix = lowest == 80 ? "，已到官方建议检测电池的参考线" : "，属正常老化，留意即可"
		// 投递失败（免打扰）不落基准，下一轮仍可补发（v1.19.1）
		if send(
			id: "health-milestone-\(lowest)",
			title: "电池健康度跌破 \(lowest)%",
			body: "当前健康度 \(health)%（已跌破 \(crossedList)%）" + suffix
		) {
			defaults.set(health, forKey: Self.healthMilestoneKey)
		}
	}

	// MARK: - H3 健康异常（降幅 + 循环里程碑；与 90/85/80 里程碑分键）

	private static let healthDeclineDedupKey = "healthDeclineLastNotifiedDay"

	func evaluateHealthAnomalies(snapshot: BatterySnapshot) {
		guard alertEnabled(.alertHealthMilestone) else { return }
		let config = configuration
		let now = clock.now()
		let todayKey = HealthAnomalyAlertEvaluator.dayKey(date: now)

		// 30 天降幅：同一天只提醒一次；判定在 HealthAnomalyAlertEvaluator（纯逻辑、可测）
		let decline = HealthAnomalyDetector.healthDeclineFinding(
			// 换电池边界过滤后才比：新旧电芯尾/头相连会拼出假骤降
			samples: historyRecorder?.trendHealthSamples ?? [],
			thresholdPoints: config.healthDeclineThresholdPoints,
			windowDays: HealthAnomalyDetector.defaultDeclineWindowDays,
			now: now
		)
		// 循环里程碑：配置里的 lastCycleMilestoneSeen 做跨过检测
		let cycle = HealthAnomalyDetector.cycleMilestoneFinding(
			cycleCount: snapshot.cycleCount,
			lastSeenCycles: config.lastCycleMilestoneSeen,
			milestones: config.cycleMilestoneThresholds
		)
		let result = HealthAnomalyAlertEvaluator.evaluate(.init(
			declineFinding: decline,
			lastDeclineNotifiedDay: defaults.string(forKey: Self.healthDeclineDedupKey),
			todayDayKey: todayKey,
			cycleFinding: cycle,
			cycleCount: snapshot.cycleCount
		))

		if let finding = result.declineToSend,
		   send(id: finding.notificationID, title: finding.title, body: finding.body) {
			defaults.set(todayKey, forKey: Self.healthDeclineDedupKey)
		}

		if let finding = result.cycleToSend,
		   send(id: finding.notificationID, title: finding.title, body: finding.body),
		   let seen = result.cycleMilestoneToPersist {
			// 成功才推进 seen，免打扰吞掉后下轮可补
			applyCycleMilestoneSeen(seen)
		}
	}

	private func applyCycleMilestoneSeen(_ seen: Int) {
		// 走 init 注入的同一实例写回：设置窗口改的就是它，同源不靠裸取全局。
		// （早先这里写 .shared 且类里没这个成员，依赖靠的是全局偶合。）
		configurationManager.setHealthCycleMilestoneSeen(seen)
	}
	
	private func evaluateSlowCharge(_ snapshot: BatterySnapshot) {
		// 判定在 SlowChargeAlertEvaluator（纯逻辑、可测）；外壳只读值、回写边沿、
		// 组装正文并在发送成功后才置位。
		let result = SlowChargeAlertEvaluator.evaluate(.init(
			snapshot: snapshot,
			isReminderEnabled: alertEnabled(.alertSlowCharge),
			didNotify: didNotifySlowCharge
		))
		didNotifySlowCharge = result.didNotify
		guard result.shouldSend,
			  let watts = result.negotiatedWatts,
			  let rated = result.ratedWatts
		else { return }
		if send(
			id: "slow-charge",
			title: "检测到慢充",
			body: String(format: "协商档位仅 %.0fW（充电器额定 %dW），请检查数据线或接口", watts, rated),
			category: Self.slowChargeCategoryID
		) {
			didNotifySlowCharge = true
		}
	}
	
	// 睡眠掉电异常：合盖一觉掉得太多，多半是有应用在阻止休眠或“断电时唤醒”在捣鬼
	private func evaluateSleepDrain(_ record: SleepDrainRecord) {
		// 判定在 SleepDrainAlertEvaluator（纯逻辑、可测）；外壳只读持久化、组装正文，
		// 发送成功后才记 wakeDate（同一觉去重）。
		let result = SleepDrainAlertEvaluator.evaluate(.init(
			record: record,
			now: clock.now(),
			lastAlertedWakeDate: defaults.object(forKey: Self.sleepDrainAlertedKey) as? Date,
			isEnabled: isEnabled,
			isReportEnabled: configuration.enabledOptions.contains(.sleepDrainReport)
		))
		guard result.shouldSend else { return }

		// 元凶名单由历史记录器在醒来时抓取并留档，这里直接复述
		var body = String(format: "合盖 %@ 掉了 %d%%（%.1f%%/小时），可能有应用在阻止睡眠", DurationFormatter.chinese(minutes: record.durationMinutes), record.droppedPercent, record.dropPerHour)
		if let owners = record.culpritNames, !owners.isEmpty {
			body += "\n正在阻止睡眠：\(owners.joined(separator: "、"))"
		}
		// 投递失败（免打扰）不记账；evaluate() 周期会带着同一觉重试，
		// 新鲜度窗（8h）内免打扰结束后补发一次，wakeDate 去重保证不轰炸
		if send(id: "sleep-drain", title: "睡眠掉电偏多", body: body),
		   let wake = result.wakeDateToPersist {
			defaults.set(wake, forKey: Self.sleepDrainAlertedKey)
		}
	}
	
	// 电量计校准提醒：30 天内跳变攒够阈值提醒做一次完整充放循环；
	// 条件可能长期成立（老化的电量计跳变是常态），用时间冷却而不是边沿重置防轰炸
	private func evaluateGaugeCalibration(_ events: [SocJumpEvent]) {
		// 判定在 GaugeCalibrationAlertEvaluator（纯逻辑、可测）；外壳只算 30 天跳变计数、
		// 读冷却标记，发送成功后才写冷却起点（免打扰吞掉时不能空转 30 天）。
		let now = clock.now()
		let count = UsagePatternAnalyzer.socJumpCount(events, withinDays: 30, now: now)
		let result = GaugeCalibrationAlertEvaluator.evaluate(.init(
			jumpCount: count,
			isEnabled: isEnabled,
			isReminderEnabled: alertEnabled(.alertGaugeCalibration),
			lastAlerted: defaults.object(forKey: Self.gaugeCalibrationAlertKey) as? Date,
			now: now
		))
		guard result.shouldSend, let alertAt = result.alertAtToPersist else { return }
		if send(
			id: "gauge-calibration",
			title: "电量计可能失准",
			body: "最近 30 天记录到 \(count) 次电量跳变（电量突然变化 2% 以上）。建议做一次完整的充放循环，帮电量计重新校准"
		) {
			defaults.set(alertAt, forKey: Self.gaugeCalibrationAlertKey)
		}
	}

	// 周报/月报发送许可（纯函数，供单测）：上次发送早于本次到点时间才发。
	// 但标记若离谱地落在未来（>24h——发通知时系统时钟被调快过），视为失效：
	// 否则时钟回拨后，这一期小结会被一个”来自未来的标记”永久静默
	nonisolated static func digestSendAllowed(lastSent: Date?, due: Date, now: Date, futureTolerance: TimeInterval = 24 * 3600) -> Bool {
		guard let lastSent else { return true }
		if lastSent.timeIntervalSince(now) > futureTolerance { return true }
		return lastSent < due
	}

	// 每周电池周报：周日 20 点后第一次有机会时发；错过就顺延到下次启动
	private func checkWeeklyDigest() {
		guard isEnabled, configuration.enabledOptions.contains(.weeklyDigest) else { return }
		guard let due = Self.mostRecentDigestDue(before: clock.now()) else { return }
		// 首次运行只记个时间标记不发：刚装上就报”本周”没意义
		guard let lastSent = defaults.object(forKey: Self.weeklyDigestDateKey) as? Date else {
			defaults.set(clock.now(), forKey: Self.weeklyDigestDateKey)
			return
		}
		guard Self.digestSendAllowed(lastSent: lastSent, due: due, now: clock.now()), let recorder = historyRecorder else { return }

		let weekStart = due.addingTimeInterval(-7 * 86400)
		let sessionCount = recorder.recentSessions.filter { $0.startDate >= weekStart }.count
		let body = Self.weeklyDigestBody(
			history: recorder.dailyHistory,
			sessionCount: sessionCount,
			healthPercent: lastSnapshot.healthPercent,
			dwellLine: DwellTracking.weeklyDigestLine(
				history: recorder.dailyHistory,
				due: due
			),
			due: due
		)
		// 无内容也记账：本期确实没什么可说，别让 digestSendAllowed 每轮空转
		guard !body.isEmpty else {
			defaults.set(clock.now(), forKey: Self.weeklyDigestDateKey)
			return
		}
		// 投递成功才记账——免打扰吞掉时保留 lastSent，下一轮仍可补发本期
		if send(id: "weekly-digest", title: "本周电池小结", body: body) {
			defaults.set(clock.now(), forKey: Self.weeklyDigestDateKey)
		}
	}
	
	// 最近一个已到点的”周日 20:00”；周日 20 点前返回上周的
	// 纯函数，标 nonisolated 方便单元测试直接调（calendar 可注入，与月报对称）
	nonisolated static func mostRecentDigestDue(before now: Date, calendar: Calendar = .current) -> Date? {
		let todayStart = calendar.startOfDay(for: now)
		let weekday = calendar.component(.weekday, from: now) // 1 = 周日
		guard
			let sunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: todayStart),
			let due = calendar.date(byAdding: .hour, value: 20, to: sunday)
		else { return nil }
		if now >= due { return due }
		return calendar.date(byAdding: .day, value: -7, to: due)
	}
	
	// 周报正文：只统计 due 截止的近 7 日窗——对全部历史求和会把「装上以来」说成「本周」
	// 这周没产生任何用电数据（且无充电次数）就返回空串（不发也罢）
	nonisolated static func weeklyDigestBody(
		history: [DailyUsage],
		sessionCount: Int,
		healthPercent: Int?,
		dwellLine: String? = nil,
		due: Date,
		calendar: Calendar = .current
	) -> String {
		let keys = DwellTracking.dayKeys(endingOn: due, count: 7, calendar: calendar)
		let stats = EnergyAggregation.aggregate(history: history, dayKeys: keys)
		guard stats.totalDrainedPercent > 0 || stats.totalChargedPercent > 0 || sessionCount > 0 else { return "" }

		var summary = EnergyAggregation.digestSummary(label: "本周", stats: stats)
		if summary.isEmpty {
			// 窗口内无有效能耗样本，但本周有充电记录——仍要交代次数，电量诚实写 0
			summary = "本周用电 0%、充入 0%"
		}
		summary += "、充电 \(sessionCount) 次"
		var parts = [summary]
		if let health = healthPercent {
			parts.append("健康度 \(health)%")
		}
		if let dwellLine, !dwellLine.isEmpty {
			parts.append(dwellLine)
		}
		return parts.joined(separator: "；")
	}

	// MARK: - 每月电池月报

	// 每月 1 号 9 点后第一次有机会时发上月小结；错过顺延到下次启动
	// 与周报共用 weeklyDigest 开关（同为"定期小结"）
	private func checkMonthlyDigest() {
		guard isEnabled, configuration.enabledOptions.contains(.weeklyDigest) else { return }
		guard let due = Self.mostRecentMonthlyDigestDue(before: clock.now()) else { return }
		guard let lastSent = defaults.object(forKey: Self.monthlyDigestDateKey) as? Date else {
			defaults.set(clock.now(), forKey: Self.monthlyDigestDateKey)
			return
		}
		guard Self.digestSendAllowed(lastSent: lastSent, due: due, now: clock.now()), let recorder = historyRecorder else { return }

		let body = Self.monthlyDigestBody(
			history: recorder.dailyHistory,
			sessions: recorder.recentSessions,
			healthSamples: recorder.healthSamples,
			due: due
		)
		guard !body.isEmpty else {
			defaults.set(clock.now(), forKey: Self.monthlyDigestDateKey)
			return
		}
		// 投递成功才记账——免打扰吞掉时下一轮仍可补发本期
		if send(id: "monthly-digest", title: "上月电池小结", body: body) {
			defaults.set(clock.now(), forKey: Self.monthlyDigestDateKey)
		}
	}

	// 最近一个已到点的"本月 1 号 09:00"；本月 1 号 9 点前返回上月的
	nonisolated static func mostRecentMonthlyDigestDue(before now: Date, calendar: Calendar = .current) -> Date? {
		guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) else { return nil }
		guard let due = calendar.date(byAdding: .hour, value: 9, to: monthStart) else { return nil }
		if now >= due { return due }
		return calendar.date(byAdding: .month, value: -1, to: due)
	}

	// 月报正文：汇总 due 所在月的上一个自然月；没数据返回空串不发
	nonisolated static func monthlyDigestBody(
		history: [DailyUsage],
		sessions: [ChargeSession],
		healthSamples: [HealthSample],
		due: Date,
		calendar: Calendar = .current
	) -> String {
		guard let dueMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: due)),
			  let prevMonthStart = calendar.date(byAdding: .month, value: -1, to: dueMonthStart)
		else { return "" }
		let prefix = UsagePatternAnalyzer.monthKeyString(prevMonthStart, calendar: calendar)

		let stats = EnergyAggregation.monthAggregate(history: history, monthPrefix: prefix)
		let sessionCount = sessions.filter { UsagePatternAnalyzer.monthKeyString($0.startDate, calendar: calendar).hasPrefix(prefix) }.count
		guard stats.totalDrainedPercent > 0 || stats.totalChargedPercent > 0 || sessionCount > 0 else { return "" }

		// 日均按有效样本日：日历天数会把「没记录的日子」摊成 0，系统性压低用电画像
		var parts = [String(format: "上月用电 %d%%、充入 %d%%、充电 %d 次", stats.totalDrainedPercent, stats.totalChargedPercent, sessionCount)]
		if let avg = stats.avgDrainedPerDataDay, stats.dataDays > 0 {
			parts.append("记录 \(stats.dataDays) 天，日均用电 \(Int(avg.rounded()))%")
		}
		if let lastHealth = healthSamples.last(where: { UsagePatternAnalyzer.monthKeyString($0.date, calendar: calendar).hasPrefix(prefix) }) {
			parts.append("月末健康度 \(lastHealth.healthPercent)%")
		}
		return parts.joined(separator: "；")
	}
	
	// 夜间免打扰：设定时段内非紧急通知不发（低电量这种紧急的照发）；
	// 时段可跨零点（如 23 点–次日 8 点），起止相同视为关闭，避免全天静音
	nonisolated static func isQuietHour(_ hour: Int, start: Int, end: Int) -> Bool {
		guard start != end else { return false }
		if start < end { return hour >= start && hour < end }
		return hour >= start || hour < end
	}

	private var isInQuietHours: Bool {
		guard configuration.enabledOptions.contains(.quietHours) else { return false }
		let hour = clock.calendar.component(.hour, from: clock.now())
		return Self.isQuietHour(hour, start: configuration.quietHoursStartHour, end: configuration.quietHoursEndHour)
	}

	// 发送通知（v1.19.1 返回值语义化）：返回是否真正投递——免打扰时段非紧急通知被
	// 静默跳过时返回 false，调用方不落”已通知”标记，免打扰结束、条件仍成立时下一轮补发
	// （此前 flag 在 send 前落位，夜间被吞的提醒永远丢失——健康里程碑尤其致命，一次性）。
	@discardableResult
	private func send(id: String, title: String, body: String, urgent: Bool = false, category: String = "") -> Bool {
		if isInQuietHours, !urgent { return false }

		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		content.categoryIdentifier = category
		// 紧急提醒（低电量等）标为时效性通知，专注模式下才真正能穿透；
		// 需要用户在系统设置里授予”时效性通知”权限，未授予时按普通通知处理
		content.interruptionLevel = urgent ? .timeSensitive : .active

		let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
		UNUserNotificationCenter.current().add(request) { error in
			if let error {
				DiagnosticLog.failureOnce("notification-send-failed", category: "BatteryAlertController", "发送通知失败：\(error.localizedDescription)")
			}
		}
		return true
	}

	// MARK: - 可交互通知

	nonisolated static func registerNotificationCategories() {
		let snooze = UNNotificationAction(identifier: "snooze-charge-care", title: "延后 30 分钟", options: [])
		let copyDiagnostics = UNNotificationAction(identifier: "copy-charge-diagnostics", title: "复制诊断信息", options: [])
		let chargeCare = UNNotificationCategory(identifier: chargeCareCategoryID, actions: [snooze], intentIdentifiers: [])
		let slowCharge = UNNotificationCategory(identifier: slowChargeCategoryID, actions: [copyDiagnostics], intentIdentifiers: [])
		UNUserNotificationCenter.current().setNotificationCategories([chargeCare, slowCharge])
	}

	// 用户点了"延后 30 分钟"：静音窗口 + 重新武装提醒（到点后若仍在线上会再喊一次）
	private func snoozeChargeCare(minutes: Int) {
		defaults.set(clock.now().addingTimeInterval(TimeInterval(minutes) * 60), forKey: Self.chargeCareSnoozeKey)
		didNotifyChargeCare = false
	}

	// 慢充通知的"复制诊断信息"：把协议/档位/额定打包进剪贴板，方便反馈或对照
	private func copyChargeDiagnostics() {
		guard let snapshot = monitor?.snapshot else { return }
		var lines: [String] = []
		if let protocolName = snapshot.chargingProtocol { lines.append("充电协议：\(protocolName)") }
		if let voltageMV = snapshot.negotiatedVoltageMV, let currentMA = snapshot.negotiatedCurrentMA {
			let watts = Double(voltageMV) * Double(currentMA) / 1_000_000
			lines.append(String(format: "协商档位：%.0fV × %.0fA ≈ %.0fW", Double(voltageMV) / 1000, Double(currentMA) / 1000, watts))
		}
		if let rated = snapshot.adapterRatedWatts { lines.append("适配器额定：\(rated)W") }
		lines.append("适配器：\(snapshot.adapterName ?? "未知") \(snapshot.adapterManufacturer ?? "")".trimmingCharacters(in: .whitespaces))
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
	}
}

// 通知中心回调：协议回调来自非隔离上下文，统一跳回 MainActor 处理
extension BatteryAlertController: UNUserNotificationCenterDelegate {
	// 应用在前台（面板打开）时通知默认被系统吞掉——改成照样弹横幅，
	// 否则用户盯着面板的时候充满/低电提醒会凭空消失
	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		willPresent notification: UNNotification
	) async -> UNNotificationPresentationOptions {
		[.banner, .sound]
	}

	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse
	) async {
		await handleNotificationResponse(response)
	}

	@MainActor
	private func handleNotificationResponse(_ response: UNNotificationResponse) {
		switch response.actionIdentifier {
		case "snooze-charge-care":
			snoozeChargeCare(minutes: 30)
		case "copy-charge-diagnostics":
			copyChargeDiagnostics()
		default:
			// 点通知本体（v1.18.9）：打开面板看详情——此前默认动作什么都不做，
			// 通知只是消失，信任链断在"通知→查看"。面板是否打开由 PanelOpenPolicy 判
			NotificationCenter.default.post(name: PanelNotifications.openPanelRequest, object: nil)
		}
	}
}
