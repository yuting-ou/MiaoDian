import AppKit
import Combine
import Foundation

// 充电记录 + 健康度趋势的采集与持久化
// 与配置一致，数据量小，直接存 UserDefaults
@MainActor
final class BatteryHistoryRecorder: ObservableObject {
	@Published private(set) var recentSessions: [ChargeSession] = []
	@Published private(set) var healthSamples: [HealthSample] = []
	// 最近几天的用电累计，末尾是今天，最多保留 90 天（供七天柱图与日历热力图）
	@Published private(set) var dailyHistory: [DailyUsage] = []
	// 上一觉合盖的掉电记录
	@Published private(set) var lastSleepDrain: SleepDrainRecord?
	// 见过的充电器档案
	@Published private(set) var chargerProfiles: [ChargerProfile] = []
	// 24 小时电量曲线采样
	@Published private(set) var socSamples: [SOCSample] = []
	// 电源事件时间线（插拔电/充满/睡眠唤醒），新的在末尾
	@Published private(set) var powerEvents: [PowerEvent] = []
	
	// 今天的用电累计；历史末尾不是今天说明今天还没产生数据
	var todayUsage: DailyUsage? {
		guard let last = dailyHistory.last, last.dayKey == Self.dayKey(Date()) else { return nil }
		return last
	}
	
	private var activeSession: ChargeSession?
	// 从磁盘恢复的会话需要先检查时间断档，再决定续接还是归档
	private var restoredSessionNeedsGapCheck = false
	private var lastActiveSessionSave = Date.distantPast
	// 今日用电累计用：上一次看到的电量与采样时刻（时长占比靠它算增量）
	private var lastPercentForDaily: Int?
	private var lastUsageSampleDate: Date?
	private var lastDailyUsageSave = Date.distantPast
	// 事件边沿检测用：上一帧的电源状态
	private var lastPowerSource: PowerSourceType?
	private var lastIsFull = false
	// 睡眠掉电：合盖时的时间和电量；醒来后等第一个新快照再结算
	private var sleepStart: (date: Date, percent: Int)?
	private var pendingWake: (sleepDate: Date, startPercent: Int, wakeDate: Date)?
	// 充电器档案：本次接入已建档的身份键与接入时刻
	private var activeChargerKey: String?
	private var adapterConnectedAt: Date?
	private var cancellables: Set<AnyCancellable> = []
	
	private let defaults: UserDefaults
	private let decoder = PropertyListDecoder()
	private let encoder = PropertyListEncoder()
	
	private static let sessionsKey = "chargeSessions"
	private static let healthKey = "healthSamples"
	private static let activeSessionKey = "activeChargeSession"
	private static let dailyUsageKey = "dailyUsage"
	private static let dailyHistoryKey = "dailyUsageHistory"
	private static let sleepDrainKey = "lastSleepDrain"
	private static let chargerProfilesKey = "chargerProfiles"
	private static let socSamplesKey = "socSamples"
	private static let powerEventsKey = "powerEvents"
	private static let maxSessions = 20
	private static let maxHealthSamples = 400
	// 用电历史保留 90 天：七天柱图只看末尾 7 天，日历热力图需要更长跨度
	private static let maxDailyHistory = 90
	private static let maxChargerProfiles = 20
	private static let maxPowerEvents = 50
	// 同类电源事件间隔小于这个值视为连发，合并只留最新一条
	private static let eventMergeSeconds: TimeInterval = 2 * 60
	// SOC 采样：窗口 24 小时；平时 10 分钟一点，电量变化/充电状态翻转时加密采点
	private static let socWindowSeconds: TimeInterval = 24 * 3600
	private static let socRegularInterval: TimeInterval = 10 * 60
	private static let socChangeMinInterval: TimeInterval = 3 * 60
	// 相邻两帧间隔超过这个值视为睡过，不计入插电/电池时长
	private static let usageDeltaCapSeconds: TimeInterval = 30
	// 合盖不足 20 分钟算小憩，不计入睡眠掉电记录
	private static let minSleepSeconds: TimeInterval = 20 * 60
	// 半小时内重复见到同一充电器（如应用重启）不重复计次
	private static let chargerRecountSeconds: TimeInterval = 30 * 60
	// 适配器名称/厂商信息可能晚几秒才到位，最多等这么久再退而求其次按额定功率建档
	private static let chargerIdentityWaitSeconds: TimeInterval = 10
	// 恢复的会话离上次落盘超过这个时长，视为中间拔过电源，不再续接
	private static let resumeGapSeconds: TimeInterval = 30 * 60
	// 曲线点数上限：正常充一次最多百来个点，超出说明电量在临界值反复横跳，不再记
	private static let maxCurvePoints = 200
	
