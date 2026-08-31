import Combine
import Foundation
import UserNotifications

// 电池状态提醒：充满、低电量及预判、高温及骤升、慢充、保养拔电、外设低电、
// 耗电异常、睡眠掉电、健康里程碑、充满预告、每周周报
// 采用边沿触发——进入状态时只提醒一次，离开状态后重置；
// 每类提醒有独立开关，夜间免打扰时段非紧急通知不发
@MainActor
final class BatteryAlertController: ObservableObject {
	// 开了提醒但系统通知权限被拒：提醒实际发不出去，面板上要给出警告
	@Published private(set) var isNotificationPermissionDenied = false
	
	private var cancellables: Set<AnyCancellable> = []
	private var configuration = AppConfiguration.default
	private var didRequestAuthorization = false
	// 耗电异常提醒要结合电源状态和高耗电应用名，留一份引用现取
	private weak var monitor: BatteryMonitor?
	// 周报数据从用电历史/充电记录里汇总
	private weak var historyRecorder: BatteryHistoryRecorder?
	private var lastSnapshot = BatterySnapshot()
	private let defaults = UserDefaults.standard
	
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
	
	// 阈值大多由用户在设置里调，重置线随阈值派生，避免临界抖动
	private static let slowChargeRatio = 0.55
	private static let slowChargeMinRatedWatts = 10
	private static let deviceLowResetMargin = 5
	private static let highDrainResetMargin = 5.0
	// 睡眠掉电异常：合盖≥ 1 小时、掉电≥ 5% 且折算≥ 2%/小时才提醒
	// nonisolated：纯判定函数 shouldAlertSleepDrain 要在非隔离上下文读它们
	nonisolated private static let sleepDrainAlertMinMinutes = 60
	nonisolated private static let sleepDrainAlertMinPercent = 5
	nonisolated private static let sleepDrainAlertMinPerHour = 2.0
	// 只对醒来后这段时间内的记录报警，启动时从磁盘捧出来的旧记录不算
	nonisolated private static let sleepDrainAlertFreshnessSeconds: TimeInterval = 10 * 60
	// 已报过的那一觉（按 wakeDate 记）：醒来 10 分钟内重启应用不能把同一条通知再发一遍
	private static let sleepDrainAlertedKey = "lastSleepDrainAlertWakeDate"
	// 低电预判：按当前掉速距警示线不足 45 分钟就提前喊一声
	private static let lowForecastLeadMinutes = 45.0
	// 温度骤升：5 分钟内涨 3°C 且已到 35°C 以上
	private static let tempSurgeWindowSeconds: TimeInterval = 5 * 60
	private static let tempSurgeDeltaC = 3.0
	private static let tempSurgeMinC = 35.0
	// 健康度里程碑：跌破这几档各提醒一次（一生只发三条的克制提醒）
	private static let healthMilestones = [90, 85, 80]
	private static let healthMilestoneKey = "healthMilestoneLastSeen"
	private static let weeklyDigestDateKey = "lastWeeklyDigestDate"
	private static let monthlyDigestDateKey = "lastMonthlyDigestDate"
	// 电量计校准提醒的冷却键：30 天内不重复提醒（跳变条件可能长期成立）
	private static let gaugeCalibrationAlertKey = "gaugeCalibrationAlertedAt"
	private static let gaugeCalibrationCooldownSeconds: TimeInterval = 30 * 86400
	
	init(monitor: BatteryMonitor, configurationManager: ConfigurationManager, historyRecorder: BatteryHistoryRecorder? = nil) {
		self.monitor = monitor
		self.historyRecorder = historyRecorder
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
		historyRecorder?.$lastSleepDrain
			.compactMap { $0 }
			.removeDuplicates()
			.sink { [weak self] record in
				self?.evaluateSleepDrain(record)
			}
			.store(in: &cancellables)

		// 电量跳变攒够阈值时提醒校准电量计
		historyRecorder?.$socJumpEvents
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
		guard isEnabled else { return }
		evaluateFull(snapshot)
		evaluateLowBattery(snapshot)
		evaluateHighTemperature(snapshot)
		evaluateTempSurge(snapshot)
		evaluateSlowCharge(snapshot)
		evaluateChargeCare(snapshot)
		evaluateFullForecast(snapshot)
		evaluateHealthMilestone(snapshot)
		checkWeeklyDigest()
		checkMonthlyDigest()
	}
	
