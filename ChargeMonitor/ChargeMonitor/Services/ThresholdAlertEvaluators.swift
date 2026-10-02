import Foundation

// 拆分 1b 第二刀：三条最简单的边沿提醒（充满／低电量／高温）的状态判定，从
// `BatteryAlertController` 抽出（纯逻辑，不碰 UN/defaults/时钟）。
//
// 为什么先搬这三条：它们是同一族"进入状态提醒一次、离开后重置"的边沿机器，
// 判定只依赖 snapshot 的两个读数与一个阈值——是最能验证"chargeCare 那套外壳形状
// 可以照抄推广"的样本。逻辑更密的（耗电异常／温度骤升／周月报）等这个形状站稳再搬。
//
// **判定侧真正的不可测面只有 UN 那 8 处触碰点**（见 AGENTS），这三台的语义此前
// 在测试面里零断言：滞回带、"重置不受提醒开关挡"、缺读数不动边沿——全部长在
// Controller 这个构造不出来的壳里。搬出来后第一次可测。
//
// 与保养不变量①同族、也最像"可以顺手简化"的一条语义，三台机器都成立：
// **重置分支不受提醒开关挡**——开关关着时边沿照常推进（置位才需要开关开着），
// 否则「关提醒 → 状态离开 → 再开提醒」会顶着陈旧的置位吞掉本该发的那条。
// （chargeCare 那台的同族不变量见 `ChargeCareAlertEvaluator` 头注释。）

// MARK: - 充满提醒：插电且已满提醒一次，拔电或未满即重置（无滞回）

nonisolated struct FullChargeAlertEvaluator {
	struct Input: Equatable {
		var snapshot: BatterySnapshot
		var isReminderEnabled: Bool
		var didNotify: Bool
	}

	struct Result: Equatable {
		var didNotify: Bool
		var shouldSend: Bool
	}

	static func evaluate(_ input: Input) -> Result {
		let isFullOnAdapter = input.snapshot.powerSource == .powerAdapter && input.snapshot.isFull
		// 拔电或未满：一律重置（无滞回——"拔了又插满"是再次提醒的正当场景）
		guard isFullOnAdapter else { return Result(didNotify: false, shouldSend: false) }
		guard !input.didNotify, input.isReminderEnabled else {
			return Result(didNotify: input.didNotify, shouldSend: false)
		}
		return Result(didNotify: input.didNotify, shouldSend: true)
	}
}

// MARK: - 低电量提醒：电池供电且过线提醒一次；回升出滞回带或接电才重置

nonisolated struct LowBatteryAlertEvaluator {
	/// 重置滞回：回升到警示线 +5% 以上才允许再次提醒。
	/// 没有这条带，临界电量（恰好压线的机器）会在"提醒→回升 1%→重置→又提醒"里反复轰炸
	static let resetMarginPercent = 5

	struct Input: Equatable {
		var snapshot: BatterySnapshot
		var thresholdPercent: Int
		var isReminderEnabled: Bool
		var didNotify: Bool
	}

	struct Result: Equatable {
		var didNotify: Bool
		var shouldSend: Bool
	}

	static func evaluate(_ input: Input) -> Result {
		// 缺 SOC 读数：边沿不判（置位与重置都不动），等下一个有读数的快照
		guard let soc = input.snapshot.stateOfChargePercent else {
			return Result(didNotify: input.didNotify, shouldSend: false)
		}
		let threshold = input.thresholdPercent
		if input.snapshot.powerSource == .battery, soc <= threshold {
			guard !input.didNotify, input.isReminderEnabled else {
				return Result(didNotify: input.didNotify, shouldSend: false)
			}
			return Result(didNotify: input.didNotify, shouldSend: true)
		} else if input.snapshot.powerSource == .powerAdapter || soc >= threshold + resetMarginPercent {
			// 接电即重置；纯电池下要升出滞回带才重置（带内保持置位，防临界横跳）
			return Result(didNotify: false, shouldSend: false)
		}
		// 滞回带内：既不发也不重置
		return Result(didNotify: input.didNotify, shouldSend: false)
	}
}

// MARK: - 高温提醒：过线提醒一次；降回线 −2°C 以下才重置

nonisolated struct HighTemperatureAlertEvaluator {
	/// 重置滞回：降回警示线 −2°C 以下才重置，线附近 ±2°C 的抖动不反复提醒
	static let resetMarginCelsius = 2.0

	struct Input: Equatable {
		var snapshot: BatterySnapshot
		var thresholdCelsius: Int
		var isReminderEnabled: Bool
		var didNotify: Bool
	}

	struct Result: Equatable {
		var didNotify: Bool
		var shouldSend: Bool
	}

	static func evaluate(_ input: Input) -> Result {
		// 缺温度读数：边沿不判，等下一个有读数的快照
		guard let temperature = input.snapshot.temperatureC else {
			return Result(didNotify: input.didNotify, shouldSend: false)
		}
		let threshold = Double(input.thresholdCelsius)
		if temperature >= threshold {
			guard !input.didNotify, input.isReminderEnabled else {
				return Result(didNotify: input.didNotify, shouldSend: false)
			}
			return Result(didNotify: input.didNotify, shouldSend: true)
		} else if temperature < threshold - resetMarginCelsius {
			// 严格小于：恰好压在 −2°C 整点上不算降出来（与搬运前逐字一致）
			return Result(didNotify: false, shouldSend: false)
		}
		// 滞回带内：既不发也不重置
		return Result(didNotify: input.didNotify, shouldSend: false)
	}
}
