import Foundation

// 拆分 1b 第五刀：外设低电 / 充满预告 / 慢充三台的判定，从 `BatteryAlertController`
// 抽出（纯逻辑，不碰 UN/defaults/时钟）。
//
// 三台各自有一条容易在拆分中被"顺手简化"的语义：
// - 外设低电是**每设备独立**的集合边沿：开关关着时整台机器不动（连重置都不做，
//   与边沿族"重置不受开关挡"不同）；发送成功才把设备记进集合，免打扰吞掉后下一轮补发。
// - 充满预告只在**真拔电**时重置：优化充电在 80% 暂停/恢复不算新一次充电。
// - 慢充的重置看**电源**且早于提醒开关：开关关着拔电也要清掉已提醒边沿。
//
// 本层只回答"该发什么"；正文格式化与"发送成功才提交状态"留给外壳。

// MARK: - 外设低电：每设备独立边沿；充回阈值 +5 以上才允许再次提醒

nonisolated struct DeviceLowAlertEvaluator {
	/// 回升滞回：充回阈值 +5 以上才移除已提醒标记，避免临界百分比反复提醒
	static let resetMarginPercent = 5

	struct Input: Equatable {
		var devices: [BluetoothDeviceBattery]
		var thresholdPercent: Int
		var isReminderEnabled: Bool
		var notifiedDevices: Set<String>
	}

	struct Result: Equatable {
		/// 处理完回升重置后的集合（外壳先写回，再对 devicesToNotify 逐个发送）
		var notifiedDevices: Set<String>
		/// 本次该发的设备（保持输入顺序）；发送成功的由外壳逐个记入集合
		var devicesToNotify: [BluetoothDeviceBattery]
	}

	static func evaluate(_ input: Input) -> Result {
		guard input.isReminderEnabled else {
			// 开关关着：整台机器不动（重置也不做），与边沿族的"重置不受开关挡"不同
			return Result(notifiedDevices: input.notifiedDevices, devicesToNotify: [])
		}
		var notified = input.notifiedDevices
		var toNotify: [BluetoothDeviceBattery] = []
		for device in input.devices {
			if device.percent <= input.thresholdPercent, device.percent > 0 {
				// 0% 是"读不到"的哨兵，不当低电报
				if !notified.contains(device.name) {
					toNotify.append(device)
				}
			} else if device.percent >= input.thresholdPercent + resetMarginPercent {
				notified.remove(device.name)
			}
		}
		return Result(notifiedDevices: notified, devicesToNotify: toNotify)
	}
}

// MARK: - 充满预告：插电开充后预告一次几时充满；只有真拔电才重置

nonisolated struct FullForecastAlertEvaluator {
	/// 预计充满不足这么多分钟就不预告（已经在眼前，没意义）
	static let minForecastMinutes = 10

	struct Input: Equatable {
		var snapshot: BatterySnapshot
		var isReminderEnabled: Bool
		var didNotify: Bool
	}

	struct Result: Equatable {
		var didNotify: Bool
		var shouldSend: Bool
		/// 该发时的预计充满分钟数，供外壳写正文
		var minutes: Int?
	}

	static func evaluate(_ input: Input) -> Result {
		if input.snapshot.powerSource != .powerAdapter {
			// 只有真拔电才重置：优化充电在 80% 暂停/恢复不算新一次充电
			return Result(didNotify: false, shouldSend: false, minutes: nil)
		}
		guard input.snapshot.isCharging, !input.snapshot.isFull,
			  let minutes = input.snapshot.timeToFullChargeMinutes, minutes >= minForecastMinutes
		else { return Result(didNotify: input.didNotify, shouldSend: false, minutes: nil) }
		guard !input.didNotify, input.isReminderEnabled else {
			return Result(didNotify: input.didNotify, shouldSend: false, minutes: minutes)
		}
		return Result(didNotify: input.didNotify, shouldSend: true, minutes: minutes)
	}
}

// MARK: - 慢充：协商功率低于额定 55% 提醒一次；拔电即重置（早于开关）

nonisolated struct SlowChargeAlertEvaluator {
	static let ratio = 0.55
	/// 额定低于这个值的充电器不判慢充（小功率头本来就不快）
	static let minRatedWatts = 10

	struct Input: Equatable {
		var snapshot: BatterySnapshot
		var isReminderEnabled: Bool
		var didNotify: Bool
	}

	struct Result: Equatable {
		var didNotify: Bool
		var shouldSend: Bool
		/// 该发时的协商功率与额定功率，供外壳写正文
		var negotiatedWatts: Double?
		var ratedWatts: Int?
	}

	static func evaluate(_ input: Input) -> Result {
		guard input.snapshot.powerSource == .powerAdapter else {
			// 拔电即重置——这一条必须早于提醒开关（开关关着拔电也要清边沿）
			return Result(didNotify: false, shouldSend: false, negotiatedWatts: nil, ratedWatts: nil)
		}
		guard input.isReminderEnabled else {
			return Result(didNotify: input.didNotify, shouldSend: false, negotiatedWatts: nil, ratedWatts: nil)
		}
		guard
			input.snapshot.isCharging, !input.snapshot.isFull,
			let rated = input.snapshot.adapterRatedWatts, rated >= minRatedWatts,
			let voltageMV = input.snapshot.negotiatedVoltageMV,
			let currentMA = input.snapshot.negotiatedCurrentMA,
			voltageMV > 0, currentMA > 0
		else {
			return Result(didNotify: input.didNotify, shouldSend: false, negotiatedWatts: nil, ratedWatts: nil)
		}
		let watts = Double(voltageMV) * Double(currentMA) / 1_000_000.0
		guard watts < Double(rated) * ratio else {
			return Result(didNotify: input.didNotify, shouldSend: false, negotiatedWatts: watts, ratedWatts: rated)
		}
		guard !input.didNotify else {
			return Result(didNotify: input.didNotify, shouldSend: false, negotiatedWatts: watts, ratedWatts: rated)
		}
		return Result(didNotify: input.didNotify, shouldSend: true, negotiatedWatts: watts, ratedWatts: rated)
	}
}
