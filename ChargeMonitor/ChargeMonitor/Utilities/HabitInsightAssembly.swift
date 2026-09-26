import Foundation

// 洞察卡的唯一组装出口（v2.9.16 收口「同一判断的第三份副本」这一族缺陷）。
//
// 为什么要有这一层：洞察卡的内容由六条来源汇成（习惯基线、保养暂停、热叠加、驻留、
// 存放、涓流）。此前面板 `habitInsights` 与各来源齐全地产出，而设置侧的资格判定
// `CardEligibility.hasHabitInsight` 自己另抄了一遍组装、**少传驻留/存放/涓流三条**——
// 后果：一台只有存放建议（或涓流、驻留）的机器，面板出着洞察卡而资格集判"无数据"。
// 预设的 hidden 只从资格集里挑，所以它不会被藏掉，而是**没落进 rows**：
// `PanelFlow.normalize` 把没落行的已知卡追加到行表尾，于是这张卡被甩到面板最底、独占整行，
// 并且因为不在资格集里，选「极简」也赶不走它。（症状我一度写成"卡片凭空消失"，审查更正过。）
//
// 规矩：**出现条件与卡片内容必须同出一个函数**。两侧都只许调 `assemble` / `hasAny`，
// 不再各自拼 chargingInsights 的参数表；再加来源时只改这一处。

/// 组装一条洞察卡所需的全部输入（纯数据，便于两侧同调与测试注入）
nonisolated struct HabitInsightInputs: Sendable {
	var events: [PowerEvent]
	var dailyHistory: [DailyUsage]
	var snapshot: BatterySnapshot
	/// 保养提醒正在被系统暂停按住（开关开 ∧ 当前处于暂缓态）
	var careHolding: Bool
	var careThresholdPercent: Int
	/// 我方静默是否真的生效过（决定文案能不能承诺"不再重复提醒"）。
	/// **故意不给默认值**：任务 #20 那条缺陷的机制就是"带默认值的参数会吞掉漏传"，
	/// 所以凡参与内容或资格判定的输入一律必填；唯一例外是下面那对测试注入的时钟，
	/// 其默认值与生产语义完全相同（nil → Date() / .current）。
	var careSilencedBySystemHold: Bool
	var drain: HourlyDrainStats
	var temp: HourlyTempStats
	var currentCharger: ChargerProfile?
	var knownChargers: [ChargerProfile]
	/// 驻留对比要按"今天"切 7 日窗口；生产留默认值，测试注入固定日历
	var today: Date?
	var calendar: Calendar?

	init(
		events: [PowerEvent],
		dailyHistory: [DailyUsage],
		snapshot: BatterySnapshot,
		careHolding: Bool,
		careThresholdPercent: Int,
		careSilencedBySystemHold: Bool,
		drain: HourlyDrainStats,
		temp: HourlyTempStats,
		currentCharger: ChargerProfile?,
		knownChargers: [ChargerProfile],
		today: Date? = nil,
		calendar: Calendar? = nil
	) {
		self.events = events
		self.dailyHistory = dailyHistory
		self.snapshot = snapshot
		self.careHolding = careHolding
		self.careThresholdPercent = careThresholdPercent
		self.careSilencedBySystemHold = careSilencedBySystemHold
		self.drain = drain
		self.temp = temp
		self.currentCharger = currentCharger
		self.knownChargers = knownChargers
		self.today = today
		self.calendar = calendar
	}

	/// 组装侧读这两条；测试注入固定日历后窗口不漂
	var resolvedToday: Date { today ?? Date() }
	var resolvedCalendar: Calendar { calendar ?? .current }
}

nonisolated enum HabitInsights {
	/// 六条来源 → 排序后的洞察列表（面板渲染吃这个）
	static func assemble(_ inputs: HabitInsightInputs) -> [ChargingHabitInsight] {
		let base = ChargingHabitAnalyzer.analyze(
			events: inputs.events,
			dailyHistory: inputs.dailyHistory,
			snapshot: inputs.snapshot,
			// 注入的时钟要一路转下去：只给驻留窗口注入，基线那条仍吃真实 Date()，
			// 夹具就会随钟漂（审查 round1 抓到"注入只通一半"）
			now: inputs.resolvedToday,
			calendar: inputs.resolvedCalendar
		)
		let heat = UsagePatternAnalyzer.heatUsageOverlapInsight(drain: inputs.drain, temp: inputs.temp)
			.map { ChargingHabitInsight(message: $0, symbol: "thermometer.sun.fill") }
		let charger = ChargingHabitAnalyzer.analyzeCharger(
			snapshot: inputs.snapshot,
			currentCharger: inputs.currentCharger,
			knownChargers: inputs.knownChargers
		)
		return UsagePatternAnalyzer.chargingInsights(
			habitBase: base,
			careHolding: inputs.careHolding,
			careThresholdPercent: inputs.careThresholdPercent,
			heatOverlap: heat,
			chargerInsight: charger,
			careSilencedBySystemHold: inputs.careSilencedBySystemHold,
			dwellInsight: DwellTracking.trackingInsight(
				history: inputs.dailyHistory,
				today: inputs.resolvedToday,
				calendar: inputs.resolvedCalendar
			),
			storageInsight: StorageGuide.advice(
				socPercent: inputs.snapshot.stateOfChargePercent,
				isOnAC: inputs.snapshot.powerSource == .powerAdapter
			).map { ChargingHabitInsight(message: $0, symbol: "archivebox.fill") },
			trickleInsight: TrickleNotice.liveNotice(
				socPercent: inputs.snapshot.stateOfChargePercent,
				isCharging: inputs.snapshot.isCharging
			)
		)
	}

	/// 资格判定吃这个：这张卡此刻有没有内容
	static func hasAny(_ inputs: HabitInsightInputs) -> Bool {
		!assemble(inputs).isEmpty
	}
}