	private func evaluateFull(_ snapshot: BatterySnapshot) {
		let isFullOnAdapter = snapshot.powerSource == .powerAdapter && snapshot.isFull
		if isFullOnAdapter {
			guard !didNotifyFull, alertEnabled(.alertFull) else { return }
			didNotifyFull = true
			send(
				id: "battery-full",
				title: "电池已充满",
				body: "电量 100%，可以拔掉电源了"
			)
		} else {
			didNotifyFull = false
		}
	}
	
	private func evaluateLowBattery(_ snapshot: BatterySnapshot) {
		guard let soc = snapshot.stateOfChargePercent else { return }
		let threshold = configuration.lowBatteryThresholdPercent
		let isLowOnBattery = snapshot.powerSource == .battery && soc <= threshold
		
		if isLowOnBattery {
			guard !didNotifyLowBattery, alertEnabled(.alertLowBattery) else { return }
			didNotifyLowBattery = true
			send(
				id: "battery-low",
				title: "电量不足",
				body: "当前电量 \(soc)%，请及时连接电源",
				urgent: true
			)
		} else if snapshot.powerSource == .powerAdapter || soc >= threshold + 5 {
			didNotifyLowBattery = false
		}
	}
	
	private func evaluateHighTemperature(_ snapshot: BatterySnapshot) {
		guard let temperature = snapshot.temperatureC else { return }
		let threshold = Double(configuration.highTemperatureThresholdC)
		
		if temperature >= threshold {
			guard !didNotifyHighTemperature, alertEnabled(.alertHighTemperature) else { return }
			didNotifyHighTemperature = true
			send(
				id: "battery-hot",
				title: "电池温度偏高",
				body: String(format: "当前 %.1f°C，建议移到通风处，避免边充电边高负荷使用", temperature)
			)
		} else if temperature < threshold - 2 {
			didNotifyHighTemperature = false
		}
	}
	
	// 保养拔电提醒：想养电池的人，充到设定线（默认 80%）提醒一次可以拔了
	private func evaluateChargeCare(_ snapshot: BatterySnapshot) {
		guard configuration.enabledOptions.contains(.chargeCareReminder) else { return }
		guard let soc = snapshot.stateOfChargePercent else { return }
		let threshold = configuration.chargeCareThresholdPercent
		
		if snapshot.isCharging, !snapshot.isFull, soc >= threshold {
			guard !didNotifyChargeCare else { return }
			didNotifyChargeCare = true
			send(
				id: "charge-care",
				title: "已充到 \(soc)%",
				body: "想保养电池的话，现在就可以拔电源了"
			)
		} else if snapshot.powerSource != .powerAdapter || soc < threshold - 5 {
			// 重置条件看“拔没拔电源”而非“在不在充电”：
			// 系统优化充电会在 80% 附近反复暂停/恢复充电，
			// 若暂停就重置，插一晚上电源会被反复提醒好几次
			didNotifyChargeCare = false
		}
	}
	
	// 外设低电：每个设备独立边沿触发，充回阈值+5 以上才允许再次提醒
	private func evaluateBluetoothDevices(_ devices: [BluetoothDeviceBattery]) {
		guard alertEnabled(.alertDeviceLow) else { return }
		let threshold = configuration.deviceLowThresholdPercent
		
		for device in devices {
			if device.percent <= threshold, device.percent > 0 {
				guard !notifiedLowDevices.contains(device.name) else { continue }
				notifiedLowDevices.insert(device.name)
				send(
					id: "device-low-\(device.name)",
					title: "外设电量不足",
					body: "\(device.name) 只剩 \(device.percent)%，记得充电"
				)
			} else if device.percent >= threshold + Self.deviceLowResetMargin {
				notifiedLowDevices.remove(device.name)
			}
		}
	}
	
