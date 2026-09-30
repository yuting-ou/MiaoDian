import AppKit
import Combine
import Foundation

// 24 小时电量曲线采样 + 电量计跳变事件。
// 两块都只吃快照与时钟，彼此不依赖别的域——拆出来的第一批。
@MainActor
final class SocSampleRecorder: ObservableObject {
	// SOC 曲线与跳变检测的键、上限、窗口
	nonisolated private static let socSamplesKey = "socSamples"
	nonisolated private static let socJumpEventsKey = "socJumpEvents"
	// SOC 采样：窗口 24 小时；平时 10 分钟一点，电量变化/充电状态翻转时加密采点
	nonisolated private static let socWindowSeconds: TimeInterval = 24 * 3600
	nonisolated private static let socRegularInterval: TimeInterval = 10 * 60
	nonisolated private static let socChangeMinInterval: TimeInterval = 3 * 60
	// 跳变事件保留上限（窗口统计只看 30 天，60 条足够）
	nonisolated private static let maxSocJumpEvents = 60
	// 相邻采样间隔超过这个值视为睡过：合盖慢放电不算跳变
	nonisolated private static let socJumpMaxGapSeconds: TimeInterval = 3 * 60

	// 24 小时电量曲线采样
	@Published private(set) var socSamples: [SOCSample] = []
	// 电量跳变事件：电池模式下相邻采样电量突变（电量计失准的表现）
	@Published private(set) var socJumpEvents: [SocJumpEvent] = []

	// 跳变检测用：电池模式下上一次采样的电量与时刻（充电/插电即重置）
	private var lastSocSample: (date: Date, percent: Int)?

	private let persistence: HistoryPersistence
	// 时间从构造器进来：测试给一个可推进的假钟就能把跨午夜/断档这类状态机走完
	private let clock: HistoryClock

	init(persistence: HistoryPersistence, clock: HistoryClock = .live) {
		self.clock = clock
		self.persistence = persistence
	}

	// 落盘转发（与拆分前的写法保持一致，调用点不用改）
	private func load<T: Decodable>(_ type: T.Type, key: String) -> T? { persistence.load(type, key: key) }
	private func save<T: Encodable>(_ value: T, key: String) { persistence.save(value, key: key) }


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

	// 这一帧是否记入 24 小时电量曲线：平时按固定间隔记，
	// 电量变化（距上点有最小间隔）或充电状态翻转时加密采点
	nonisolated static func shouldRecordSOCSample(last: SOCSample?, percent: Int, isCharging: Bool, now: Date) -> Bool {
		guard let last else { return true }
		let elapsed = now.timeIntervalSince(last.date)
		let chargingFlipped = last.isCharging != isCharging
		let percentMoved = last.percent != percent && elapsed >= socChangeMinInterval
		return chargingFlipped || percentMoved || elapsed >= socRegularInterval
	}

	func recordSOCSample(_ snapshot: BatterySnapshot) {
		guard let percent = snapshot.stateOfChargePercent else { return }
		let now = clock.now()
		guard Self.shouldRecordSOCSample(last: socSamples.last, percent: percent, isCharging: snapshot.isCharging, now: now) else { return }

		var samples = socSamples
		samples.append(SOCSample(date: now, percent: percent, isCharging: snapshot.isCharging))
		samples.removeAll { now.timeIntervalSince($0.date) > Self.socWindowSeconds }
		socSamples = samples
		save(samples, key: Self.socSamplesKey)
	}

	// 电池模式下相邻采样（10 秒级）电量本不该突变 ≥2%，出现即记一笔跳变；
	// 插电/充电即重置追踪（充电时的电量快涨是正常 CC/CV 行为）
	func trackSocJumps(_ snapshot: BatterySnapshot) {
		guard snapshot.powerSource == .battery, !snapshot.isCharging,
			let percent = snapshot.stateOfChargePercent else {
			lastSocSample = nil
			return
		}
		let now = clock.now()
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

	// MARK: - 自己的加载与恢复

	func loadFromDisk() {
		socSamples = load([SOCSample].self, key: Self.socSamplesKey) ?? []
		socJumpEvents = load([SocJumpEvent].self, key: Self.socJumpEventsKey) ?? []
	}

	func restore(from archive: BatteryHistoryArchive) {
		socSamples = archive.socSamples
		socJumpEvents = archive.socJumpEvents
		// 跳变追踪的基线随旧数据作废，恢复后从当前读数重新积累
		lastSocSample = nil
		save(socSamples, key: Self.socSamplesKey)
		save(socJumpEvents, key: Self.socJumpEventsKey)
	}
}
