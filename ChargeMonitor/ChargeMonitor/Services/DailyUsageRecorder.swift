import AppKit
import Combine
import Foundation

// 今日用电小结、时段用电/温度画像、应用耗电累计。
// 睡眠时长也记在「当天」的用电行上（跨午夜那觉按段拆开），所以它对外暴露 creditSleepTime。
@MainActor
final class DailyUsageRecorder: ObservableObject {
	// 用电/温度/应用耗电的键、保留窗口与断档门
	nonisolated private static let dailyUsageKey = "dailyUsage"
	nonisolated private static let dailyHistoryKey = "dailyUsageHistory"
	nonisolated private static let hourlyDrainKey = "hourlyDrainStats"
	nonisolated private static let hourlyTempKey = "hourlyTempStats"
	nonisolated private static let appEnergyKey = "appEnergy"
	// 用电历史保留 90 天：七天柱图只看末尾 7 天，日历热力图需要更长跨度
	nonisolated private static let maxDailyHistory = 90
	// 帧间隔超过归因窗口视为睡过：跨睡眠的电量差是夜里慢慢掉/慢慢充的，
	// 全记到醒来那一帧会把整夜耗电/充电错记成瞬时变化（时段热力图也会错桶），一律不计
	nonisolated private static let usageAttributionGapSeconds: TimeInterval = 3 * 60

	// 插入新的一天并保持 dayKey 升序：时区西行/时钟回拨会让"今天"的键比已存键更早，
	// 不排序则封顶 removeFirst 会错删较新的天，报告与柱图的窗口起点也会错乱。
	// v1.18.5 封顶护今（状态机边界）：排序后若封顶会裁掉"今天"（西行跨日界线后今天
	// 就是全表最旧键），改为跳过今天、从今天的后继起裁掉 excess 个最老的旧天——
	// 今日小结不能因为时区旅行当天永久缺失（旧实现裁掉今天后 firstIndex 找不到键，
	// 当天帧全部静默丢弃，且西行期间天天如此）。今天不在裁剪区间 → 普通封顶。
	nonisolated static func insertingDailyUsage(_ history: [DailyUsage], dayKey: String, maxDays: Int) -> [DailyUsage] {
		var history = history
		// 建行之时把当时生效的归因窗口钉进这一行：口径以后还会变，跨天比值必须有同桶依据
		history.append(DailyUsage(dayKey: dayKey, attributionGapSeconds: Self.usageAttributionGapSeconds))
		history.sort { $0.dayKey < $1.dayKey }
		let excess = history.count - maxDays
		guard excess > 0 else { return history }
		// 封顶永不失「今天」：从最旧起删掉 excess 个非今天的天。
		// 不按下标切片——超长档 + 今天落中部时 (todayIndex+1+excess) 会越界 trap
		// （restore 不封顶的 dailyHistory 跨时区西行即可触发）。
		var toRemove = excess
		var kept: [DailyUsage] = []
		kept.reserveCapacity(maxDays)
		for day in history {
			if day.dayKey != dayKey, toRemove > 0 {
				toRemove -= 1
				continue
			}
			kept.append(day)
		}
		return kept
	}

	// 最近几天的用电累计，末尾是今天，最多保留 90 天（供七天柱图与日历热力图）
	@Published private(set) var dailyHistory: [DailyUsage] = []
	// 时段用电：按小时分桶累计的掉电（热力图数据源）
	@Published private(set) var hourlyDrainStats = HourlyDrainStats()
	// 时段温度画像：每小时历史最高温，与用电高峰对照出"热叠加"洞察
	@Published private(set) var hourlyTempStats = HourlyTempStats()
	// 应用耗电累计：按天记录各应用"高耗电"状态的秒数
	@Published private(set) var appEnergy: [AppEnergyUsage] = []
	// 今天的用电累计；时区西行使"今天"的键可能不是数组末尾，按键查找
	var todayUsage: DailyUsage? {
		dailyHistory.last { $0.dayKey == Self.dayKey(clock.now()) }
	}
	// 今日用电累计用：上一次看到的电量与采样时刻（时长占比靠它算增量）
	private(set) var lastPercentForDaily: Int?
	private var lastUsageSampleDate: Date?
	private var lastDailyUsageSave = Date.distantPast
	// 应用耗电累计：上一次计时的时刻（帧间隔超上限视为断档不计）
	private var lastEnergyTick: Date?
	private var lastAppEnergySave = Date.distantPast