	// 耗电异常：掉电速度突然飙高时提醒，顺带点名高耗电应用
	// 典型场景：合盖没合好塞进包里烧电，或某个应用后台发疯
	private func evaluateHighDrain(_ estimate: DrainRateEstimate?) {
		guard isEnabled else { return }
		evaluateLowForecast(estimate)
		guard let rate = estimate?.percentPerHour else {
			// 接上电源后估算器清空、发布 nil：视作离开异常状态，重置提醒
			// 电池模式下的 nil（睡眠清空重新积累）不重置，防止一觉醒来被重复轰炸
			if lastSnapshot.powerSource != .battery { didNotifyHighDrain = false }
			return
		}
		let threshold = Double(configuration.highDrainThresholdPerHour)
		
		let isAbnormal = lastSnapshot.powerSource == .battery && rate >= threshold
		if isAbnormal {
			guard !didNotifyHighDrain, alertEnabled(.alertHighDrain) else { return }
			didNotifyHighDrain = true
			var body = String(format: "最近一小时掉电 %.0f%%/小时，比平时快不少", rate)
			if let culprit = monitor?.significantEnergyApps.first?.name, !culprit.isEmpty {
				body += "，「\(culprit)」正在高耗电"
			}
			send(id: "high-drain", title: "掉电有点快", body: body)
		} else if lastSnapshot.powerSource != .battery || rate < threshold - Self.highDrainResetMargin {
			didNotifyHighDrain = false
		}
	}
	
	// 低电预判：还没到警示线，但按当前掉速撞线在即，提前喊一声好找插座
	private func evaluateLowForecast(_ estimate: DrainRateEstimate?) {
		guard let soc = lastSnapshot.stateOfChargePercent else { return }
		let threshold = configuration.lowBatteryThresholdPercent
		
		// 接电、已进低电区、或估算消失（插电清空）都重置
		if lastSnapshot.powerSource != .battery || soc <= threshold {
			didNotifyLowForecast = false
			return
		}
		guard let rate = estimate?.percentPerHour, rate > 0.5 else { return }
		
		let minutesToThreshold = Double(soc - threshold) / rate * 60
		if minutesToThreshold <= Self.lowForecastLeadMinutes {
			guard !didNotifyLowForecast, alertEnabled(.alertLowForecast) else { return }
			didNotifyLowForecast = true
			send(
				id: "low-forecast",
				title: "电量快要告急",
				body: "按当前掉电速度，约 \(Int(minutesToThreshold)) 分钟后就到 \(threshold)% 了，附近有插座就充上吧"
			)
		} else if minutesToThreshold > Self.lowForecastLeadMinutes * 2 {
			// 掉速回落、缓冲充足后才重置，避免在临界点反复横跳
			didNotifyLowForecast = false
		}
	}
	
	// 充满预告：插电开充后预告一声几点能充满，一次性不骚扰
	private func evaluateFullForecast(_ snapshot: BatterySnapshot) {
		if snapshot.powerSource != .powerAdapter {
			// 只有真拔电才重置：优化充电在 80% 暂停/恢复不算新一次充电
			didNotifyFullForecast = false
			return
		}
		guard snapshot.isCharging, !snapshot.isFull else { return }
		guard let minutes = snapshot.timeToFullChargeMinutes, minutes >= 10 else { return }
		guard !didNotifyFullForecast, alertEnabled(.alertFullForecast) else { return }
		
		didNotifyFullForecast = true
		send(
			id: "full-forecast",
			title: "开始充电",
			body: "预计 \(DurationFormatter.clockText(afterMinutes: minutes)) 充满（还需 \(DurationFormatter.chinese(minutes: minutes))）"
		)
	}
	
