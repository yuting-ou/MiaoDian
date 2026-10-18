import Foundation

// 拆分 1b 第三刀：耗电异常 / 低电预判 / 温度骤升三台判定，从
// `BatteryAlertController` 抽出（纯逻辑，不碰 UN/defaults/时钟/monitor）。
//
// 为什么这三台：它们是剩余判定里逻辑最密的一组——耗电异常与低电预判共享同一个
// `DrainRateEstimate` 且 nil 语义分叉（插电清空 vs 睡眠重新积累），温度骤升带
// 一个跨调用的环形缓存（采样断档要清空）。三台原先都长在构造不出来的 UN 外壳里，
// 测试面零断言。
//
// 与 `ThresholdAlertEvaluators` 同族的不变量：**重置分支不受提醒开关挡**——
// 开关关着时边沿照常推进，否则「关提醒 → 离开状态 → 再开提醒」会顶着陈旧置位
// 吞掉本该发的那条。三台各有一条断言钉死。
//
// 本层只回答"该不该发"；正文里的应用名/格式化与"发送成功才置位"留给外壳。

// MARK: - 耗电异常：掉速过线提醒一次；回到线−5 以下或离开电池才重置

nonisolated struct HighDrainAlertEvaluator {
	/// 重置滞回：掉速要回落到 线−5%/h 以下才允许再次提醒，防止临界抖动反复轰炸
	static let resetMarginPerHour = 5.0

	struct Input: Equatable {
		/// 最近一次快照的电源状态（`evaluateHighDrain` 由掉电估算驱动，可能两拍快照之间到达）
		var powerSource: PowerSourceType
		/// nil = 估算器没给数
		var ratePerHour: Double?
		var thresholdPerHour: Int
		var isReminderEnabled: Bool
		var didNotify: Bool
	}

	struct Result: Equatable {
		var didNotify: Bool
		var shouldSend: Bool
	}

	static func evaluate(_ input: Input) -> Result {
		guard let rate = input.ratePerHour else {
			// 接上电源后估算器清空、发布 nil：视作离开异常状态，重置提醒。
			// 电池模式下的 nil（睡眠清空重新积累）不重置，防止一觉醒来被重复轰炸。
			if input.powerSource != .battery {
				return Result(didNotify: false, shouldSend: false)
			}
			return Result(didNotify: input.didNotify, shouldSend: false)
		}
		let threshold = Double(input.thresholdPerHour)
		let isAbnormal = input.powerSource == .battery && rate >= threshold
		if isAbnormal {
			guard !input.didNotify, input.isReminderEnabled else {
				return Result(didNotify: input.didNotify, shouldSend: false)
			}
			return Result(didNotify: input.didNotify, shouldSend: true)
		}
		if input.powerSource != .battery || rate < threshold - resetMarginPerHour {
			return Result(didNotify: false, shouldSend: false)
		}
		// 滞回带内：既不发也不重置
		return Result(didNotify: input.didNotify, shouldSend: false)
	}
}

// MARK: - 低电预判：未到警示线但按当前掉速将撞线，提前 45 分钟喊一声

nonisolated struct LowForecastAlertEvaluator {
	/// 距警示线不足这么多分钟就提前提醒
	static let leadMinutes = 45.0
	/// 缓冲超过 lead×2 才重置，避免在临界点反复横跳
	static let resetMultiplier = 2.0
	/// 低于这个掉速视为"几乎没在掉"，不参与预判（也避免除零后的离谱分钟数）
	static let minRatePerHour = 0.5

	struct Input: Equatable {
		var snapshot: BatterySnapshot
		var ratePerHour: Double?
		var thresholdPercent: Int
		var isReminderEnabled: Bool
		var didNotify: Bool
	}

	struct Result: Equatable {
		var didNotify: Bool
		/// 该发时带出距线分钟数，供外壳写正文（判定与格式化不各算一遍）
		var shouldSend: Bool
		var minutesToThreshold: Double?
	}

	static func evaluate(_ input: Input) -> Result {
		guard let soc = input.snapshot.stateOfChargePercent else {
			return Result(didNotify: input.didNotify, shouldSend: false, minutesToThreshold: nil)
		}
		let threshold = input.thresholdPercent
		// 接电、已进低电区、或估算消失（插电清空）都重置
		if input.snapshot.powerSource != .battery || soc <= threshold {
			return Result(didNotify: false, shouldSend: false, minutesToThreshold: nil)
		}
		guard let rate = input.ratePerHour, rate > minRatePerHour else {
			return Result(didNotify: input.didNotify, shouldSend: false, minutesToThreshold: nil)
		}
		let minutes = Double(soc - threshold) / rate * 60
		if minutes <= leadMinutes {
			guard !input.didNotify, input.isReminderEnabled else {
				return Result(didNotify: input.didNotify, shouldSend: false, minutesToThreshold: minutes)
			}
			return Result(didNotify: input.didNotify, shouldSend: true, minutesToThreshold: minutes)
		} else if minutes > leadMinutes * resetMultiplier {
			return Result(didNotify: false, shouldSend: false, minutesToThreshold: minutes)
		}
		// 缓冲带（45–90 分钟）：既不发也不重置
		return Result(didNotify: input.didNotify, shouldSend: false, minutesToThreshold: minutes)
	}
}

