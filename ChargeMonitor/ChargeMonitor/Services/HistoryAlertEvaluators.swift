import Foundation

// 拆分 1b 第六刀：睡眠掉电 / 电量计校准两台判定，从 `BatteryAlertController`
// 抽出（纯逻辑，不碰 UN/defaults/时钟）。
//
// 两台的共同点是**记录/事件驱动 + 持久化去重**：
// - 睡眠掉电按 wakeDate 去重，免打扰吞掉后靠新鲜度窗内的周期重试补发；
// - 电量计校准用时间冷却而不是边沿，且"发送成功才进冷却"——被免打扰吞掉时
//   不能空转 30 天。
// 两台都把"发送成功后要写什么"作为 Result 的独立出口，由外壳按 send 返回值执行。

// MARK: - 睡眠掉电：合盖 ≥1h、掉电 ≥5%、折算 ≥2%/h；同一觉只报一次

nonisolated struct SleepDrainAlertEvaluator {
	static let minMinutes = 60
	static let minPercent = 5
	static let minPerHour = 2.0
	/// 只对醒来后这段时间内的记录报警，启动时从磁盘捧出来的旧记录不算
	static let freshnessSeconds: TimeInterval = 8 * 3600

	struct Input: Equatable {
		var record: SleepDrainRecord
		var now: Date
		var lastAlertedWakeDate: Date?
		var isEnabled: Bool
		var isReportEnabled: Bool
	}

	struct Result: Equatable {
		var shouldSend: Bool
		/// 发送成功后才记的 wakeDate（同一觉去重）；nil = 不写
		var wakeDateToPersist: Date?
	}

	static func evaluate(_ input: Input) -> Result {
		guard input.isEnabled, input.isReportEnabled else {
			return Result(shouldSend: false, wakeDateToPersist: nil)
		}
		// 同一觉已报过不重发（重启后订阅会立刻回放磁盘里的旧记录）
		if let last = input.lastAlertedWakeDate, last == input.record.wakeDate {
			return Result(shouldSend: false, wakeDateToPersist: nil)
		}
		// 醒来超过新鲜窗口不报
		guard input.now.timeIntervalSince(input.record.wakeDate) < freshnessSeconds else {
			return Result(shouldSend: false, wakeDateToPersist: nil)
		}
		let qualifies = input.record.durationMinutes >= minMinutes
			&& input.record.droppedPercent >= minPercent
			&& input.record.dropPerHour >= minPerHour
		return Result(
			shouldSend: qualifies,
			wakeDateToPersist: qualifies ? input.record.wakeDate : nil
		)
	}
}

// MARK: - 电量计校准：30 天跳变攒够阈值提醒；冷却期内不重复，成功才进冷却

nonisolated struct GaugeCalibrationAlertEvaluator {
	static let cooldownSeconds: TimeInterval = 30 * 86400

	struct Input: Equatable {
		var jumpCount: Int
		var isEnabled: Bool
		var isReminderEnabled: Bool
		var lastAlerted: Date?
		var now: Date
	}

	struct Result: Equatable {
		var shouldSend: Bool
		/// 发送成功后才写入的冷却起点；nil = 不写
		var alertAtToPersist: Date?
	}

	static func evaluate(_ input: Input) -> Result {
		guard input.isEnabled, input.isReminderEnabled else {
			return Result(shouldSend: false, alertAtToPersist: nil)
		}
		guard UsagePatternAnalyzer.gaugeNeedsCalibration(jumpCount: input.jumpCount) else {
			return Result(shouldSend: false, alertAtToPersist: nil)
		}
		guard !isCooldownActive(
			lastAlerted: input.lastAlerted, now: input.now, cooldown: cooldownSeconds
		) else { return Result(shouldSend: false, alertAtToPersist: nil) }
		// 投递成功才进冷却——免打扰吞掉时不能空转 30 天；由外壳按 send 返回值写入
		return Result(shouldSend: true, alertAtToPersist: input.now)
	}

	/// 冷却判定：未来的冷却标记（时钟调快留下的）视为失效，否则时钟回拨后
	/// 这一条会被一个"来自未来的标记"永久静默（与周月报 digestSendAllowed 同族）。
	static func isCooldownActive(lastAlerted: Date?, now: Date, cooldown: TimeInterval) -> Bool {
		guard let lastAlerted else { return false }
		guard now >= lastAlerted else { return false }
		return now.timeIntervalSince(lastAlerted) < cooldown
	}
}