	// 温度骤升：不等到高温线，短时间内快速升温就先提个醒
	private func evaluateTempSurge(_ snapshot: BatterySnapshot) {
		guard let celsius = snapshot.temperatureC else { return }
		let now = Date()
		
		// 采样断档（睡过）则清空重来，跨睡眠的温差没意义
		if let last = recentTemps.last, now.timeIntervalSince(last.date) > 120 {
			recentTemps.removeAll()
		}
		recentTemps.append((now, celsius))
		recentTemps.removeAll { now.timeIntervalSince($0.date) > Self.tempSurgeWindowSeconds + 60 }
		
		// 找窗口起点（约 5 分钟前）的温度作对比
		guard let baseline = recentTemps.first(where: { now.timeIntervalSince($0.date) <= Self.tempSurgeWindowSeconds }) else { return }
		guard now.timeIntervalSince(baseline.date) >= Self.tempSurgeWindowSeconds * 0.8 else { return }
		let delta = celsius - baseline.celsius
		
		if delta >= Self.tempSurgeDeltaC, celsius >= Self.tempSurgeMinC {
			guard !didNotifyTempSurge, alertEnabled(.alertTempSurge) else { return }
			didNotifyTempSurge = true
			send(
				id: "temp-surge",
				title: "温度上升较快",
				body: String(format: "5 分钟内从 %.1f°C 升到 %.1f°C，留意下是不是在跑重任务或散热不良", baseline.celsius, celsius)
			)
		} else if delta < 1 {
			didNotifyTempSurge = false
		}
	}
	
	// 健康度里程碑：跌破 90/85/80 各提醒一次，基准持久化防重启后重发
	private func evaluateHealthMilestone(_ snapshot: BatterySnapshot) {
		guard let health = snapshot.healthPercent else { return }
		
		let stored = defaults.integer(forKey: Self.healthMilestoneKey)
		guard stored > 0 else {
			// 首次运行只记基准不提醒：装上时已经 87% 的电池没必要补刀
			defaults.set(health, forKey: Self.healthMilestoneKey)
			return
		}
		guard health < stored else {
			// 健康度读数回升（校准波动）时抬高基准，保持“只在真跌破时提醒”
			if health > stored { defaults.set(health, forKey: Self.healthMilestoneKey) }
			return
		}
		defaults.set(health, forKey: Self.healthMilestoneKey)
		
		guard alertEnabled(.alertHealthMilestone) else { return }
		guard let crossed = Self.healthMilestones.first(where: { stored > $0 && health <= $0 }) else { return }
		let suffix = crossed == 80 ? "，已到官方建议检测电池的参考线" : "，属正常老化，留意即可"
		send(
			id: "health-milestone-\(crossed)",
			title: "电池健康度跌破 \(crossed)%",
			body: "当前健康度 \(health)%" + suffix
		)
	}
	
	private func evaluateSlowCharge(_ snapshot: BatterySnapshot) {
		guard snapshot.powerSource == .powerAdapter else {
			didNotifySlowCharge = false
			return
		}
		guard alertEnabled(.alertSlowCharge) else { return }
		guard
			snapshot.isCharging, !snapshot.isFull,
			let rated = snapshot.adapterRatedWatts, rated >= Self.slowChargeMinRatedWatts,
			let voltageMV = snapshot.negotiatedVoltageMV,
			let currentMA = snapshot.negotiatedCurrentMA,
			voltageMV > 0, currentMA > 0
		else { return }
		
		let negotiatedWatts = Double(voltageMV) * Double(currentMA) / 1_000_000.0
		guard negotiatedWatts < Double(rated) * Self.slowChargeRatio else { return }
		guard !didNotifySlowCharge else { return }
		
		didNotifySlowCharge = true
		send(
			id: "slow-charge",
			title: "检测到慢充",
			body: String(format: "协商档位仅 %.0fW（充电器额定 %dW），请检查数据线或接口", negotiatedWatts, rated)
		)
	}
	
