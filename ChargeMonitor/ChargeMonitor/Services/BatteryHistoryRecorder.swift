import AppKit
import Combine
import Foundation

// 充电记录 + 健康度趋势的采集与持久化
// 与配置一致，数据量小，直接存 UserDefaults
// 所有时间相关的判定都抽成 nonisolated 纯函数（now 可注入），状态机直测真代码
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
	// 充电器质量诊断：按充电器累计的协商功率样本
	@Published private(set) var chargerPowerStats: [String: ChargerPowerStats] = [:]
	// 时段用电：按小时分桶累计的掉电（热力图数据源）
	@Published private(set) var hourlyDrainStats = HourlyDrainStats()
	// 应用耗电累计：按天记录各应用"高耗电"状态的秒数
	@Published private(set) var appEnergy: [AppEnergyUsage] = []
	// 电量跳变事件：电池模式下相邻采样电量突变（电量计失准的表现）
	@Published private(set) var socJumpEvents: [SocJumpEvent] = []
	
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
	private var lastChargerStatsSave = Date.distantPast
	// 事件边沿检测用：上一帧的电源状态
	private var lastPowerSource: PowerSourceType?
	private var lastIsFull = false
	// 睡眠掉电：合盖时的时间和电量；醒来后等第一个新快照再结算
	private var sleepStart: (date: Date, percent: Int)?
	private var pendingWake: (sleepDate: Date, startPercent: Int, wakeDate: Date)?
	// 充电器档案：本次接入已建档的身份键与接入时刻
	private var activeChargerKey: String?
	private var adapterConnectedAt: Date?
	// 应用耗电累计：上一次计时的时刻（帧间隔超上限视为断档不计）
	private var lastEnergyTick: Date?
	private var lastAppEnergySave = Date.distantPast
	// 跳变检测用：电池模式下上一次采样的电量与时刻（充电/插电即重置）
	private var lastSocSample: (date: Date, percent: Int)?
	// monitor 引用：应用耗电累计要读它的"面板是否打开"与当前高耗电列表
	private let monitor: BatteryMonitor
	private var cancellables: Set<AnyCancellable> = []
	
	private let defaults: UserDefaults
	private let decoder = PropertyListDecoder()
	private let encoder = PropertyListEncoder()
	// 滚动备份：写入时顺手把各历史键的最新编码攒在内存，定期滚到独立文件；
	// 主档损坏时从中抢救（详见下方“持久化”）
	private let backupDirectory: URL?
	private var backupRaw: [String: Data] = [:]
	private var lastBackupSave = Date.distantPast
	
	nonisolated private static let sessionsKey = "chargeSessions"
	nonisolated private static let healthKey = "healthSamples"
	nonisolated private static let activeSessionKey = "activeChargeSession"
	nonisolated private static let dailyUsageKey = "dailyUsage"
	nonisolated private static let dailyHistoryKey = "dailyUsageHistory"
	nonisolated private static let sleepDrainKey = "lastSleepDrain"
	nonisolated private static let chargerProfilesKey = "chargerProfiles"
	nonisolated private static let socSamplesKey = "socSamples"
	nonisolated private static let powerEventsKey = "powerEvents"
	nonisolated private static let chargerPowerStatsKey = "chargerPowerStats"
	nonisolated private static let hourlyDrainKey = "hourlyDrainStats"
	nonisolated private static let appEnergyKey = "appEnergy"
	nonisolated private static let socJumpEventsKey = "socJumpEvents"
	nonisolated private static let maxSessions = 20
	nonisolated private static let maxHealthSamples = 400
	// 用电历史保留 90 天：七天柱图只看末尾 7 天，日历热力图需要更长跨度
	nonisolated private static let maxDailyHistory = 90
	nonisolated private static let maxChargerProfiles = 20
	nonisolated private static let maxPowerEvents = 50
	// 同类电源事件间隔小于这个值视为连发，合并只留最新一条
	nonisolated private static let eventMergeSeconds: TimeInterval = 2 * 60
	// SOC 采样：窗口 24 小时；平时 10 分钟一点，电量变化/充电状态翻转时加密采点
	nonisolated private static let socWindowSeconds: TimeInterval = 24 * 3600
	nonisolated private static let socRegularInterval: TimeInterval = 10 * 60
	nonisolated private static let socChangeMinInterval: TimeInterval = 3 * 60
	// 相邻两帧间隔超过这个值视为睡过，不计入插电/电池时长
	nonisolated private static let usageDeltaCapSeconds: TimeInterval = 30
	// 合盖不足 20 分钟算小憩，不计入睡眠掉电记录
	nonisolated private static let minSleepSeconds: TimeInterval = 20 * 60
	// 半小时内重复见到同一充电器（如应用重启）不重复计次
	nonisolated private static let chargerRecountSeconds: TimeInterval = 30 * 60
	// 适配器名称/厂商信息可能晚几秒才到位，最多等这么久再退而求其次按额定功率建档
	nonisolated private static let chargerIdentityWaitSeconds: TimeInterval = 10
	// 恢复的会话离上次落盘超过这个时长，视为中间拔过电源，不再续接
	nonisolated private static let resumeGapSeconds: TimeInterval = 30 * 60
	// 曲线点数上限：正常充一次最多百来个点，超出说明电量在临界值反复横跳，不再记
	nonisolated private static let maxCurvePoints = 200
	// 滚动备份的文件名与落盘间隔；测试直接引用文件名，保持单一数据源
	nonisolated static let backupFileName = "history-backup.plist"
	nonisolated private static let backupIntervalSeconds: TimeInterval = 30 * 60
	// 跳变事件保留上限（窗口统计只看 30 天，60 条足够）
	nonisolated private static let maxSocJumpEvents = 60
	// 相邻采样间隔超过这个值视为睡过：合盖慢放电不算跳变
	nonisolated private static let socJumpMaxGapSeconds: TimeInterval = 3 * 60
	
	convenience init(monitor: BatteryMonitor, defaults: UserDefaults = .standard) {
		self.init(monitor: monitor, defaults: defaults, backupDirectory: Self.defaultBackupDirectory())
	}
	
	// backupDirectory 显式传 nil 表示关闭备份（单测用）
	init(monitor: BatteryMonitor, defaults: UserDefaults, backupDirectory: URL?) {
		self.defaults = defaults
		self.backupDirectory = backupDirectory
		self.monitor = monitor
		// 备份先于主档加载：主档损坏时靠它抢救
		backupRaw = loadBackupRaw()
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
		chargerPowerStats = load([String: ChargerPowerStats].self, key: Self.chargerPowerStatsKey) ?? [:]
		hourlyDrainStats = load(HourlyDrainStats.self, key: Self.hourlyDrainKey) ?? HourlyDrainStats()
		appEnergy = load([AppEnergyUsage].self, key: Self.appEnergyKey) ?? []
		socJumpEvents = load([SocJumpEvent].self, key: Self.socJumpEventsKey) ?? []
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
		accumulateChargerPower(snapshot)
		recordDailyHealth(snapshot)
		updateDailyUsage(snapshot)
		recordSOCSample(snapshot)
		recordPowerEvents(snapshot)
		accumulateAppEnergy()
		trackSocJumps(snapshot)
	}

	// MARK: - 电量计跳变

	// 电池模式下相邻采样（10 秒级）电量本不该突变 ≥2%，出现即记一笔跳变；
	// 插电/充电即重置追踪（充电时的电量快涨是正常 CC/CV 行为）
	private func trackSocJumps(_ snapshot: BatterySnapshot) {
		guard snapshot.powerSource == .battery, !snapshot.isCharging,
			let percent = snapshot.stateOfChargePercent else {
			lastSocSample = nil
			return
		}
		let now = Date()
		defer { lastSocSample = (now, percent) }
		guard let last = lastSocSample,
			now.timeIntervalSince(last.date) <= Self.socJumpMaxGapSeconds,
			UsagePatternAnalyzer.isSocJump(from: last.percent, to: percent) else { return }
		let events = Self.appendingSocJump(
			socJumpEvents,
			from: last.percent,
			to: percent,
			at: now,
			maxEvents: Self.maxSocJumpEvents
		)
		guard events != socJumpEvents else { return }
		socJumpEvents = events
		save(events, key: Self.socJumpEventsKey)
	}

	// 追加一条跳变事件并封顶（纯函数，单测直测）
	nonisolated static func appendingSocJump(
		_ events: [SocJumpEvent],
		from: Int,
		to: Int,
		at date: Date,
		maxEvents: Int
	) -> [SocJumpEvent] {
		var events = events
		events.append(SocJumpEvent(date: date, fromPercent: from, toPercent: to))
		if events.count > maxEvents {
			events.removeFirst(events.count - maxEvents)
		}
		return events
	}
	
	// MARK: - 纯判定（now 可注入，状态机直测）
	
	// 从磁盘恢复的会话只有“中间没拔过电”才配续接：
	// 离上次落盘太久视为中间拔过电，旧会话该归档，避免两段充电被粘成一条
	nonisolated static func shouldResumeRestoredSession(_ session: ChargeSession, now: Date) -> Bool {
		now.timeIntervalSince(session.endDate) <= resumeGapSeconds
	}
	
	// 过滤插拔瞬间的无效会话：时长不足 2 分钟且电量没涨的不值得归档
	nonisolated static func isSessionWorthArchiving(_ session: ChargeSession) -> Bool {
		session.durationMinutes >= 2 || session.endPercent > session.startPercent
	}
	
	// 追加一条电源事件：同类短时间内连发（插头接触不良反复断连、反复重启应用）
	// 合并只留最新一条，不刷屏；总长度封顶，新的挤掉最旧的
	nonisolated static func appendingPowerEvent(_ events: [PowerEvent], kind: PowerEventKind, now: Date) -> [PowerEvent] {
		var events = events
		if let last = events.last, last.kind == kind, now.timeIntervalSince(last.date) < eventMergeSeconds {
			events[events.count - 1] = PowerEvent(date: now, kind: kind)
		} else {
			events.append(PowerEvent(date: now, kind: kind))
		}
		if events.count > maxPowerEvents {
			events.removeFirst(events.count - maxPowerEvents)
		}
		return events
	}
	
	// 充电器身份键：名称|厂商|额定功率，建档与相认都靠它，各处必须同源
	nonisolated static func chargerKey(name: String, manufacturer: String, ratedWatts: Int) -> String {
		"\(name)|\(manufacturer)|\(ratedWatts)"
	}
	
	// 已知身份的充电器更新或建档：
	// 重连窗口内再见不重复计次（如应用重启），超窗算一次新连接；档案满了挤掉最久没见的
	nonisolated static func upsertingChargerProfile(
		_ profiles: [ChargerProfile],
		name: String,
		manufacturer: String,
		ratedWatts: Int,
		now: Date
	) -> [ChargerProfile] {
		let key = chargerKey(name: name, manufacturer: manufacturer, ratedWatts: ratedWatts)
		var profiles = profiles
		if let index = profiles.firstIndex(where: { $0.key == key }) {
			if now.timeIntervalSince(profiles[index].lastSeen) > chargerRecountSeconds {
				profiles[index].connectCount += 1
			}
			profiles[index].lastSeen = now
		} else {
			let fallbackName = manufacturer.isEmpty ? "\(ratedWatts)W 充电器" : manufacturer
			profiles.append(ChargerProfile(
				key: key,
				name: name.isEmpty ? fallbackName : name,
				ratedWatts: ratedWatts > 0 ? ratedWatts : nil,
				firstSeen: now,
				lastSeen: now,
				connectCount: 1
			))
			if profiles.count > maxChargerProfiles {
				profiles.sort { $0.lastSeen < $1.lastSeen }
				profiles.removeFirst(profiles.count - maxChargerProfiles)
			}
		}
		return profiles
	}
	
	// 帧间隔超过归因窗口视为睡过：跨睡眠的电量差是夜里慢慢掉/慢慢充的，
	// 全记到醒来那一帧会把整夜耗电/充电错记成瞬时变化（时段热力图也会错桶），一律不计
	nonisolated private static let usageAttributionGapSeconds: TimeInterval = 3 * 60

	// 一帧快照累计进当日用电：电池模式掉的计入用电，充电时涨的计入充入；
	// 反向变化不计（电池模式下回升多是校准波动，插电时掉电不算用户用电）；
	// 帧间隔超上限视为睡过，那段时间不计入插电/电池时长
	nonisolated static func accumulatingDailyUsage(
		_ usage: DailyUsage,
		percent: Int,
		lastPercent: Int?,
		powerSource: PowerSourceType,
		isCharging: Bool,
		secondsSinceLastSample: TimeInterval?
	) -> DailyUsage {
		var usage = usage
		// 电量差只在连续采样间归因；间隔需为正且未跨睡眠
		let isContiguous = secondsSinceLastSample.map { $0 > 0 && $0 <= usageAttributionGapSeconds } ?? false
		if isContiguous, let last = lastPercent {
			if percent < last, powerSource == .battery {
				usage.drainedPercent += last - percent
			} else if percent > last, isCharging {
				usage.chargedPercent += percent - last
			}
		}
		if let delta = secondsSinceLastSample, delta > 0, delta <= usageDeltaCapSeconds {
			if powerSource == .powerAdapter {
				usage.acSeconds += delta
			} else {
				usage.batterySeconds += delta
			}
			// 高电量驻留：电化学应力看的是"停在多高的电量"，与插不插电无关
			if percent >= 90 {
				usage.soc90to100Seconds += delta
			} else if percent >= 80 {
				usage.soc80to90Seconds += delta
			}
		}
		return usage
	}
	
	// 这一帧是否记入 24 小时电量曲线：平时按固定间隔记，
	// 电量变化（距上点有最小间隔）或充电状态翻转时加密采点
	nonisolated static func shouldRecordSOCSample(last: SOCSample?, percent: Int, isCharging: Bool, now: Date) -> Bool {
		guard let last else { return true }
		let elapsed = now.timeIntervalSince(last.date)
		let chargingFlipped = last.isCharging != isCharging
		let percentMoved = last.percent != percent && elapsed >= socChangeMinInterval
		return chargingFlipped || percentMoved || elapsed >= socRegularInterval
	}
	
	// 醒来结算睡眠掉电；不足 20 分钟的小憩不记录
	nonisolated static func settledSleepDrain(sleepDate: Date, startPercent: Int, wakeDate: Date, endPercent: Int) -> SleepDrainRecord? {
		guard wakeDate.timeIntervalSince(sleepDate) >= minSleepSeconds else { return nil }
		return SleepDrainRecord(sleepDate: sleepDate, wakeDate: wakeDate, startPercent: startPercent, endPercent: endPercent)
	}
	
	// MARK: - 充电记录
	
	private func updateChargeSession(_ snapshot: BatterySnapshot) {
		let isChargingNow = snapshot.powerSource == .powerAdapter && snapshot.isCharging
		
		if isChargingNow {
			let percent = snapshot.stateOfChargePercent ?? 0
			let inputW = snapshot.adapterInputPowerW ?? snapshot.chargingPowerW ?? 0
			
			// 从磁盘恢复的会话先过断档判定，再决定续接还是归档
			if restoredSessionNeedsGapCheck {
				restoredSessionNeedsGapCheck = false
				if let restored = activeSession, !Self.shouldResumeRestoredSession(restored, now: Date()) {
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
		guard Self.isSessionWorthArchiving(session) else { return }
		
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
		guard Self.shouldRecordSOCSample(last: socSamples.last, percent: percent, isCharging: snapshot.isCharging, now: now) else { return }
		
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
		powerEvents = Self.appendingPowerEvent(powerEvents, kind: kind, now: Date())
		save(powerEvents, key: Self.powerEventsKey)
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
		guard let record = Self.settledSleepDrain(
			sleepDate: pending.sleepDate,
			startPercent: pending.startPercent,
			wakeDate: pending.wakeDate,
			endPercent: percent
		) else { return }
		lastSleepDrain = record
		save(record, key: Self.sleepDrainKey)
	}
	
	// 功率统计只保留仍建档的充电器（纯函数，单测直测）
	nonisolated static func pruningChargerPowerStats(
		_ stats: [String: ChargerPowerStats],
		keeping profiles: [ChargerProfile]
	) -> [String: ChargerPowerStats] {
		let keys = Set(profiles.map(\.key))
		guard stats.count > keys.count else { return stats }
		return stats.filter { keys.contains($0.key) }
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
		activeChargerKey = Self.chargerKey(name: name, manufacturer: manufacturer, ratedWatts: rated)
		chargerProfiles = Self.upsertingChargerProfile(chargerProfiles, name: name, manufacturer: manufacturer, ratedWatts: rated, now: Date())
		save(chargerProfiles, key: Self.chargerProfilesKey)
		// 功率统计跟着档案走：档案挤掉最旧后，对应统计一并清理，不留孤儿数据
		let prunedStats = Self.pruningChargerPowerStats(chargerPowerStats, keeping: chargerProfiles)
		if prunedStats.count != chargerPowerStats.count {
			chargerPowerStats = prunedStats
			save(chargerPowerStats, key: Self.chargerPowerStatsKey)
		}
	}

	// 当前充电器累计的协商功率样本（供诊断；拔电后为 nil）
	var currentChargerPowerStats: ChargerPowerStats? {
		guard let key = activeChargerKey else { return nil }
		return chargerPowerStats[key]
	}

	// 充电期间累计协商功率：每帧把当前协商瓦数滚进对应充电器的统计，
	// 事后算平均，识别"额定 65W 却一直只协商 20W"这类劣质线/口
	// 落盘限频：纯累计变化最多一分钟存一次，避免每 2 秒写一次
	private func accumulateChargerPower(_ snapshot: BatterySnapshot) {
		guard let key = activeChargerKey else { return }
		guard snapshot.powerSource == .powerAdapter, snapshot.isCharging else { return }
		guard
			let voltageMV = snapshot.negotiatedVoltageMV,
			let currentMA = snapshot.negotiatedCurrentMA,
			voltageMV > 0, currentMA > 0
		else { return }
		let watts = Double(voltageMV) * Double(currentMA) / 1_000_000.0
		guard watts >= IOKitBatteryReader.minimumVisibleWatts else { return }

		var stats = chargerPowerStats[key] ?? ChargerPowerStats(key: key, ratedWatts: snapshot.adapterRatedWatts)
		stats.sampleCount += 1
		stats.sumWatts += watts
		stats.maxWatts = max(stats.maxWatts, watts)
		chargerPowerStats[key] = stats

		if Date().timeIntervalSince(lastChargerStatsSave) >= 60 {
			lastChargerStatsSave = Date()
			save(chargerPowerStats, key: Self.chargerPowerStatsKey)
		}
	}
	
	// MARK: - 应用耗电累计

	// 纯函数：把一段秒数累计进在场应用的当日记录；按截止键清掉过期天、按最近活跃封顶数量
	nonisolated static func appendingEnergySeconds(
		_ records: [AppEnergyUsage],
		ids: [String],
		names: [String: String],
		seconds: Double,
		dayKey: String,
		cutoffDayKey: String,
		now: Date,
		maxApps: Int
	) -> [AppEnergyUsage] {
		guard seconds > 0 else { return records }
		// 输入来自磁盘存档——理论上不会重键，但手改/异常数据不能把应用炸掉
		var byID = Dictionary(records.map { ($0.bundleId, $0) }, uniquingKeysWith: { first, _ in first })
		for id in ids {
			var record = byID[id] ?? AppEnergyUsage(bundleId: id, name: names[id] ?? id, secondsByDay: [:], lastSeen: now)
			if let latestName = names[id], !latestName.isEmpty { record.name = latestName }
			record.secondsByDay[dayKey, default: 0] += seconds
			record.lastSeen = now
			byID[id] = record
		}
		// 过期天对所有记录全量清理（不只在场的），否则离场应用的旧数据永远占着存储
		let cutoff = cutoffDayKey
		return Array(byID.values
			.map { record -> AppEnergyUsage in
				var record = record
				record.secondsByDay = record.secondsByDay.filter { $0.key >= cutoff }
				return record
			}
			.sorted { $0.lastSeen > $1.lastSeen }
			.prefix(maxApps))
	}

	// 每帧把"面板打开期间处于高耗电列表"的应用累计上这帧的秒数；
	// 高耗电列表只在面板打开时才刷新，列表非空 + 帧间隔正常才计
	private func accumulateAppEnergy() {
		let now = Date()
		let elapsed = lastEnergyTick.map { now.timeIntervalSince($0) } ?? 0
		lastEnergyTick = now
		guard elapsed > 0, elapsed <= 30 else { return }
		guard monitor.isPopoverOpen, !monitor.significantEnergyApps.isEmpty else { return }

		let dayKey = Self.dayKey(now)
		let cutoff = Self.dayKey(now.addingTimeInterval(-30 * 86400))
		appEnergy = Self.appendingEnergySeconds(
			appEnergy,
			ids: monitor.significantEnergyApps.map(\.id),
			names: Dictionary(monitor.significantEnergyApps.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
			seconds: elapsed,
			dayKey: dayKey,
			cutoffDayKey: cutoff,
			now: now,
			maxApps: 50
		)
		if now.timeIntervalSince(lastAppEnergySave) >= 60 {
			lastAppEnergySave = now
			save(appEnergy, key: Self.appEnergyKey)
		}
	}

	// MARK: - 今日用电小结
	
	// 相邻两次采样的电量差累计（纯函数 accumulatingDailyUsage），跨天追加新的一天
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
		let before = history[history.count - 1]
		let sampleGap = lastUsageSampleDate.map { now.timeIntervalSince($0) }
		let usage = Self.accumulatingDailyUsage(
			before,
			percent: percent,
			lastPercent: lastPercentForDaily,
			powerSource: snapshot.powerSource,
			isCharging: snapshot.isCharging,
			secondsSinceLastSample: sampleGap
		)
		// 时段用电与今日用电同源：电池模式的掉电增量同时计入对应小时桶；
		// 与今日用电同一归因窗口，跨睡眠的掉电不错记到醒来那一个小时
		let isContiguous = sampleGap.map { $0 > 0 && $0 <= Self.usageAttributionGapSeconds } ?? false
		if isContiguous, snapshot.powerSource == .battery, let last = lastPercentForDaily, percent < last {
			hourlyDrainStats = UsagePatternAnalyzer.accumulatingHourlyDrain(
				hourlyDrainStats,
				hour: Calendar.current.component(.hour, from: now),
				droppedPercent: Double(last - percent),
				dayKey: key
			)
		} else {
			// 没掉电也要推进天数键（跨天 accumulatedDays +1 靠它）
			hourlyDrainStats = UsagePatternAnalyzer.accumulatingHourlyDrain(
				hourlyDrainStats,
				hour: Calendar.current.component(.hour, from: now),
				droppedPercent: 0,
				dayKey: key
			)
		}
		// 落盘限频区分电量变化与纯时长：电量变了立存，纯时长最多一分钟存一次
		if usage.drainedPercent != before.drainedPercent || usage.chargedPercent != before.chargedPercent {
			structuralChange = true
		}
		history[history.count - 1] = usage
		
		guard history != dailyHistory else { return }
		dailyHistory = history
		if structuralChange || now.timeIntervalSince(lastDailyUsageSave) >= 60 {
			lastDailyUsageSave = now
			save(history, key: Self.dailyHistoryKey)
			save(hourlyDrainStats, key: Self.hourlyDrainKey)
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
	
	// 把最旧一个月的原始样本折叠成单点（当月最后一个读数），直到总数不超上限；
	// 若最旧月已是单点（历史深处全是月度聚合），本轮无进展也无害
	nonisolated static func foldingHealthSamples(_ samples: [HealthSample], maxRawCount: Int) -> [HealthSample] {
		guard samples.count > maxRawCount, let oldest = samples.first else { return samples }
		let monthKey = UsagePatternAnalyzer.monthKeyString(oldest.date)
		var folded: HealthSample?
		var index = 0
		while index < samples.count,
			UsagePatternAnalyzer.monthKeyString(samples[index].date) == monthKey {
			folded = samples[index]
			index += 1
		}
		guard let kept = folded, index > 1 else { return samples }
		return [kept] + samples[index...]
	}

	private func recordDailyHealth(_ snapshot: BatterySnapshot) {
		guard let health = snapshot.healthPercent else { return }

		let today = Date()
		if let last = healthSamples.last, Calendar.current.isDate(last.date, inSameDayAs: today) {
			return
		}

		// 原始日样本封顶后，最旧一个月折叠成单点（取当月最后读数）永久保留：
		// 老化以年计，近期要日粒度、远期月粒度就够，趋势线不会因封顶断头
		healthSamples = Self.foldingHealthSamples(
			healthSamples + [HealthSample(date: today, healthPercent: health, cycleCount: snapshot.cycleCount)],
			maxRawCount: Self.maxHealthSamples
		)
		save(healthSamples, key: Self.healthKey)
	}
	
	// MARK: - 持久化
	
	// 设置与历史全在一个 UserDefaults plist 里，损坏即静默清零；
	// 这里把历史键的最新编码滚到独立备份文件，主档损坏时回退备份，最多丢一个备份间隔
	private static func defaultBackupDirectory() -> URL? {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
			.appendingPathComponent("ChargeMonitor", isDirectory: true)
	}
	
	private var backupFileURL: URL? {
		backupDirectory?.appendingPathComponent(Self.backupFileName)
	}
	
	private func loadBackupRaw() -> [String: Data] {
		guard let url = backupFileURL, let data = try? Data(contentsOf: url) else { return [:] }
		return (try? PropertyListDecoder().decode([String: Data].self, from: data)) ?? [:]
	}
	
	private func saveBackupIfDue(now: Date = Date()) {
		guard let url = backupFileURL, now.timeIntervalSince(lastBackupSave) >= Self.backupIntervalSeconds else { return }
		lastBackupSave = now
		do {
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try PropertyListEncoder().encode(backupRaw).write(to: url, options: .atomic)
		} catch {
			DiagnosticLog.failureOnce("backup-save-failed", category: "BatteryHistoryRecorder", "历史滚动备份写入失败：\(error.localizedDescription)")
		}
	}
	
	private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
		let primary = defaults.data(forKey: key)
		let recovered = Self.decodingWithFallback(type, primaryData: primary, backupData: backupRaw[key])
		if let primary, (try? decoder.decode(type, from: primary)) == nil {
			DiagnosticLog.failureOnce("history-corrupt-\(key)", category: "BatteryHistoryRecorder", "历史数据 \(key) 损坏\(recovered != nil ? "，已从滚动备份恢复" : "，且无可用的滚动备份")")
		}
		return recovered
	}
	
	// 纯函数：主档 + 备份的解码策略，供单测直接调
	// 主档正常直接解码；主档有数据却解不开（损坏）回退备份；
	// 主档无数据（首次运行/被清空）不碰备份——备份只救损坏，不做删除恢复
	nonisolated static func decodingWithFallback<T: Decodable>(_ type: T.Type, primaryData: Data?, backupData: Data?) -> T? {
		guard let primaryData else { return nil }
		if let value = try? PropertyListDecoder().decode(type, from: primaryData) { return value }
		guard let backupData else { return nil }
		return try? PropertyListDecoder().decode(type, from: backupData)
	}
	
	private func save<T: Encodable>(_ value: T, key: String) {
		guard let data = try? encoder.encode(value) else { return }
		defaults.set(data, forKey: key)
		// 备份内存随写入保持最新，定期滚到磁盘
		backupRaw[key] = data
		saveBackupIfDue()
	}

	// MARK: - 全量存档（换机/重装的数据逃生舱）

	func makeArchive() -> BatteryHistoryArchive {
		BatteryHistoryArchive(
			exportedAt: Date(),
			sessions: recentSessions,
			healthSamples: healthSamples,
			dailyHistory: dailyHistory,
			lastSleepDrain: lastSleepDrain,
			chargerProfiles: chargerProfiles,
			socSamples: socSamples,
			powerEvents: powerEvents,
			chargerPowerStats: chargerPowerStats,
			hourlyDrainStats: hourlyDrainStats,
			appEnergy: appEnergy,
			socJumpEvents: socJumpEvents
		)
	}

	// 从存档恢复全部历史并逐键落盘（滚动备份随之刷新）；
	// 活动充电会话是运行态，不覆盖——若恢复时正在充电，本次会话继续记账
	func restore(from archive: BatteryHistoryArchive) {
		recentSessions = archive.sessions
		healthSamples = archive.healthSamples
		dailyHistory = archive.dailyHistory
		lastSleepDrain = archive.lastSleepDrain
		chargerProfiles = archive.chargerProfiles
		socSamples = archive.socSamples
		powerEvents = archive.powerEvents
		chargerPowerStats = archive.chargerPowerStats
		hourlyDrainStats = archive.hourlyDrainStats
		appEnergy = archive.appEnergy
		socJumpEvents = archive.socJumpEvents
		// 跳变追踪的基线随旧数据作废，恢复后从当前读数重新积累
		lastSocSample = nil

		save(recentSessions, key: Self.sessionsKey)
		save(healthSamples, key: Self.healthKey)
		save(dailyHistory, key: Self.dailyHistoryKey)
		save(chargerProfiles, key: Self.chargerProfilesKey)
		save(socSamples, key: Self.socSamplesKey)
		save(powerEvents, key: Self.powerEventsKey)
		save(chargerPowerStats, key: Self.chargerPowerStatsKey)
		save(hourlyDrainStats, key: Self.hourlyDrainKey)
		save(appEnergy, key: Self.appEnergyKey)
		save(socJumpEvents, key: Self.socJumpEventsKey)
		if let record = lastSleepDrain {
			save(record, key: Self.sleepDrainKey)
		} else {
			defaults.removeObject(forKey: Self.sleepDrainKey)
			backupRaw.removeValue(forKey: Self.sleepDrainKey)
		}
	}
}