	private let persistence: HistoryPersistence
	// 时间从构造器进来：测试给一个可推进的假钟就能把跨午夜/断档这类状态机走完
	private let clock: HistoryClock
	private let monitor: BatteryMonitor

	init(persistence: HistoryPersistence, monitor: BatteryMonitor, clock: HistoryClock = .live) {
		self.clock = clock
		self.persistence = persistence
		self.monitor = monitor
	}

	// 落盘转发（与拆分前的写法保持一致，调用点不用改）
	private func load<T: Decodable>(_ type: T.Type, key: String) -> T? { persistence.load(type, key: key) }
	private func save<T: Encodable>(_ value: T, key: String) { persistence.save(value, key: key) }


	// 温度画像每帧记入当前小时的峰值；只有真刷新了峰值才落盘（每小时至多几次写）
	func accumulateHourlyTemp(_ snapshot: BatterySnapshot) {
		guard let celsius = snapshot.temperatureC, celsius > 0 else { return }
		let now = clock.now()
		let before = hourlyTempStats
		hourlyTempStats = UsagePatternAnalyzer.accumulatingHourlyTemp(
			hourlyTempStats,
			hour: clock.calendar.component(.hour, from: now),
			celsius: celsius,
			dayKey: UsagePatternAnalyzer.dayKeyString(now)
		)
		if hourlyTempStats != before {
			save(hourlyTempStats, key: Self.hourlyTempKey)
		}
	}

