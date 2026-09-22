import Foundation

/// H3 健康异常（诚实子集）：30 天健康度骤降 + 循环里程碑。
/// 持续高温不在本轮——HourlyTempStats 无可靠「连续天」证据，不编造。
nonisolated enum HealthAnomalyDetector {
	enum Kind: String, Equatable, Sendable {
		case healthDecline
		case cycleMilestone
	}

	struct Finding: Equatable, Sendable {
		let kind: Kind
		let notificationID: String
		let title: String
		let body: String
	}

	nonisolated static let defaultDeclineWindowDays: Double = 30
	nonisolated static let defaultDeclinePoints: Int = 5
	nonisolated static let defaultCycleMilestones: [Int] = [800, 1000]

	/// 窗口内健康度下降 ≥ thresholdPoints 才报；样本跨度不足窗口一半则 nil（防噪声）
	nonisolated static func healthDeclineFinding(
		samples: [HealthSample],
		thresholdPoints: Int = defaultDeclinePoints,
		windowDays: Double = defaultDeclineWindowDays,
		now: Date = Date()
	) -> Finding? {
		guard thresholdPoints > 0, windowDays > 0 else { return nil }
		let cutoff = now.addingTimeInterval(-windowDays * 86400)
		let window = samples.filter { $0.date >= cutoff && $0.date <= now }
		guard let first = window.first, let last = window.last, window.count >= 2 else { return nil }
		let span = last.date.timeIntervalSince(first.date) / 86400
		guard span >= windowDays * 0.5 else { return nil }
		let drop = first.healthPercent - last.healthPercent
		guard drop >= thresholdPoints else { return nil }
		return Finding(
			kind: .healthDecline,
			notificationID: "health-decline-\(Int(now.timeIntervalSince1970) / 86400)",
			title: "健康度近期下降较快",
			body: String(
				format: "约 %.0f 天内健康度从 %d%% 降到 %d%%（下降 %d 个百分点）。可能与高温或长期高电量驻留有关，可在面板查看驻留与温度。",
				span, first.healthPercent, last.healthPercent, drop
			)
		)
	}

	/// 循环数达到里程碑（只报 lastSeen 与 cycle 之间跨过的档；一跳跨多档要报全）
	nonisolated static func cycleMilestoneFinding(
		cycleCount: Int?,
		lastSeenCycles: Int,
		milestones: [Int] = defaultCycleMilestones
	) -> Finding? {
		guard let cycle = cycleCount, cycle > 0, lastSeenCycles >= 0 else { return nil }
		let crossed = milestones
			.filter { $0 > 0 && lastSeenCycles < $0 && cycle >= $0 }
			.sorted(by: >)
		guard let lowest = crossed.last else { return nil }
		let crossedList = crossed.map(String.init).joined(separator: "/")
		let extra = crossed.count > 1 ? "（已跨过 \(crossedList)）" : ""
		return Finding(
			kind: .cycleMilestone,
			notificationID: "cycle-milestone-\(lowest)",
			title: "电池循环次数达到 \(lowest)",
			body: "当前循环约 \(cycle) 次\(extra)。达到设计循环寿命前健康度逐步下降属正常，可在面板对照健康趋势。"
		)
	}
}