	// 睡眠掉电异常：合盖一觉掉得太多，多半是有应用在阻止休眠或“断电时唤醒”在捣鬼
	private func evaluateSleepDrain(_ record: SleepDrainRecord) {
		guard isEnabled, configuration.enabledOptions.contains(.sleepDrainReport) else { return }
		let lastAlerted = defaults.object(forKey: Self.sleepDrainAlertedKey) as? Date
		guard Self.shouldAlertSleepDrain(record: record, now: Date(), lastAlertedWakeDate: lastAlerted) else { return }
		// 先记账再发：哪怕通知投递失败，也不靠重复轰炸来“补偿”
		defaults.set(record.wakeDate, forKey: Self.sleepDrainAlertedKey)
		
		send(
			id: "sleep-drain",
			title: "睡眠掉电偏多",
			body: String(format: "合盖 %@ 掉了 %d%%（%.1f%%/小时），可能有应用在阻止睡眠", DurationFormatter.chinese(minutes: record.durationMinutes), record.droppedPercent, record.dropPerHour)
		)
	}
	
	// 纯判定，供单测直接调：
	// 同一觉已报过不重发（重启后订阅会立刻回放磁盘里的旧记录）；
	// 醒来超过新鲜窗口不报；时长/掉电/折算任一不达标不报
	nonisolated static func shouldAlertSleepDrain(record: SleepDrainRecord, now: Date, lastAlertedWakeDate: Date?) -> Bool {
		if let lastAlertedWakeDate, lastAlertedWakeDate == record.wakeDate { return false }
		guard now.timeIntervalSince(record.wakeDate) < sleepDrainAlertFreshnessSeconds else { return false }
		return record.durationMinutes >= sleepDrainAlertMinMinutes
			&& record.droppedPercent >= sleepDrainAlertMinPercent
			&& record.dropPerHour >= sleepDrainAlertMinPerHour
	}
	
	// 电量计校准提醒：30 天内跳变攒够阈值提醒做一次完整充放循环；
	// 条件可能长期成立（老化的电量计跳变是常态），用时间冷却而不是边沿重置防轰炸
	private func evaluateGaugeCalibration(_ events: [SocJumpEvent]) {
		guard isEnabled, alertEnabled(.alertGaugeCalibration) else { return }
		let now = Date()
		let count = UsagePatternAnalyzer.socJumpCount(events, withinDays: 30, now: now)
		guard UsagePatternAnalyzer.gaugeNeedsCalibration(jumpCount: count) else { return }
		// 先记账再发：投递失败也不靠重复轰炸补偿
		if let lastAlerted = defaults.object(forKey: Self.gaugeCalibrationAlertKey) as? Date,
			now.timeIntervalSince(lastAlerted) < Self.gaugeCalibrationCooldownSeconds {
			return
		}
		defaults.set(now, forKey: Self.gaugeCalibrationAlertKey)
		send(
			id: "gauge-calibration",
			title: "电量计可能失准",
			body: "最近 30 天记录到 \(count) 次电量跳变（电量突然变化 2% 以上）。建议做一次完整的充放循环，帮电量计重新校准"
		)
	}

	// 每周电池周报：周日 20 点后第一次有机会时发；错过就顺延到下次启动
	private func checkWeeklyDigest() {
		guard isEnabled, configuration.enabledOptions.contains(.weeklyDigest) else { return }
		guard let due = Self.mostRecentDigestDue(before: Date()) else { return }
		// 首次运行只记个时间标记不发：刚装上就报“本周”没意义
		guard let lastSent = defaults.object(forKey: Self.weeklyDigestDateKey) as? Date else {
			defaults.set(Date(), forKey: Self.weeklyDigestDateKey)
			return
		}
		guard lastSent < due, let recorder = historyRecorder else { return }
		defaults.set(Date(), forKey: Self.weeklyDigestDateKey)
		
		let weekStart = due.addingTimeInterval(-7 * 86400)
		let sessionCount = recorder.recentSessions.filter { $0.startDate >= weekStart }.count
		let body = Self.weeklyDigestBody(
			history: recorder.dailyHistory,
			sessionCount: sessionCount,
			healthPercent: lastSnapshot.healthPercent
		)
		guard !body.isEmpty else { return }
		send(id: "weekly-digest", title: "本周电池小结", body: body)
	}
	
