import Foundation

// 充电习惯洞察：纯本地统计电源事件，学出"通常几点插电、几点拔"的规律，
// 据此给软性建议（不做充电限制那种危险操作，只提示）
nonisolated struct ChargingHabitInsight: Equatable, Sendable {
	let message: String
	let symbol: String
}

nonisolated enum ChargingHabitAnalyzer {
	// 至少这么多次插/拔样本才敢下结论，否则规律没意义
	private static let minSamples = 4
	// 长期插电的判定：最近几天插电占比都超过这个值
	private static let heavyACShare = 0.85

	// 综合近期电源事件 + 用电历史 + 当前状态，给一条最相关的建议；没把握就返回 nil
	static func analyze(
		events: [PowerEvent],
		dailyHistory: [DailyUsage],
		snapshot: BatterySnapshot,
		now: Date = Date(),
		calendar: Calendar = .current
	) -> ChargingHabitInsight? {
		// 场景一：长期插电党——最近至少 3 天且平均插电占比很高，提示"用一用"
		let withShare = dailyHistory.suffix(5).compactMap(\.acShare)
		if withShare.count >= 3 {
			let avg = withShare.reduce(0, +) / Double(withShare.count)
			if avg >= heavyACShare {
				return ChargingHabitInsight(
					message: "最近几天几乎全程插着电，偶尔用电池放到 50% 左右更利于电池保养",
					symbol: "powerplug.fill"
				)
			}
		}

		// 场景二：夜间充电规律——找出常见的插电时段，若当前正处于该时段且在充电，
		// 提示按习惯充到 80% 睡一晚够用
		if snapshot.isCharging, let habit = nightlyChargeHabit(events: events, calendar: calendar) {
			let hour = calendar.component(.hour, from: now)
			if habit.contains(hour) {
				return ChargingHabitInsight(
					message: "按你平时的作息，充到 80% 睡一晚通常就够用，不必非充满",
					symbol: "moon.stars.fill"
				)
			}
		}

		// 场景三：用电异常——近 7 天日均用电显著高于之前三周基线（>35%）时点一句
		if let anomaly = UsagePatternAnalyzer.drainAnomaly(dailyHistory: dailyHistory, todayKey: UsagePatternAnalyzer.dayKeyString(now)),
		   anomaly.recentAvg >= anomaly.baselineAvg * 1.35 {
			return ChargingHabitInsight(
				message: String(format: "最近一周日均用电 %.0f%%，比前三周（日均 %.0f%%）多出约 %.0f%%，可留意是哪里变了",
								anomaly.recentAvg, anomaly.baselineAvg, (anomaly.recentAvg / anomaly.baselineAvg - 1) * 100),
				symbol: "exclamationmark.triangle.fill"
			)
		}

		return nil
	}

	// 从插电事件里统计高频插电时段（返回小时集合）；样本不足返回 nil
	// "夜间"宽泛定义为 21 点~次日 2 点，落在此区间的插电才算"睡前充电"信号
	private static func nightlyChargeHabit(events: [PowerEvent], calendar: Calendar) -> Set<Int>? {
		let plugHours = events
			.filter { $0.kind == .pluggedIn }
			.map { calendar.component(.hour, from: $0.date) }
			.filter { $0 >= 21 || $0 <= 2 }
		guard plugHours.count >= minSamples else { return nil }
		return Set(plugHours)
	}

	// 充电器偏慢洞察：当前正在充电，但协商功率明显低于这只充电器的额定值，
	// 而用户手上还有一只额定更高、之前用过的充电器——提示换一只充得更快。
	// 典型场景：插了只 30W 的线/口，却用它充一台能吃 65W 的机器
	static func analyzeCharger(
		snapshot: BatterySnapshot,
		currentCharger: ChargerProfile?,
		knownChargers: [ChargerProfile]
	) -> ChargingHabitInsight? {
		guard snapshot.powerSource == .powerAdapter, snapshot.isCharging else { return nil }
		guard let currentCharger, let rated = currentCharger.ratedWatts, rated > 0 else { return nil }
		guard
			let voltageMV = snapshot.negotiatedVoltageMV,
			let currentMA = snapshot.negotiatedCurrentMA,
			voltageMV > 0, currentMA > 0
		else { return nil }

		let negotiated = Double(voltageMV) * Double(currentMA) / 1_000_000.0
		// 协商低于额定 60% 才叫"偏慢"，避免刚插上还没握手就误报
		guard negotiated < Double(rated) * 0.6 else { return nil }

		// 找一只用户用过的、额定更高的充电器
		guard let faster = knownChargers
			.filter({ ($0.ratedWatts ?? 0) > rated })
			.max(by: { ($0.ratedWatts ?? 0) < ($1.ratedWatts ?? 0) }),
			let fasterRated = faster.ratedWatts
		else { return nil }

		return ChargingHabitInsight(
			message: String(format: "当前协商仅 %.0fW（充电器额定 %dW），偏慢；你之前用过的 %@（%@）能充得更快",
							negotiated, rated, faster.name, "\(fasterRated)W"),
			symbol: "bolt.badge.clock"
		)
	}
}
