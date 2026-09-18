import Foundation

/// E1 睡眠耗电分析：对**多次**合盖记录做聚合与元凶排行。
/// 只建议、不动作（不杀进程、不改系统设置）。样本不足沉默。
nonisolated enum SleepDrainAnalytics {
	nonisolated struct Analysis: Equatable, Sendable {
		let sampleCount: Int
		let avgPercentPerHour: Double
		let maxPercentPerHour: Double
		let topCulprits: [String]
		let advice: String?
	}

	nonisolated static let minDurationMinutes = 60
	nonisolated static let minDroppedPercent = 1
	nonisolated static let defaultMinSamples = 3
	nonisolated static let defaultMaxAgeDays: Double = 14
	nonisolated static let heavyPerHour = 2.0
	nonisolated static let mildPerHour = 1.2

	nonisolated static func eligibleRecords(
		_ records: [SleepDrainRecord],
		now: Date = Date(),
		maxAgeDays: Double = defaultMaxAgeDays
	) -> [SleepDrainRecord] {
		let cutoff = now.addingTimeInterval(-maxAgeDays * 86400)
		return records.filter {
			$0.wakeDate >= cutoff
				&& $0.durationMinutes >= minDurationMinutes
				&& $0.droppedPercent >= minDroppedPercent
		}
	}

	nonisolated static func culpritRanking(_ records: [SleepDrainRecord], limit: Int = 3) -> [String] {
		var counts: [String: Int] = [:]
		for r in records {
			for name in r.culpritNames ?? [] where !name.isEmpty {
				counts[name, default: 0] += 1
			}
		}
		return counts
			.sorted { lhs, rhs in
				if lhs.value != rhs.value { return lhs.value > rhs.value }
				return lhs.key < rhs.key
			}
			.prefix(limit)
			.map(\.key)
	}

	nonisolated static func analyze(
		records: [SleepDrainRecord],
		now: Date = Date(),
		maxAgeDays: Double = defaultMaxAgeDays,
		minSamples: Int = defaultMinSamples
	) -> Analysis? {
		let eligible = eligibleRecords(records, now: now, maxAgeDays: maxAgeDays)
		guard eligible.count >= minSamples else { return nil }
		let rates = eligible.map(\.dropPerHour)
		let avg = rates.reduce(0, +) / Double(rates.count)
		let maxRate = rates.max() ?? avg
		let culprits = culpritRanking(eligible)
		return Analysis(
			sampleCount: eligible.count,
			avgPercentPerHour: avg,
			maxPercentPerHour: maxRate,
			topCulprits: culprits,
			advice: advice(avgPerHour: avg, culprits: culprits)
		)
	}

	nonisolated static func advice(avgPerHour: Double, culprits: [String]) -> String {
		let rateText = String(format: "%.1f%%/小时", avgPerHour)
		if avgPerHour >= heavyPerHour {
			var text = "近期合盖掉电偏快（约 \(rateText)）"
			if !culprits.isEmpty {
				let names = culprits.prefix(2).joined(separator: "、")
				text += "；多次出现的阻止睡眠进程：\(names)（可在活动监视器查看）"
			}
			text += "——妙电只提示，不会替你结束进程"
			return text
		}
		if avgPerHour >= mildPerHour {
			var text = "近期睡眠掉电略偏快（约 \(rateText)）"
			if !culprits.isEmpty {
				text += "；元凶倾向：\(culprits.prefix(2).joined(separator: "、"))"
			}
			return text
		}
		return "近期睡眠掉电大致正常（约 \(rateText)）"
	}

	/// 面板悬停/报告用一行摘要；无分析时 nil
	nonisolated static func summaryLine(_ analysis: Analysis?) -> String? {
		guard let analysis else { return nil }
		return analysis.advice
	}
}