	init(monitor: BatteryMonitor, defaults: UserDefaults = .standard) {
		self.defaults = defaults
		recentSessions = load([ChargeSession].self, key: Self.sessionsKey) ?? []
		healthSamples = load([HealthSample].self, key: Self.healthKey) ?? []
		// 上次退出时若正在充电，把进行中的会话捡回来，中途退出不丢记录
		activeSession = load(ChargeSession.self, key: Self.activeSessionKey)
		restoredSessionNeedsGapCheck = activeSession != nil
		// 用电历史也捡回来；早期版本只存单天，迁移进历史数组后删旧键
		if let history = load([DailyUsage].self, key: Self.dailyHistoryKey) {
			dailyHistory = history
		} else if let old = load(DailyUsage.self, key: Self.dailyUsageKey) {
			dailyHistory = [old]
			save(dailyHistory, key: Self.dailyHistoryKey)
			defaults.removeObject(forKey: Self.dailyUsageKey)
		}
		
		lastSleepDrain = load(SleepDrainRecord.self, key: Self.sleepDrainKey)
		chargerProfiles = load([ChargerProfile].self, key: Self.chargerProfilesKey) ?? []
		socSamples = load([SOCSample].self, key: Self.socSamplesKey) ?? []
		powerEvents = load([PowerEvent].self, key: Self.powerEventsKey) ?? []
		// 监听系统睡眠/唤醒，统计合盖期间掉了多少电
		let workspaceCenter = NSWorkspace.shared.notificationCenter
		workspaceCenter.addObserver(self, selector: #selector(handleWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
		workspaceCenter.addObserver(self, selector: #selector(handleDidWake), name: NSWorkspace.didWakeNotification, object: nil)
		
		// 订阅一建立就会立刻收到当前快照，所以必须放在各项数据加载之后
		monitor.$snapshot
			.sink { [weak self] snapshot in
				self?.process(snapshot)
			}
			.store(in: &cancellables)
	}
	
	// 健康趋势：最早一笔和最新一笔的对比（跨度至少 1 天才有意义）
	var healthTrend: (earliest: HealthSample, latest: HealthSample)? {
		guard
			let earliest = healthSamples.first,
			let latest = healthSamples.last,
			latest.date.timeIntervalSince(earliest.date) >= 24 * 3600
		else { return nil }
		return (earliest, latest)
	}
	
	private func process(_ snapshot: BatterySnapshot) {
		finalizeSleepDrainIfNeeded(snapshot)
		updateChargeSession(snapshot)
		updateChargerProfile(snapshot)
		recordDailyHealth(snapshot)
		updateDailyUsage(snapshot)
		recordSOCSample(snapshot)
		recordPowerEvents(snapshot)
	}
	
	// MARK: - 充电记录
	
	private func updateChargeSession(_ snapshot: BatterySnapshot) {
		let isChargingNow = snapshot.powerSource == .powerAdapter && snapshot.isCharging
		
		if isChargingNow {
			let percent = snapshot.stateOfChargePercent ?? 0
			let inputW = snapshot.adapterInputPowerW ?? snapshot.chargingPowerW ?? 0
			
			// 从磁盘恢复的会话：离上次落盘太久说明中间可能拔过电，
			// 先把旧会话归档，再为这次充电开新会话，避免两段充电被粘成一条
			if restoredSessionNeedsGapCheck {
				restoredSessionNeedsGapCheck = false
				if let restored = activeSession, Date().timeIntervalSince(restored.endDate) > Self.resumeGapSeconds {
					activeSession = nil
					finalizeSession(restored)
				}
			}
			
			if var session = activeSession {
				let percentChanged = session.endPercent != percent
				session.endDate = Date()
				session.endPercent = percent
				session.peakInputW = max(session.peakInputW, inputW)
				// 电量变化时记一个曲线点，事后能看出这次充电是先快后慢还是全程稳定
				if percentChanged, (session.curve?.count ?? 0) < Self.maxCurvePoints {
					var curve = session.curve ?? []
					curve.append(ChargePoint(
						minuteOffset: Int(session.endDate.timeIntervalSince(session.startDate) / 60),
						percent: percent
					))
					session.curve = curve
				}
				activeSession = session
				// 进行中的会话定期落盘，应用中途退出也不丢这段记录
				if percentChanged || Date().timeIntervalSince(lastActiveSessionSave) >= 60 {
					persistActiveSession(session)
				}
			} else {
				let session = ChargeSession(
					startDate: Date(),
					endDate: Date(),
					startPercent: percent,
					endPercent: percent,
					peakInputW: inputW,
					curve: [ChargePoint(minuteOffset: 0, percent: percent)]
				)
				activeSession = session
				persistActiveSession(session)
			}
		} else if let session = activeSession {
			activeSession = nil
			restoredSessionNeedsGapCheck = false
			defaults.removeObject(forKey: Self.activeSessionKey)
			finalizeSession(session)
		}
	}
	
	private func finalizeSession(_ session: ChargeSession) {
		// 过滤插拔瞬间的无效会话
		guard session.durationMinutes >= 2 || session.endPercent > session.startPercent else { return }
		
		recentSessions.append(session)
		if recentSessions.count > Self.maxSessions {
			recentSessions.removeFirst(recentSessions.count - Self.maxSessions)
		}
		save(recentSessions, key: Self.sessionsKey)
	}
	
	private func persistActiveSession(_ session: ChargeSession) {
		lastActiveSessionSave = Date()
		save(session, key: Self.activeSessionKey)
	}
	
	// MARK: - 24 小时电量曲线
	
	private func recordSOCSample(_ snapshot: BatterySnapshot) {
		guard let percent = snapshot.stateOfChargePercent else { return }
		let now = Date()
		
		if let last = socSamples.last {
			let elapsed = now.timeIntervalSince(last.date)
			let chargingFlipped = last.isCharging != snapshot.isCharging
			let percentMoved = last.percent != percent && elapsed >= Self.socChangeMinInterval
			guard chargingFlipped || percentMoved || elapsed >= Self.socRegularInterval else { return }
		}
		
		var samples = socSamples
		samples.append(SOCSample(date: now, percent: percent, isCharging: snapshot.isCharging))
		samples.removeAll { now.timeIntervalSince($0.date) > Self.socWindowSeconds }
		socSamples = samples
		save(samples, key: Self.socSamplesKey)
	}
	
	// MARK: - 电源事件时间线
	
	private func recordPowerEvents(_ snapshot: BatterySnapshot) {
		defer {
			lastPowerSource = snapshot.powerSource
			lastIsFull = snapshot.isFull
		}
		// 启动后第一帧只记基准不记事件，免得每次启动都多一条假“插电”
		guard let previous = lastPowerSource else { return }
		
		if previous != snapshot.powerSource {
			appendPowerEvent(snapshot.powerSource == .powerAdapter ? .pluggedIn : .unplugged)
		}
		if !lastIsFull, snapshot.isFull {
			appendPowerEvent(.chargedFull)
		}
	}
	
	private func appendPowerEvent(_ kind: PowerEventKind) {
		var events = powerEvents
		// 同类事件短时间内连发（插头接触不良反复断连、反复重启应用）只留最新一条，不刷屏
		if let last = events.last, last.kind == kind,
		   Date().timeIntervalSince(last.date) < Self.eventMergeSeconds {
			events[events.count - 1] = PowerEvent(date: Date(), kind: kind)
		} else {
			events.append(PowerEvent(date: Date(), kind: kind))
		}
		if events.count > Self.maxPowerEvents {
			events.removeFirst(events.count - Self.maxPowerEvents)
		}
		powerEvents = events
		save(events, key: Self.powerEventsKey)
	}
	
	// MARK: - 睡眠掉电
	
	@objc private func handleWillSleep() {
		appendPowerEvent(.sleep)
		guard let percent = lastPercentForDaily else { return }
		sleepStart = (Date(), percent)
		pendingWake = nil
	}
	
	@objc private func handleDidWake() {
		appendPowerEvent(.wake)
		guard let start = sleepStart else { return }
		sleepStart = nil
		// 醒来瞬间的快照可能还是睡前的旧值，挂起等下一次刷新再结算
		pendingWake = (start.date, start.percent, Date())
	}
	
	private func finalizeSleepDrainIfNeeded(_ snapshot: BatterySnapshot) {
		guard let pending = pendingWake, let percent = snapshot.stateOfChargePercent else { return }
		pendingWake = nil
		guard pending.wakeDate.timeIntervalSince(pending.sleepDate) >= Self.minSleepSeconds else { return }
		
		let record = SleepDrainRecord(
			sleepDate: pending.sleepDate,
			wakeDate: pending.wakeDate,
			startPercent: pending.startPercent,
			endPercent: percent
		)
		lastSleepDrain = record
		save(record, key: Self.sleepDrainKey)
	}
	
	// MARK: - 充电器档案
	
	// 当前接着的充电器对应的档案（拔电后为 nil）
	var currentChargerProfile: ChargerProfile? {
		guard let key = activeChargerKey else { return nil }
		return chargerProfiles.first { $0.key == key }
	}
	
	private func updateChargerProfile(_ snapshot: BatterySnapshot) {
		guard snapshot.powerSource == .powerAdapter else {
			activeChargerKey = nil
			adapterConnectedAt = nil
			return
		}
		if adapterConnectedAt == nil { adapterConnectedAt = Date() }
		// 本次接入已建档就不再动，避免适配器信息陆续到位时被重复计次
		guard activeChargerKey == nil else { return }
		
		let name = snapshot.adapterName ?? ""
		let manufacturer = snapshot.adapterManufacturer ?? ""
		let rated = snapshot.adapterRatedWatts ?? 0
		// 名称/厂商任一到位就建档；都没有则等几秒，超时后按额定功率建档
		if name.isEmpty, manufacturer.isEmpty {
			guard rated > 0,
				let connectedAt = adapterConnectedAt,
				Date().timeIntervalSince(connectedAt) >= Self.chargerIdentityWaitSeconds
			else { return }
		}
		let key = "\(name)|\(manufacturer)|\(rated)"
		activeChargerKey = key
		
		var profiles = chargerProfiles
		if let index = profiles.firstIndex(where: { $0.key == key }) {
			if Date().timeIntervalSince(profiles[index].lastSeen) > Self.chargerRecountSeconds {
				profiles[index].connectCount += 1
			}
			profiles[index].lastSeen = Date()
		} else {
			let fallbackName = manufacturer.isEmpty ? "\(rated)W 充电器" : manufacturer
			profiles.append(ChargerProfile(
				key: key,
				name: name.isEmpty ? fallbackName : name,
				ratedWatts: rated > 0 ? rated : nil,
				firstSeen: Date(),
				lastSeen: Date(),
				connectCount: 1
			))
			// 档案满了挤掉最久没见过的
			if profiles.count > Self.maxChargerProfiles {
				profiles.sort { $0.lastSeen < $1.lastSeen }
				profiles.removeFirst(profiles.count - Self.maxChargerProfiles)
			}
		}
		chargerProfiles = profiles
		save(profiles, key: Self.chargerProfilesKey)
	}
	
	// MARK: - 今日用电小结
	
	// 相邻两次采样的电量差累计：电池模式下掉的计入用电，充电时涨的计入充入；
	// 同时按电源类型累计插电/电池时长（算插电占比）
	// 跨天时追加新的一天，只保留最近 7 天
	private func updateDailyUsage(_ snapshot: BatterySnapshot) {
		guard let percent = snapshot.stateOfChargePercent else { return }
		let now = Date()
		defer {
			lastPercentForDaily = percent
			lastUsageSampleDate = now
		}
		
		let key = Self.dayKey(now)
		var history = dailyHistory
		var structuralChange = false
		if history.last?.dayKey != key {
			history.append(DailyUsage(dayKey: key))
			if history.count > Self.maxDailyHistory {
				history.removeFirst(history.count - Self.maxDailyHistory)
			}
			structuralChange = true
		}
		var usage = history[history.count - 1]
		
		if let last = lastPercentForDaily {
			if percent < last, snapshot.powerSource == .battery {
				usage.drainedPercent += last - percent
				structuralChange = true
			} else if percent > last, snapshot.isCharging {
				usage.chargedPercent += percent - last
				structuralChange = true
			}
		}
		// 时长增量：距上一帧太久说明睡过，那段时间不计
		if let lastDate = lastUsageSampleDate {
			let delta = now.timeIntervalSince(lastDate)
			if delta > 0, delta <= Self.usageDeltaCapSeconds {
				if snapshot.powerSource == .powerAdapter {
					usage.acSeconds += delta
				} else {
					usage.batterySeconds += delta
				}
			}
		}
		history[history.count - 1] = usage
		
		guard history != dailyHistory else { return }
		dailyHistory = history
		// 时长秒数每帧都在涨，落盘限频：电量变化/跨天立存，纯时长增量最多一分钟存一次
		if structuralChange || now.timeIntervalSince(lastDailyUsageSave) >= 60 {
			lastDailyUsageSave = now
			save(history, key: Self.dailyHistoryKey)
		}
	}
	
	private static func dayKey(_ date: Date) -> String {
		dayKeyFormatter.string(from: date)
	}
	
	private static let dayKeyFormatter: DateFormatter = {
		let formatter = DateFormatter()
		// dayKey 是落盘的机器主键，必须用固定 POSIX 公历：
		// 否则用户把系统日历改成非公历（如佛历）时 yyyy 会输出 2570 这种年份，键会错乱
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter
	}()
	
	// MARK: - 健康度趋势
	
	private func recordDailyHealth(_ snapshot: BatterySnapshot) {
		guard let health = snapshot.healthPercent else { return }
		
		let today = Date()
		if let last = healthSamples.last, Calendar.current.isDate(last.date, inSameDayAs: today) {
			return
		}
		
		healthSamples.append(HealthSample(date: today, healthPercent: health, cycleCount: snapshot.cycleCount))
		if healthSamples.count > Self.maxHealthSamples {
			healthSamples.removeFirst(healthSamples.count - Self.maxHealthSamples)
		}
		save(healthSamples, key: Self.healthKey)
	}
	
	// MARK: - 持久化
	
	private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
		guard let data = defaults.data(forKey: key) else { return nil }
		return try? decoder.decode(type, from: data)
	}
	
	private func save<T: Encodable>(_ value: T, key: String) {
		guard let data = try? encoder.encode(value) else { return }
		defaults.set(data, forKey: key)
	}
}
