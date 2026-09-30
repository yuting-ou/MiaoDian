import AppKit
import Combine
import Foundation

// 睡眠掉电：合盖/唤醒的段归因与掉电记录。
// 睡眠时长要记进「当天」的用电行，所以它持有 DailyUsageRecorder——这是真实依赖，不藏着。
@MainActor
final class SleepDrainRecorder: ObservableObject {
	// 睡眠记录的键、上限与小憩门
	nonisolated private static let sleepDrainKey = "lastSleepDrain"
	nonisolated static let sleepDrainHistoryKey = "sleepDrainHistory"
	nonisolated static let sleepDrainHistoryLimit = 20
	// 合盖不足 20 分钟算小憩，不计入睡眠掉电记录
	nonisolated private static let minSleepSeconds: TimeInterval = 20 * 60

	// 上一觉合盖的掉电记录
	@Published private(set) var lastSleepDrain: SleepDrainRecord?
	/// E1：近两周合盖掉电滚动列表（聚合分析用）；上限 20 条
	@Published private(set) var sleepDrainHistory: [SleepDrainRecord] = []
	// 睡眠掉电：合盖时的时间、电量和当时的供电来源；醒来后等第一个新快照再结算
	// onAC 必须在此刻捕获：结算发生在醒来后，那时只剩"现在的"电源状态，
	// 拿它归因整夜会把"睡前拔着电、醒时插着电"错记成整夜插电
	private var sleepStart: (date: Date, percent: Int, onAC: Bool)?
	private var pendingWake: (sleepDate: Date, startPercent: Int, wakeDate: Date, onAC: Bool)?

	private let persistence: HistoryPersistence
	// 时间从构造器进来：测试给一个可推进的假钟就能把跨午夜/断档这类状态机走完
	private let clock: HistoryClock
	private let daily: DailyUsageRecorder

	init(persistence: HistoryPersistence, daily: DailyUsageRecorder, clock: HistoryClock = .live) {
		self.clock = clock
		self.persistence = persistence
		self.daily = daily
	}

	// 落盘转发（与拆分前的写法保持一致，调用点不用改）
	private func load<T: Decodable>(_ type: T.Type, key: String) -> T? { persistence.load(type, key: key) }
	private func save<T: Encodable>(_ value: T, key: String) { persistence.save(value, key: key) }


	// 醒来结算睡眠掉电；不足 20 分钟的小憩不记录
	nonisolated static func settledSleepDrain(sleepDate: Date, startPercent: Int, wakeDate: Date, endPercent: Int) -> SleepDrainRecord? {
		guard wakeDate.timeIntervalSince(sleepDate) >= minSleepSeconds else { return nil }
		return SleepDrainRecord(sleepDate: sleepDate, wakeDate: wakeDate, startPercent: startPercent, endPercent: endPercent)
	}

