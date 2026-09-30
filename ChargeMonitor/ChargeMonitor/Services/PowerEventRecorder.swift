import AppKit
import Combine
import Foundation

// 电源事件时间线（插拔电/充满/睡眠唤醒）。
// 靠上一帧的电源状态做边沿检测，连发事件按 eventMergeSeconds 合并。
@MainActor
final class PowerEventRecorder: ObservableObject {
	// 事件时间线的键、上限与连发合并窗口
	nonisolated private static let powerEventsKey = "powerEvents"
	nonisolated private static let maxPowerEvents = 50
	// 同类电源事件间隔小于这个值视为连发，合并只留最新一条
	nonisolated private static let eventMergeSeconds: TimeInterval = 2 * 60

	// 电源事件时间线（插拔电/充满/睡眠唤醒），新的在末尾
	@Published private(set) var powerEvents: [PowerEvent] = []
	// 事件边沿检测用：上一帧的电源状态
	private var lastPowerSource: PowerSourceType?
	private var lastIsFull = false

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

	func recordPowerEvents(_ snapshot: BatterySnapshot) {
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

	func appendPowerEvent(_ kind: PowerEventKind) {
		powerEvents = Self.appendingPowerEvent(powerEvents, kind: kind, now: clock.now())
		save(powerEvents, key: Self.powerEventsKey)
	}

	// MARK: - 自己的加载与恢复

	func loadFromDisk() {
		powerEvents = load([PowerEvent].self, key: Self.powerEventsKey) ?? []
	}

	func restore(from archive: BatteryHistoryArchive) {
		powerEvents = archive.powerEvents
		save(powerEvents, key: Self.powerEventsKey)
	}
}