// MARK: - 温度骤升：5 分钟内涨 3°C 且已到 35°C 提醒；缓存是跨调用的值状态

nonisolated struct TempSurgeAlertEvaluator {
	static let windowSeconds: TimeInterval = 5 * 60
	/// 相邻两次采样超过这个间隔视为断档（睡过），缓存清空重来——跨睡眠的温差没意义
	static let gapResetSeconds: TimeInterval = 120
	/// 缓存保留窗比对比窗多 60s，保证窗口边缘的基线还在表里
	static let retentionSeconds: TimeInterval = windowSeconds + 60
	/// 窗口起点必须至少存在这么久，避免用一两个刚采的点算出"骤升"
	static let minBaselineAgeSeconds: TimeInterval = windowSeconds * 0.8
	static let deltaC = 3.0
	static let minC = 35.0
	/// 降温/回落这么多才重置边沿
	static let resetDeltaC = 1.0

	struct Sample: Equatable {
		var date: Date
		var celsius: Double
	}

	/// 跨调用持有的缓存与边沿（由外壳原样保存）
	struct State: Equatable {
		var recentTemps: [Sample]
		var didNotify: Bool
	}

	struct Input: Equatable {
		/// nil = 这一拍读不到温度：**缓存与边沿都不动**，等下一个有读数的快照
		var temperatureCelsius: Double?
		var now: Date
		var isReminderEnabled: Bool
		var state: State
	}

	struct Result: Equatable {
		var state: State
		var shouldSend: Bool
		/// 该发时带出窗口起点的温度，供外壳写正文
		var baselineCelsius: Double?
	}

	static func evaluate(_ input: Input) -> Result {
		guard let celsius = input.temperatureCelsius else {
			return Result(state: input.state, shouldSend: false, baselineCelsius: nil)
		}
		var state = input.state
		let now = input.now

		// 采样断档（睡过）则清空重来，跨睡眠的温差没意义
		if let last = state.recentTemps.last, now.timeIntervalSince(last.date) > gapResetSeconds {
			state.recentTemps.removeAll()
		}
		state.recentTemps.append(Sample(date: now, celsius: celsius))
		state.recentTemps.removeAll { now.timeIntervalSince($0.date) > retentionSeconds }

		// 找窗口起点（约 5 分钟前）的温度作对比
		guard let baseline = state.recentTemps.first(where: { now.timeIntervalSince($0.date) <= windowSeconds })
		else { return Result(state: state, shouldSend: false, baselineCelsius: nil) }
		guard now.timeIntervalSince(baseline.date) >= minBaselineAgeSeconds
		else { return Result(state: state, shouldSend: false, baselineCelsius: baseline.celsius) }
		let delta = celsius - baseline.celsius

		if delta >= deltaC, celsius >= minC {
			guard !state.didNotify, input.isReminderEnabled else {
				return Result(state: state, shouldSend: false, baselineCelsius: baseline.celsius)
			}
			return Result(state: state, shouldSend: true, baselineCelsius: baseline.celsius)
		} else if delta < resetDeltaC {
			state.didNotify = false
		}
		return Result(state: state, shouldSend: false, baselineCelsius: baseline.celsius)
	}
}
