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
		guard let first = samples.first, let last = samples.last else { return nil }

		let span = last.date.timeIntervalSince(first.date)
		guard span >= Self.minimumSpanSeconds else { return nil }

		let dropped = first.percent - last.percent
		guard dropped >= 1 else { return nil }

		let percentPerHour = Double(dropped) / span * 3600

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
			estimatedMinutesRemaining: minutesRemaining
		)
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
