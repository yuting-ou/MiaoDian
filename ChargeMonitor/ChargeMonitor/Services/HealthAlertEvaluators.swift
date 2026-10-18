import Foundation

// 拆分 1b 第四刀：健康里程碑与健康异常（降幅去重 / 循环里程碑写回）的判定，
// 从 `BatteryAlertController` 抽出（纯逻辑，不碰 UN/defaults/时钟）。
//
// 这两台的共同点是**持久化写回的时机就是判定本身**：
// - 里程碑基准在首次运行、读数回升、开关关着穿越时都要推进，只有"发送"那条
//   必须等 send 成功才落——写早了会把一次被免打扰吞掉的提醒永久吞掉；
// - 降幅提醒同一天只发一次，日键由调用方的时钟算好传入；
// - 循环里程碑的 seen 同样是发送成功才推进。
// 所以 evaluator 把"非发送路径要写什么"（milestoneToPersist）与"发送成功后才写什么"
// （shouldSend / cycleMilestoneToPersist）分成两个出口，外壳按 send 的返回值执行。

// MARK: - 健康度里程碑：跌破 90/85/80 各提醒一次；基准持久化防重启后重发

nonisolated struct HealthMilestoneAlertEvaluator {
	static let defaultMilestones = [90, 85, 80]

	struct Input: Equatable {
		var healthPercent: Int?
		var isReminderEnabled: Bool
		/// defaults 里读到的基准（0 = 从未写过）
		var storedMilestone: Int
		var milestones: [Int]
	}

	struct Result: Equatable {
		/// 非发送路径要推进的基准（首次运行 / 读数回升 / 开关关着穿越）；nil = 不写
		var milestoneToPersist: Int?
		var shouldSend: Bool
		var crossedMilestones: [Int]
		var lowestCrossed: Int?
		var healthPercent: Int?
	}

	static func evaluate(_ input: Input) -> Result {
		guard let health = input.healthPercent else {
			return Result(milestoneToPersist: nil, shouldSend: false,
				crossedMilestones: [], lowestCrossed: nil, healthPercent: nil)
		}
		let stored = input.storedMilestone
		guard stored > 0 else {
			// 首次运行只记基准不提醒：装上时已经 87% 的电池没必要补刀
			return Result(milestoneToPersist: health, shouldSend: false,
				crossedMilestones: [], lowestCrossed: nil, healthPercent: health)
		}
		guard health < stored else {
			// 健康度读数回升（校准波动）时抬高基准，保持"只在真跌破时提醒"
			return Result(
				milestoneToPersist: health > stored ? health : nil,
				shouldSend: false, crossedMilestones: [], lowestCrossed: nil, healthPercent: health
			)
		}
		// 一跳跨多档要报全：92→81 必须交代 90/85/80，不能只报最高档后把其余档静默吞掉
		let crossed = input.milestones.filter { stored > $0 && health <= $0 }.sorted(by: >)
		guard let lowest = crossed.last else {
			return Result(milestoneToPersist: nil, shouldSend: false,
				crossedMilestones: [], lowestCrossed: nil, healthPercent: health)
		}
		guard input.isReminderEnabled else {
			// 开关关着也要推进基准，避免打开后补报陈年穿越
			return Result(milestoneToPersist: health, shouldSend: false,
				crossedMilestones: crossed, lowestCrossed: lowest, healthPercent: health)
		}
		// 发送路径不在这里落基准：外壳只在 send 成功后写
		return Result(milestoneToPersist: nil, shouldSend: true,
			crossedMilestones: crossed, lowestCrossed: lowest, healthPercent: health)
	}
}

// MARK: - 健康异常：30 天降幅同日去重 + 循环里程碑 seen 写回

nonisolated struct HealthAnomalyAlertEvaluator {
	struct Input: Equatable {
		/// 降幅检测结果（由 HealthAnomalyDetector 算出；nil = 无异常）
		var declineFinding: HealthAnomalyDetector.Finding?
		/// 上次成功提醒的日键（nil = 从未提醒过）
		var lastDeclineNotifiedDay: String?
		/// 今天的日键（由调用方的注入时钟/日历算好）
		var todayDayKey: String
		/// 循环里程碑检测结果
		var cycleFinding: HealthAnomalyDetector.Finding?
		/// 当前循环数（循环提醒发送成功后推进 seen 用）
		var cycleCount: Int?
	}

	struct Result: Equatable {
		var declineToSend: HealthAnomalyDetector.Finding?
		var cycleToSend: HealthAnomalyDetector.Finding?
		/// 循环提醒发送成功后才推进的 seen（nil = 不推进）
		var cycleMilestoneToPersist: Int?
	}

	static func evaluate(_ input: Input) -> Result {
		let decline: HealthAnomalyDetector.Finding?
		if let finding = input.declineFinding,
		   input.lastDeclineNotifiedDay != input.todayDayKey {
			decline = finding
		} else {
			decline = nil
		}
		return Result(
			declineToSend: decline,
			cycleToSend: input.cycleFinding,
			cycleMilestoneToPersist: input.cycleFinding == nil ? nil : input.cycleCount
		)
	}

	/// 降幅提醒的去重键：同一天只发一次。
	/// 日历由调用方注入，测试不得自己抄第二份日键格式（与 DailyUsageRecorder.dayKey 同一条纪律）。
	nonisolated static func dayKey(date: Date, calendar: Calendar = .current) -> String {
		let c = calendar.dateComponents([.year, .month, .day], from: date)
		return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
	}
}