	// 睡眠段拆成按自然日的片段：合盖→醒来之间没有采样帧，但插电/电池时长与高电量驻留
	// 是真实发生的，不补记则每天记到的时长只有醒着那几小时（实测 09-22 只记到 6.1h，
	// 而那一夜 11.9h 睡眠全丢）——续航换算、驻留洞察、插电占比全部偏低。
	// 两端电量已知，中间按时间线性看待（慢放/慢充本就近似线性），跨午夜时两天各算各的那段；
	// 日键走 UsageCalendarLayout.dayKey（与注入 calendar.timeZone 同源，时区漂移不错位）。
	// 睡眠中的供电来源变化无从观测，整段按合盖那一刻的电源归因（诚实边界）。
	nonisolated static func sleepSegmentParts(
		sleepDate: Date,
		startPercent: Int,
		wakeDate: Date,
		endPercent: Int,
		calendar: Calendar
	) -> [SleepSegmentPart] {
		let total = wakeDate.timeIntervalSince(sleepDate)
		guard total > 0 else { return [] }
		let span = Double(endPercent - startPercent)
		var parts: [SleepSegmentPart] = []
		var cursor = sleepDate
		while cursor < wakeDate {
			guard let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor)) else { break }
			let end = min(midnight, wakeDate)
			parts.append(SleepSegmentPart(
				dayKey: UsageCalendarLayout.dayKey(cursor, calendar: calendar),
				seconds: end.timeIntervalSince(cursor),
				startPercent: Double(startPercent) + span * (cursor.timeIntervalSince(sleepDate) / total),
				endPercent: Double(startPercent) + span * (end.timeIntervalSince(sleepDate) / total)
			))
			cursor = end
		}
		return parts
	}

	func finalizeSleepDrainIfNeeded(_ snapshot: BatterySnapshot) {
		guard let percent = snapshot.stateOfChargePercent else { return }
		settlePendingSleepDrain(endPercent: percent)
	}

	private func settlePendingSleepDrain(endPercent: Int) {
		guard let pending = pendingWake else { return }
		pendingWake = nil
		// 时长与驻留归因不受 ≥20 分钟门约束：小憩 10 分钟也在耗电，也该算进当天时长，
		// 那道门只管"睡眠掉电记录/告警"这件事
		let parts = Self.sleepSegmentParts(
			sleepDate: pending.sleepDate,
			startPercent: pending.startPercent,
			wakeDate: pending.wakeDate,
			endPercent: endPercent,
			calendar: clock.calendar
		)
		// 时长记进「当天」的用电行——这一步归每日用电域（日键与保留窗口是它的），
		// 这里只把拆好的段交出去，不自己碰 dailyHistory
		daily.creditSleepTime(parts: parts, onAC: pending.onAC)
		guard let record = Self.settledSleepDrain(
			sleepDate: pending.sleepDate,
			startPercent: pending.startPercent,
			wakeDate: pending.wakeDate,
			endPercent: endPercent
		) else { return }
		lastSleepDrain = record
		save(record, key: Self.sleepDrainKey)
		appendSleepHistory(record)
		fetchSleepCulprits(for: record)
	}

	/// E1：滚动追加睡眠掉电史（同一 sleepDate 替换，避免重复结算）
	private func appendSleepHistory(_ record: SleepDrainRecord) {
		var list = sleepDrainHistory.filter { $0.sleepDate != record.sleepDate }
		list.append(record)
		list.sort { $0.sleepDate > $1.sleepDate }
		if list.count > Self.sleepDrainHistoryLimit {
			list = Array(list.prefix(Self.sleepDrainHistoryLimit))
		}
		sleepDrainHistory = list
		save(list, key: Self.sleepDrainHistoryKey)
	}

	// 醒来结算后异步抓取"谁在持有阻止睡眠断言"，回填进记录——
	// 通知、面板、报告都能复述元凶，而不是只在通知里闪现一次
	private func fetchSleepCulprits(for record: SleepDrainRecord) {
		let reader = SleepAssertionReader()
		Task { [weak self] in
			let owners = await Task.detached(priority: .utility) { reader.assertionOwnerNames() }.value
			guard let self, !owners.isEmpty else { return }
			// 期间可能又睡了一觉，只回填还是"那一觉"的记录
			guard self.lastSleepDrain?.sleepDate == record.sleepDate else { return }
			var updated = record
			updated.culpritNames = owners
			self.lastSleepDrain = updated
			self.save(updated, key: Self.sleepDrainKey)
			// 同步回填历史列表，聚合排行才能看到元凶
			if let idx = self.sleepDrainHistory.firstIndex(where: { $0.sleepDate == record.sleepDate }) {
				var list = self.sleepDrainHistory
				list[idx].culpritNames = owners
				self.sleepDrainHistory = list
				self.save(list, key: Self.sleepDrainHistoryKey)
			}
		}
	}

	// MARK: - 合盖/唤醒（由门面从 NSWorkspace 通知转进来）

	/// 合盖：定格这一刻的电量与供电来源。
	/// onAC 必须在此刻捕获——结算发生在醒来后，那时只剩「现在的」电源状态，
	/// 拿它归因整夜会把「睡前拔着电、醒时插着电」错记成整夜插电。
	/// lastPercent 由每日用电域提供（它才是维护「最后一次采样电量」的地方）。
	func handleWillSleep(onAC: Bool, lastPercent: Int?) {
		// 醒后未及结算又合盖：先用当前电量把上一觉结掉，否则整夜掉电静默丢失
		if pendingWake != nil, let percent = lastPercent {
			settlePendingSleepDrain(endPercent: percent)
		}
		guard let percent = lastPercent else { return }
		sleepStart = (clock.now(), percent, onAC)
		pendingWake = nil
	}

	/// 唤醒：挂起等待下一个快照再结算——醒来瞬间的快照可能还是睡前的旧值
	func handleDidWake() {
		guard let start = sleepStart else { return }
		sleepStart = nil
		pendingWake = (start.date, start.percent, clock.now(), start.onAC)
	}

	// MARK: - 自己的加载与恢复

	func loadFromDisk() {
		lastSleepDrain = load(SleepDrainRecord.self, key: Self.sleepDrainKey)
		sleepDrainHistory = load([SleepDrainRecord].self, key: Self.sleepDrainHistoryKey) ?? []
	}

	func restore(from archive: BatteryHistoryArchive) {
		lastSleepDrain = archive.lastSleepDrain
		// E1：旧档无 sleepDrainHistory 时保留当前；有则导入
		if let hist = archive.sleepDrainHistory {
			sleepDrainHistory = hist
			save(hist, key: Self.sleepDrainHistoryKey)
		}
		if let record = lastSleepDrain {
			save(record, key: Self.sleepDrainKey)
		} else {
			persistence.remove(key: Self.sleepDrainKey)
		}
	}
}