	// 插入新的一天并保持 dayKey 升序：时区西行/时钟回拨会让"今天"的键比已存键更早，
	// 不排序则封顶 removeFirst 会错删较新的天，报告与柱图的窗口起点也会错乱。
	// v1.18.5 封顶护今（状态机边界）：排序后若封顶会裁掉"今天"（西行跨日界线后今天
	// 就是全表最旧键），改为跳过今天、从今天的后继起裁掉 excess 个最老的旧天——
	// 今日小结不能因为时区旅行当天永久缺失（旧实现裁掉今天后 firstIndex 找不到键，
	// 当天帧全部静默丢弃，且西行期间天天如此）。今天不在裁剪区间 → 普通封顶。

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
		// 时长与掉电共用同一个归因窗口：窗口内两样都记，超窗两样都不记。
		// 旧实现这里另设 30 秒小帽（掉电允许 180 秒），App Nap 或维护性睡眠把轮询
		// 拖到 30~180 秒时，掉电照记、时长整段消失——本机实测某日 13.7 小时只归因
		// 2.2 小时，醒着强度被抬到真值的数倍，动态续航的校准输入因此是假的。
		if let delta = secondsSinceLastSample, isContiguous {
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

	/// 段内「电量 ≥ 阈值」的时间占比。单调线性路径下，电量区间与时间区间成正比，
	/// 闭式解为高端点到阈值的距离占总落差之比；两端同值时要么全程要么全无。
	nonisolated static func dwellShareAbove(_ threshold: Double, from startPercent: Double, to endPercent: Double) -> Double {
		let hi = max(startPercent, endPercent), lo = min(startPercent, endPercent)
		if hi == lo { return hi >= threshold ? 1 : 0 }
		return min(max((hi - threshold) / (hi - lo), 0), 1)
	}

	/// 睡眠段结算进日行。只补时长与驻留，不动 drainedPercent/chargedPercent
	/// （电量差仍归连续采样窗，否则整夜掉电会被当成"瞬时用电"）；
	/// 那天没有日行则跳过——凭空造一行会让"记录 N 天"与月报日均分母虚增。
	/// 把一觉的时长记进「当天」的用电行（跨午夜那觉由 creditingSleepTime 按段拆开）。
	/// 睡眠域不直接碰 dailyHistory：日键与保留窗口归这个域管，落盘也走这里
	func creditSleepTime(parts: [SleepSegmentPart], onAC: Bool) {
		let credited = Self.creditingSleepTime(dailyHistory, parts: parts, onAC: onAC)
		guard credited != dailyHistory else { return }
		dailyHistory = credited
		save(dailyHistory, key: Self.dailyHistoryKey)
	}

	nonisolated static func creditingSleepTime(
		_ history: [DailyUsage],
		parts: [SleepSegmentPart],
		onAC: Bool
	) -> [DailyUsage] {
		var history = history
		for part in parts {
			// 短于归因窗的睡眠，跨它的那一帧已经按同一段记过时长与驻留；
			// 两条路径以同一个窗口分界（≤窗归帧、>窗归睡眠段），重叠区间不再双计
			guard part.seconds > usageAttributionGapSeconds else { continue }
			guard part.seconds > 0, let index = history.firstIndex(where: { $0.dayKey == part.dayKey }) else { continue }
			if onAC {
				history[index].acSeconds += part.seconds
				// 插电那半边也要留痕：没有这一笔，「醒着口径」的插电占比无从还原
				// （旧实现只给电池那半边记了 sleepBatterySeconds）
				history[index].sleepACSeconds = (history[index].sleepACSeconds ?? 0) + part.seconds
			} else {
				history[index].batterySeconds += part.seconds
				// 单独记一份"来自睡眠的电池时长"：醒着掉电/醒着时长这类比值要拿它减回分母
				history[index].sleepBatterySeconds = (history[index].sleepBatterySeconds ?? 0) + part.seconds
			}
			let above90 = dwellShareAbove(90, from: part.startPercent, to: part.endPercent)
			let above80 = dwellShareAbove(80, from: part.startPercent, to: part.endPercent)
			history[index].soc90to100Seconds += part.seconds * above90
			history[index].soc80to90Seconds += part.seconds * (above80 - above90)
		}
		return history
	}

	// 纯函数：把一段秒数累计进在场应用的当日记录；按截止键清掉过期天、按最近活跃封顶数量
	nonisolated static func appendingEnergySeconds(
		_ records: [AppEnergyUsage],
		ids: [String],
		names: [String: String],
		seconds: Double,
		hour: Int,
		dayKey: String,
		cutoffDayKey: String,
		now: Date,
		maxApps: Int
	) -> [AppEnergyUsage] {
		guard seconds > 0 else { return records }
		// 输入来自磁盘存档——理论上不会重键，但手改/异常数据不能把应用炸掉
		var byID = Dictionary(records.map { ($0.bundleId, $0) }, uniquingKeysWith: { first, _ in first })
		let bucket = min(max(hour, 0), 23)
		for id in ids {
			var record = byID[id] ?? AppEnergyUsage(bundleId: id, name: names[id] ?? id, secondsByDay: [:], lastSeen: now)
			if let latestName = names[id], !latestName.isEmpty { record.name = latestName }
			record.secondsByDay[dayKey, default: 0] += seconds
			// 小时分布：旧档首次累计时补建 24 桶
			var hourly = record.secondsByHour ?? Array(repeating: 0, count: 24)
			hourly[bucket] += seconds
			record.secondsByHour = hourly
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
	func accumulateAppEnergy() {
		let now = clock.now()
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
			hour: clock.calendar.component(.hour, from: now),
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

	// 相邻两次采样的电量差累计（纯函数 accumulatingDailyUsage），跨天追加新的一天
	func updateDailyUsage(_ snapshot: BatterySnapshot) {
		guard let percent = snapshot.stateOfChargePercent else { return }
		let now = clock.now()
		defer {
			lastPercentForDaily = percent
			lastUsageSampleDate = now
		}

		let key = Self.dayKey(now)
		var history = dailyHistory
		var structuralChange = false
		if !history.contains(where: { $0.dayKey == key }) {
			history = Self.insertingDailyUsage(history, dayKey: key, maxDays: Self.maxDailyHistory)
			structuralChange = true
		}
		guard let dayIndex = history.firstIndex(where: { $0.dayKey == key }) else { return }
		let before = history[dayIndex]
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
				hour: clock.calendar.component(.hour, from: now),
				droppedPercent: Double(last - percent),
				dayKey: key
			)
		} else {
			// 没掉电也要推进天数键（跨天 accumulatedDays +1 靠它）
			hourlyDrainStats = UsagePatternAnalyzer.accumulatingHourlyDrain(
				hourlyDrainStats,
				hour: clock.calendar.component(.hour, from: now),
				droppedPercent: 0,
				dayKey: key
			)
		}
		// 落盘限频区分电量变化与纯时长：电量变了立存，纯时长最多一分钟存一次
		if usage.drainedPercent != before.drainedPercent || usage.chargedPercent != before.chargedPercent {
			structuralChange = true
		}
		history[dayIndex] = usage

		guard history != dailyHistory else { return }
		dailyHistory = history
		if structuralChange || now.timeIntervalSince(lastDailyUsageSave) >= 60 {
			lastDailyUsageSave = now
			save(history, key: Self.dailyHistoryKey)
			save(hourlyDrainStats, key: Self.hourlyDrainKey)
		}
	}

	/// 日键。落盘的机器主键：固定 POSIX 公历（否则用户把系统日历改成佛历，yyyy 会输出 2570 这种年份）。
	/// 提成 internal 是给门面顺序断言用的——那组断言要按**真实日键**摆跨午夜的位，
	/// 测试自己抄一份 `yyyy-MM-dd` 就是第二个真源，判据会和被判处件漂移。
	static func dayKey(_ date: Date) -> String {
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

	// MARK: - 自己的加载与恢复

	func loadFromDisk() {
		// 用电历史也捡回来；早期版本只存单天，迁移进历史数组后删旧键
		if let history = load([DailyUsage].self, key: Self.dailyHistoryKey) {
			dailyHistory = history
		} else if let old = load(DailyUsage.self, key: Self.dailyUsageKey) {
			dailyHistory = [old]
			save(dailyHistory, key: Self.dailyHistoryKey)
			// 显式遗忘必须走持久化管道：它会连带清掉 UserDefaults 旧键，
			// 否则下次启动「文件不在 → 迁回旧键」会把刚删掉的单天档复活
			persistence.remove(key: Self.dailyUsageKey)
		}
		hourlyDrainStats = load(HourlyDrainStats.self, key: Self.hourlyDrainKey) ?? HourlyDrainStats()
		hourlyTempStats = load(HourlyTempStats.self, key: Self.hourlyTempKey) ?? HourlyTempStats()
		appEnergy = load([AppEnergyUsage].self, key: Self.appEnergyKey) ?? []
	}

	func restore(from archive: BatteryHistoryArchive) {
		dailyHistory = archive.dailyHistory
		hourlyDrainStats = archive.hourlyDrainStats
		// 旧存档没有温度画像时保留当前值，不清零
		if let tempStats = archive.hourlyTempStats {
			hourlyTempStats = tempStats
		}
		appEnergy = archive.appEnergy
		save(dailyHistory, key: Self.dailyHistoryKey)
		save(hourlyDrainStats, key: Self.hourlyDrainKey)
		save(hourlyTempStats, key: Self.hourlyTempKey)
		save(appEnergy, key: Self.appEnergyKey)
	}
}