	// 最近一个已到点的“周日 20:00”；周日 20 点前返回上周的
	// 纯函数，标 nonisolated 方便单元测试直接调
	nonisolated static func mostRecentDigestDue(before now: Date) -> Date? {
		let calendar = Calendar.current
		let todayStart = calendar.startOfDay(for: now)
		let weekday = calendar.component(.weekday, from: now) // 1 = 周日
		guard
			let sunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: todayStart),
			let due = calendar.date(byAdding: .hour, value: 20, to: sunday)
		else { return nil }
		if now >= due { return due }
		return calendar.date(byAdding: .day, value: -7, to: due)
	}
	
	// 周报正文；这周没产生任何用电数据就返回空串（不发也罢）
	nonisolated static func weeklyDigestBody(history: [DailyUsage], sessionCount: Int, healthPercent: Int?) -> String {
		let drained = history.reduce(0) { $0 + $1.drainedPercent }
		let charged = history.reduce(0) { $0 + $1.chargedPercent }
		guard drained > 0 || charged > 0 || sessionCount > 0 else { return "" }
		
		var parts = ["本周用电 \(drained)%、充入 \(charged)%、充电 \(sessionCount) 次"]
		if let health = healthPercent {
			parts.append("健康度 \(health)%")
		}
		return parts.joined(separator: "；")
	}

	// MARK: - 每月电池月报

	// 每月 1 号 9 点后第一次有机会时发上月小结；错过顺延到下次启动
	// 与周报共用 weeklyDigest 开关（同为"定期小结"）
	private func checkMonthlyDigest() {
		guard isEnabled, configuration.enabledOptions.contains(.weeklyDigest) else { return }
		guard let due = Self.mostRecentMonthlyDigestDue(before: Date()) else { return }
		guard let lastSent = defaults.object(forKey: Self.monthlyDigestDateKey) as? Date else {
			defaults.set(Date(), forKey: Self.monthlyDigestDateKey)
			return
		}
		guard lastSent < due, let recorder = historyRecorder else { return }
		defaults.set(Date(), forKey: Self.monthlyDigestDateKey)

		let body = Self.monthlyDigestBody(
			history: recorder.dailyHistory,
			sessions: recorder.recentSessions,
			healthSamples: recorder.healthSamples,
			due: due
		)
		guard !body.isEmpty else { return }
		send(id: "monthly-digest", title: "上月电池小结", body: body)
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

		let monthDays = history.filter { $0.dayKey.hasPrefix(prefix) }
		let drained = monthDays.reduce(0) { $0 + $1.drainedPercent }
		let charged = monthDays.reduce(0) { $0 + $1.chargedPercent }
		let sessionCount = sessions.filter { UsagePatternAnalyzer.monthKeyString($0.startDate, calendar: calendar).hasPrefix(prefix) }.count
		guard drained > 0 || charged > 0 || sessionCount > 0 else { return "" }

		let dayCount = calendar.range(of: .day, in: .month, for: prevMonthStart)?.count ?? 30
		var parts = [String(format: "上月用电 %d%%、充入 %d%%、充电 %d 次", drained, charged, sessionCount)]
		parts.append(String(format: "日均用电 %.0f%%", Double(drained) / Double(dayCount)))
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
		let hour = Calendar.current.component(.hour, from: Date())
		return Self.isQuietHour(hour, start: configuration.quietHoursStartHour, end: configuration.quietHoursEndHour)
	}

	private func send(id: String, title: String, body: String, urgent: Bool = false) {
		if isInQuietHours, !urgent { return }

		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		// 紧急提醒（低电量等）标为时效性通知，专注模式下才真正能穿透；
		// 需要用户在系统设置里授予“时效性通知”权限，未授予时按普通通知处理
		content.interruptionLevel = urgent ? .timeSensitive : .active

		let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
		UNUserNotificationCenter.current().add(request) { error in
			if let error {
				DiagnosticLog.failureOnce("notification-send-failed", category: "BatteryAlertController", "发送通知失败：\(error.localizedDescription)")
			}
		}
	}
}
