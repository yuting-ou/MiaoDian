import Foundation

// 掉电速度估算：基于电池模式下的真实放电记录计算 %/小时
// 换到电源或开始充电后重置，避免混入充电数据
struct DrainRateEstimator {
	private struct Sample {
		let date: Date
		let percent: Int
	}
	
	private var samples: [Sample] = []
	
	// 至少积累 10 分钟数据才给出估算
	private static let minimumSpanSeconds: TimeInterval = 10 * 60
	// 只用最近 1 小时的数据，反映当前使用习惯
	private static let windowSeconds: TimeInterval = 60 * 60
	// 两次采样间隔超过这个值，说明系统睡眠过（正常后台轮询才 10 秒）
	private static let sleepGapSeconds: TimeInterval = 3 * 60
	
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
		
		samples.append(Sample(date: date, percent: percent))
		samples.removeAll { date.timeIntervalSince($0.date) > Self.windowSeconds }
	}
	
	func estimate() -> DrainRateEstimate? {
		guard let first = samples.first, let last = samples.last else { return nil }
		
		let span = last.date.timeIntervalSince(first.date)
		guard span >= Self.minimumSpanSeconds else { return nil }
		
		let dropped = first.percent - last.percent
		guard dropped >= 1 else { return nil }
		
		let percentPerHour = Double(dropped) / span * 3600
		
		var minutesRemaining: Int?
		if percentPerHour > 0.1 {
			minutesRemaining = Int(Double(last.percent) / percentPerHour * 60)
		}
		
		return DrainRateEstimate(
			percentPerHour: percentPerHour,
			estimatedMinutesRemaining: minutesRemaining
		)
	}
}
