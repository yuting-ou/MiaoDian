import Foundation

/// H2 老化趋势：到 80% 的外推必须诚实——估计 + 置信区间 + 双锚点（可溯源）。
/// 苹果标称约 1000 次循环到 80%，循环当量仅作第二估计锚，不是本机实测寿命。
nonisolated enum HealthAgingProjection {
	nonisolated static let minSpanDays: Double = 14
	nonisolated static let shortSpanDays: Double = 30
	nonisolated static let mediumSpanDays: Double = 90
	/// 标称：约 (100-80)/1000 = 0.02 个百分点/循环
	nonisolated static let percentPerCycle: Double = 0.02

	enum Method: String, Equatable, Sendable {
		case capacityOnly
		case dualAnchor
	}

	struct Result: Equatable, Sendable {
		let remainingDaysP50: Double
		let remainingDaysLow: Double
		let remainingDaysHigh: Double
		let spanDays: Double
		let sampleCount: Int
		let capacityDeclinePerDay: Double
		let cycleDeclinePerDay: Double?
		let method: Method
		let relativeBand: Double
	}

	/// 相对半宽：样本越短区间越宽（禁止假精确）
	nonisolated static func relativeBand(spanDays: Double) -> Double {
		if spanDays < shortSpanDays { return 0.45 }
		if spanDays <= mediumSpanDays { return 0.30 }
		return 0.20
	}

	nonisolated static func project(samples: [HealthSample]) -> Result? {
		guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return nil }
		let span = last.date.timeIntervalSince(first.date) / 86400
		guard span >= minSpanDays,
			  first.healthPercent > last.healthPercent,
			  last.healthPercent > 80
		else { return nil }

		let capDecline = Double(first.healthPercent - last.healthPercent) / span
		guard capDecline > 0 else { return nil }

		var cycleDecline: Double? = nil
		if let c0 = first.cycleCount, let c1 = last.cycleCount, c1 > c0 {
			let d = (Double(c1 - c0) / span) * percentPerCycle
			if d > 0 { cycleDecline = d }
		}

		let decline: Double
		let method: Method
		if let cycleDecline {
			decline = 0.5 * (capDecline + cycleDecline)
			method = .dualAnchor
		} else {
			decline = capDecline
			method = .capacityOnly
		}

		let p50 = Double(last.healthPercent - 80) / decline
		let w = relativeBand(spanDays: span)
		return Result(
			remainingDaysP50: p50,
			remainingDaysLow: p50 * (1 - w),
			remainingDaysHigh: p50 * (1 + w),
			spanDays: span,
			sampleCount: samples.count,
			capacityDeclinePerDay: capDecline,
			cycleDeclinePerDay: cycleDecline,
			method: method,
			relativeBand: w
		)
	}

	nonisolated static func formatSpan(days: Double) -> String {
		let months = Int((days / 30.0).rounded())
		if months < 1 { return "不足 1 个月" }
		var span = ""
		if months / 12 > 0 { span += "\(months / 12) 年" }
		if months % 12 > 0 { span += "\(months % 12) 个月" }
		if span.isEmpty { span = "\(months) 个月" }
		return span
	}

	/// 面板寿命句：强制「估计」+ 区间
	nonisolated static func displayLine(_ result: Result) -> String {
		let p50 = formatSpan(days: result.remainingDaysP50)
		let low = formatSpan(days: result.remainingDaysLow)
		let high = formatSpan(days: result.remainingDaysHigh)
		var line = "照此趋势，估计约 \(p50)后降至 80%（区间约 \(low)–\(high)）"
		if result.spanDays < shortSpanDays {
			line += "；样本偏短，区间更宽"
		}
		return line
	}

	nonisolated static func methodHelp(_ result: Result) -> String {
		var text = UsagePatternAnalyzer.projectionCaveat(spanDays: result.spanDays)
		switch result.method {
		case .dualAnchor:
			text += "；双锚点：容量斜率与循环当量各半（循环当量按标称 \(percentPerCycle)%/次，非你的电池实测）"
		case .capacityOnly:
			text += "；仅容量斜率（缺有效循环增量）"
		}
		text += String(format: "；相对区间 ±%.0f%%", result.relativeBand * 100)
		return text
	}
}
