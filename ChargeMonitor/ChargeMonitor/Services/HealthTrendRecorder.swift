import AppKit
import Combine
import Foundation

// 健康度趋势采样与电池更换边界。
// 序列号变了 = 现实里换过电池：旧趋势与新读数不可比，必须切一刀。
@MainActor
final class HealthTrendRecorder: ObservableObject {
	// 健康样本的键与封顶；序列号/更换时刻是小标量，仍走 UserDefaults
	nonisolated private static let healthKey = "healthSamples"
	// 电池序列号与更换边界：序列号变了 = 现实里换过电池
	nonisolated private static let batterySerialKey = "batterySerialLastSeen"
	nonisolated private static let batteryReplacedAtKey = "batteryReplacedAt"
	nonisolated private static let maxHealthSamples = 400

	@Published private(set) var healthSamples: [HealthSample] = []
	// 最近一次检测到电池更换的时刻（序列号变化）；nil = 从未换过
	private(set) var batteryReplacedAt: Date?

	private let persistence: HistoryPersistence
	// 时间从构造器进来：测试给一个可推进的假钟就能把跨午夜/断档这类状态机走完
	private let clock: HistoryClock
	private let defaults: UserDefaults
	// 检测到换电池要往电源事件时间线记一笔（趋势边界的可见凭据），
	// 序列号则要读 monitor 的电池身份——两个都是真实依赖，显式注入不藏着
	private let events: PowerEventRecorder
	private let monitor: BatteryMonitor

	init(persistence: HistoryPersistence, defaults: UserDefaults, events: PowerEventRecorder, monitor: BatteryMonitor, clock: HistoryClock = .live) {
		self.clock = clock
		self.persistence = persistence
		self.defaults = defaults
		self.events = events
		self.monitor = monitor
	}

	// 落盘转发（与拆分前的写法保持一致，调用点不用改）
	private func load<T: Decodable>(_ type: T.Type, key: String) -> T? { persistence.load(type, key: key) }
	private func save<T: Encodable>(_ value: T, key: String) { persistence.save(value, key: key) }


	// 电池更换事件边界：换电池后旧趋势与新读数不可比，健康趋势/预测只看更换之后的样本
	var trendHealthSamples: [HealthSample] {
		Self.filteringHealthSamplesForTrend(healthSamples, replacedAt: batteryReplacedAt)
	}

	// 纯函数，供单测直测：更换边界前的样本全部丢弃
	nonisolated static func filteringHealthSamplesForTrend(_ samples: [HealthSample], replacedAt: Date?) -> [HealthSample] {
		guard let replacedAt else { return samples }
		return samples.filter { $0.date >= replacedAt }
	}

	// 健康趋势：最早一笔和最新一笔的对比（跨度至少 1 天才有意义）
	var healthTrend: (earliest: HealthSample, latest: HealthSample)? {
		let samples = trendHealthSamples
		guard
			let earliest = samples.first,
			let latest = samples.last,
			latest.date.timeIntervalSince(earliest.date) >= 24 * 3600
		else { return nil }
		return (earliest, latest)
	}

	// 序列号变了 = 现实里换过电池：记一条电源事件作为趋势边界，
	// 否则健康曲线会凭空"反弹"、寿命预测拿旧电池的趋势套新电池
	func detectBatterySwap() {
		guard let serial = monitor.batteryIdentity?.serialNumber, !serial.isEmpty else { return }
		let stored = defaults.string(forKey: Self.batterySerialKey)
		defaults.set(serial, forKey: Self.batterySerialKey)
		guard Self.shouldFlagBatterySwap(stored: stored, current: serial) else { return }
		let now = clock.now()
		batteryReplacedAt = now
		defaults.set(now, forKey: Self.batteryReplacedAtKey)
		events.appendPowerEvent(.batteryReplaced)
	}

	// 纯判定（供单测）：首次运行只记基准；读不到序列号不误报；变了才算更换
	nonisolated static func shouldFlagBatterySwap(stored: String?, current: String?) -> Bool {
		guard let stored, !stored.isEmpty, let current, !current.isEmpty else { return false }
		return stored != current
	}

	// 把最旧一个"还有多个样本可折"的月折叠成单点（当月最后一个读数），
	// 直到总数不超上限。最旧月已是单点时跳过它继续往后找——
	// 否则导入的异常存档（单点月+总数超限）会让封顶永久停滞
	nonisolated static func foldingHealthSamples(_ samples: [HealthSample], maxRawCount: Int) -> [HealthSample] {
		guard samples.count > maxRawCount, !samples.isEmpty else { return samples }
		var monthStart = 0
		while monthStart < samples.count {
			let monthKey = UsagePatternAnalyzer.monthKeyString(samples[monthStart].date)
			var monthEnd = monthStart
			while monthEnd < samples.count,
				UsagePatternAnalyzer.monthKeyString(samples[monthEnd].date) == monthKey {
				monthEnd += 1
			}
			if monthEnd - monthStart >= 2 {
				return Array(samples[0..<monthStart]) + [samples[monthEnd - 1]] + samples[monthEnd...]
			}
			monthStart = monthEnd
		}
		// 全是单点：无可折，原样返回（有界，无害）
		return samples
	}

	func recordDailyHealth(_ snapshot: BatterySnapshot) {
		guard let health = snapshot.healthPercent else { return }

		let today = clock.now()
		if let last = healthSamples.last, clock.calendar.isDate(last.date, inSameDayAs: today) {
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

	// MARK: - 自己的加载与恢复

	var batterySerialLastSeen: String? { defaults.string(forKey: Self.batterySerialKey) }

	func loadFromDisk() {
		healthSamples = load([HealthSample].self, key: Self.healthKey) ?? []
		batteryReplacedAt = defaults.object(forKey: Self.batteryReplacedAtKey) as? Date
		detectBatterySwap()
	}

	func restore(from archive: BatteryHistoryArchive) {
		healthSamples = archive.healthSamples
		save(healthSamples, key: Self.healthKey)
		// 电池更换边界随档恢复：丢了它，换过电池的传记会把两块电池连成假曲线。
		// 旧存档缺字段（nil）时序列号保持现状、边界按「无更换」重置以与恢复的样本一致
		if let serial = archive.batterySerialLastSeen {
			defaults.set(serial, forKey: Self.batterySerialKey)
		}
		batteryReplacedAt = archive.batteryReplacedAt
		if let replacedAt = archive.batteryReplacedAt {
			defaults.set(replacedAt, forKey: Self.batteryReplacedAtKey)
		} else {
			defaults.removeObject(forKey: Self.batteryReplacedAtKey)
		}
	}
}
