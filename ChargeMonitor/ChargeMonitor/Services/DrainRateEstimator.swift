import Foundation

// 掉电速度估算：基于电池模式下的真实放电记录计算 %/小时
// 换到电源或开始充电后重置，避免混入充电数据
// 剩余时间优先用库仑计数（窗口内平均放电电流 × 电池容量），百分比法兜底——
// 百分比受电量计量化噪声限制（1% 跳变就是几十分钟的误差），电流是连续量
struct DrainRateEstimator {
	private struct Sample {
		let date: Date
		let percent: Int
		// 电池端实时放电电流（mA，恒为正）与满充容量：库仑计数的原料
		let dischargeMA: Double?
		let maxCapacityMAh: Int?
	}

	private var samples: [Sample] = []

	// 至少积累 10 分钟数据才给出估算
	private static let minimumSpanSeconds: TimeInterval = 10 * 60
	// 只用最近 1 小时的数据，反映当前使用习惯
	private static let windowSeconds: TimeInterval = 60 * 60
	// 两次采样间隔超过这个值，说明系统睡眠过（正常后台轮询才 10 秒）
	private static let sleepGapSeconds: TimeInterval = 3 * 60
	// 库仑计数至少要这么多条电流读数，抗单帧抖动
	nonisolated private static let minAmperageSamples = 10

	// E4 窗口自适应默认参：突变时切到短窗，稳定时用满窗
	nonisolated static let adaptiveFullWindowSeconds: TimeInterval = 60 * 60
	nonisolated static let adaptiveMinSpanSeconds: TimeInterval = 10 * 60
	nonisolated static let adaptiveRecentSpanSeconds: TimeInterval = 15 * 60
	nonisolated static let adaptiveMinRecentSpanSeconds: TimeInterval = 8 * 60
	nonisolated static let adaptiveMutationRatio: Double = 0.35
	nonisolated static let adaptiveRateFloor: Double = 0.5
	// 绝对阈值：短窗判定另要求 recentDrop≥2，避免低基线下单次 1% 量化台阶算成假突变
	nonisolated static let adaptiveMutationAbsolute: Double = 4.0
	// 短窗最少掉电百分点：1% 量化噪声在低放电率+短窗上会算出虚高速率
	nonisolated static let adaptiveMinRecentDrop: Int = 2

	mutating func record(snapshot: BatterySnapshot, at date: Date = Date()) {
		guard snapshot.powerSource == .battery, !snapshot.isCharging else {
			samples.removeAll()
			return
		}
		guard let percent = snapshot.stateOfChargePercent else { return }

		if let last = samples.last {
			// 电量回升说明数据异常（如刚拔电源的瞬间），重新开始
			// 或距上次采样太久说明系统睡眠过——睡眠期间不采样，
			// 跨睡眠的时间差会把 %/小时严重算歪，一律清空重新积累
			if percent > last.percent || date.timeIntervalSince(last.date) > Self.sleepGapSeconds {
				samples.removeAll()
			}
		}

		// InstantAmperage 正充负放；只记放电电流，涓流/噪声进不来
		let dischargeMA: Double?
		if let ma = snapshot.batteryAmperageMA, ma < 0 {
			dischargeMA = Double(-ma)
		} else {
			dischargeMA = nil
		}
		samples.append(Sample(date: date, percent: percent, dischargeMA: dischargeMA, maxCapacityMAh: snapshot.maxCapacityMAh))
		samples.removeAll { date.timeIntervalSince($0.date) > Self.windowSeconds }
	}

	func estimate() -> DrainRateEstimate? {
		guard let last = samples.last else { return nil }
		let pairs = samples.map { (date: $0.date, percent: $0.percent) }
		guard let adaptive = Self.adaptivePercentPerHour(samples: pairs) else { return nil }
		let percentPerHour = adaptive.rate
		let windowSeconds = adaptive.windowSeconds

		// 剩余时间：库仑计数优先，原料不足退回百分比线性外推
		var minutesRemaining: Int? = Self.coulombMinutesRemaining(
			samples: samples.map { ($0.date, $0.dischargeMA, $0.maxCapacityMAh) },
			socPercent: last.percent
		)
		if minutesRemaining == nil, percentPerHour > 0.1 {
			minutesRemaining = Int(Double(last.percent) / percentPerHour * 60)
		}

		return DrainRateEstimate(
			percentPerHour: percentPerHour,
			estimatedMinutesRemaining: minutesRemaining,
			windowSeconds: Int(windowSeconds)
		)
	}

	/// E4 窗口自适应（纯函数）：稳定用满窗；负载突变时用短窗响应。
	/// 返回 rate 与实际采用的窗口秒数；样本不足/无掉电 → nil。
	nonisolated static func adaptivePercentPerHour(
		samples: [(date: Date, percent: Int)],
		fullWindow: TimeInterval = adaptiveFullWindowSeconds,
		minSpan: TimeInterval = adaptiveMinSpanSeconds,
		recentSpan: TimeInterval = adaptiveRecentSpanSeconds,
		minRecentSpan: TimeInterval = adaptiveMinRecentSpanSeconds,
		mutationRatio: Double = adaptiveMutationRatio,
		rateFloor: Double = adaptiveRateFloor,
		mutationAbsolute: Double = adaptiveMutationAbsolute,
		minRecentDrop: Int = adaptiveMinRecentDrop
	) -> (rate: Double, windowSeconds: TimeInterval)? {
		guard let end = samples.last?.date else { return nil }
		let fullSamples = samples.filter { end.timeIntervalSince($0.date) <= fullWindow }
		guard let first = fullSamples.first, let last = fullSamples.last else { return nil }
		let fullSpan = last.date.timeIntervalSince(first.date)
		let fullDrop = first.percent - last.percent
		var fullRate: Double?
		if fullSpan >= minSpan, fullDrop >= 1 {
			fullRate = Double(fullDrop) / fullSpan * 3600
		}

		let recentSamples = samples.filter { end.timeIntervalSince($0.date) <= recentSpan }
		var recentRate: Double?
		var recentSpanUsed: TimeInterval = 0
		if let rFirst = recentSamples.first, let rLast = recentSamples.last {
			recentSpanUsed = rLast.date.timeIntervalSince(rFirst.date)
			let recentDrop = rFirst.percent - rLast.percent
			// minRecentDrop≥2：低基线时 1% 台阶在短窗上可算出虚高 %/h（假突变）
			if recentSpanUsed >= minRecentSpan, recentDrop >= max(1, minRecentDrop) {
				recentRate = Double(recentDrop) / recentSpanUsed * 3600
			}
		}

		if let fullRate, let recentRate {
			let threshold = max(mutationRatio * max(abs(fullRate), rateFloor), mutationAbsolute)
			if abs(recentRate - fullRate) >= threshold {
				return (recentRate, recentSpanUsed)
			}
			return (fullRate, fullWindow)
		}
		if let fullRate {
			return (fullRate, fullWindow)
		}
		if let recentRate {
			return (recentRate, recentSpanUsed)
		}
		return nil
	}

	// 库仑计数的纯函数核心，供单测直测：剩余电荷（满充容量 × 电量）÷ 时间加权平均放电电流
	nonisolated static func coulombMinutesRemaining(
		samples: [(date: Date, dischargeMA: Double?, maxCapacityMAh: Int?)],
		socPercent: Int
	) -> Int? {
		let dischargeReadings = samples.compactMap(\.dischargeMA)
		guard dischargeReadings.count >= minAmperageSamples,
			let lastCapacity = samples.last?.maxCapacityMAh,
			lastCapacity > 0
		else { return nil }
		let capacity = lastCapacity

		// 按采样间隔加权平均：面板 2 秒/后台 10 秒/通知帧节奏混跑，等权会偏向高节奏时段
		var weightedSum = 0.0
		var weightTotal = 0.0
		for (index, sample) in samples.enumerated() {
			guard let dischargeMA = sample.dischargeMA else { continue }
			let nextTime = index + 1 < samples.count ? samples[index + 1].date : sample.date
			let weight = max(nextTime.timeIntervalSince(sample.date), 1)
			weightedSum += dischargeMA * weight
			weightTotal += weight
		}
		guard weightTotal > 0 else { return nil }
		let averageDischargeMA = weightedSum / weightTotal
		guard averageDischargeMA > 0 else { return nil }

		let remainingMAh = Double(capacity) * Double(socPercent) / 100
		let minutes = remainingMAh / averageDischargeMA * 60
		guard minutes > 0, minutes.isFinite else { return nil }
		// 兜底上限（约 7 天），防异常读数把估算带到荒谬区间
		return min(Int(minutes), 10_000)
	}
}
