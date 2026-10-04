import CoreGraphics
import Foundation

// 卡片"出现条件 + 声明高度"的判定（纯逻辑，进单元测试面）。
//
// 为什么要有它：`BatteryPopoverView.visibleCards` 用 74 行写了 17 张卡的出现条件与
// 高度公式，而 `UI/` 整目录不进测试编译面 —— 于是"这张卡该不该出现"和"高度够不够"
// 两件事在测试面上**一个信号都没有**。同一个错项目里已经犯过三次：今日用电
// （2.9.11 修）、体检卡与洞察卡（2.9.14 修），每次都是"内容长高了、声明没跟上"，
// 而且每次都靠人眼截图发现。
//
// 纪律（与 PanelColumnPlan / PanelCardHeights 同一套）：
// ① 只搬判定不搬状态：本文件不持有可观察对象、不读环境、不碰动画与几何；
//    视图仍持状态，只把"输入 → 显示哪些卡、各多高"这一步交出来；
// ② 泛型 ID 而非搬 CardID：CardID 是视图的 private 嵌套类型，搬进逻辑层会牵动布局
//    持久化与编辑态的 rawValue 契约。沿用 PanelColumnPlan.balanced<ID: Hashable> 的
//    做法——本文件对具体 ID 类型无依赖，由调用方传；
// ③ 高度常量仍由 PanelCardHeights 单一来源持有，这里只编排、不重写任何数值；
// ④ 折叠态统一 32pt，与旧 cardHeight 逐字一致。
//
// 注：本文件进测试编译面，注释里不要出现属性包装器字面量（测试/run_tests.sh 会按
// 字面把宏宿主整体排除，见该脚本的排除分支）。

/// 一张可显示的卡片：id + 声明高度
struct PanelCardEntry<ID: Hashable>: Equatable {
	let id: ID
	let height: CGFloat

	init(id: ID, height: CGFloat) {
		self.id = id
		self.height = height
	}
}

/// `visibleCards` 判定所需的全部输入。
///
/// 字段全必填、形状显式：漏传 = 编译错误。v2.9.16 收口 #20 之后定的口径就是
/// "参数表不许被抄第二遍"，所以这里不给"可省"留口子——不需要的维度传 0 / 空即可。
struct PanelCardVisibilityInput {
	// —— 开关与数据存在性 ——
	var enabledOptions: Set<DisplayOption> = []
	/// 折叠卡片的 `DisplayOption.rawValue` 集合
	var collapsedCards: Set<String> = []
	/// 头部充电信息行数（决定 powerInfo 卡高度；0 = 不显示该卡）
	var powerItemCount: Int = 0
	/// 头部电池信息行数（决定 batteryInfo 卡高度；0 = 不显示该卡）
	var batteryItemCount: Int = 0
	/// 健康曲线是否可见（健康度样本足够）
	var showsHealthCurve: Bool = false

	// —— 历史/监控数据的"有无"（只传计数与状态，不传对象）——
	var recentSessionCount: Int = 0
	var hasCheckup: Bool = false
	var checkupEstimatedInputs: [String] = []
	var batteryIdentityMeaningful: Bool = false
	var socJumpCount30d: Int = 0
	var habitInsightMessages: [String] = []
	var temperatureSampleCount: Int = 0
	/// 今日用电行；nil = 今日无记录
	var todayUsage: DailyUsage? = nil
	/// 今日用电卡的说明行高（由 DwellTracking 给出，与卡内说明行同源）
	var dailySummaryHeight: CGFloat = 0
	var dailyHistoryCount: Int = 0
	var hourlyDrainAccumulatedDays: Int = 0
	var socSampleCount: Int = 0
	var powerSampleCount: Int = 0
	/// 续航换算的资格：电池模式 + 有正掉电估算 + 有 SOC
	var runtimeScenarioEligible: Bool = false
	/// 续航换算的校准口径行是否为空（空则不额外占行）
	var runtimeCalibrationNoteEmpty: Bool = true
	var significantEnergyAppCount: Int = 0
	var weeklyAppEnergyCount: Int = 0
	var powerEventCount: Int = 0
	var bluetoothDeviceCount: Int = 0

	init() {}
}

/// 卡片可见性判定的单一入口。
///
/// 每张卡的"开关键 + 展开高 + ID"由调用方以闭包给出，本文件只负责**条件判定与
/// 高度计算**——条件逐字照搬 `visibleCards`（含 17 张卡的语义分簇顺序）。
enum PanelCardVisibility {
	/// 折叠态声明高（与旧 `cardHeight` 逐字一致）
	static let collapsedHeight: CGFloat = 32

	/// 折叠优先：命中折叠集合一律 32pt
	static func height(expanded: CGFloat, collapsed: Bool) -> CGFloat {
		collapsed ? collapsedHeight : expanded
	}

	/// 17 张卡的出现条件与声明高度。
	///
	/// - Parameters:
	///   - input: 全部判定输入
	///   - collapsed: 折叠集合（`DisplayOption.rawValue`）
	///   - spec: 每张卡的 (开关键, 展开高, ID)。用字典而非闭包传入，
	///          是为了让"哪张卡、什么键、多高"在一屏里可核对。
	/// - Returns: 按语义分簇顺序排列的可见卡片（顺序即渲染/配平顺序）
	static func entries<ID: Hashable>(
		input: PanelCardVisibilityInput,
		collapsed: Set<String>,
		spec: [String: (option: DisplayOption, expanded: CGFloat, id: ID)]
	) -> [PanelCardEntry<ID>] {
		var out: [PanelCardEntry<ID>] = []
		let on = input.enabledOptions

		@discardableResult
		func push(_ key: String, _ expanded: CGFloat) -> Bool {
			guard let s = spec[key] else { return false }
			guard on.contains(s.option) else { return false }
			out.append(PanelCardEntry(
				id: s.id,
				height: height(expanded: expanded, collapsed: collapsed.contains(s.option.rawValue))
			))
			return true
		}

		// —— 充电中：协议/档位/功率/充电器 + 这次和历史的充电记录 ——
		// 前两张（powerInfo/batteryInfo）不受 DisplayOption 开关约束，
		// 它们由头部信息行是否存在决定——与旧实现一致（功率行恒在，无开关）。
		if input.powerItemCount > 0, let s = spec["powerInfo"] {
			out.append(PanelCardEntry(id: s.id, height: height(
				expanded: 22 + 26 * CGFloat(input.powerItemCount),
				collapsed: collapsed.contains(s.option.rawValue))))
		}
		if input.recentSessionCount > 0 {
			push("chargeHistory", 50 + 40 * CGFloat(min(3, input.recentSessionCount)))
		}

		// —— 电池健康：状态/体检/身份证/保养建议/温度/趋势 ——
		if input.batteryItemCount > 0, let s = spec["batteryInfo"] {
			out.append(PanelCardEntry(id: s.id, height: height(
				expanded: 22 + 26 * CGFloat(input.batteryItemCount),
				collapsed: collapsed.contains(s.option.rawValue))))
		}
		if input.hasCheckup {
			// 出现条件与高度共用同一段解析：配平按"有估计项"给高、渲染却按另一个快照
			// 算成没这行——这个错在体检卡上犯过一次（v2.9.14）。
			push("checkup", PanelCardHeights.checkup(estimatedInputs: input.checkupEstimatedInputs))
		}
		if input.batteryIdentityMeaningful {
			let jumpExtra: CGFloat = input.socJumpCount30d > 0 ? 26 : 0
			push("batteryIdentity", 104 + jumpExtra)
		}
		if !input.habitInsightMessages.isEmpty {
			push("habitInsight", PanelCardHeights.habitInsight(messages: input.habitInsightMessages))
		}
		if input.temperatureSampleCount >= 2 {
			push("temperatureChart", 96)
		}
		if input.showsHealthCurve {
			push("healthTrend", 142)
		}

		// —— 用电行为：今日/日历/时段/24h/功耗/续航换算/高耗电 ——
		if let usage = input.todayUsage, usage.drainedPercent > 0 || usage.chargedPercent > 0 {
			// 高度与卡内说明行同源：说明行长出来了，配平就得看见它长高了
			push("dailySummary", input.dailySummaryHeight)
		}
		if input.dailyHistoryCount >= 3 {
			push("usageCalendar", 128)
		}
		if input.hourlyDrainAccumulatedDays >= 3 {
			push("hourlyDrain", 96)
		}
		if input.socSampleCount >= 2 {
			push("socChart", 120)
		}
		if input.powerSampleCount >= 2 {
			push("powerChart", 102)
		}
		if input.runtimeScenarioEligible {
			// 校准口径行会多占一行，配平高度给余量（不裁内容，只影响双列配平）
			let noteExtra: CGFloat = input.runtimeCalibrationNoteEmpty ? 0 : 16
			push("runtimeScenarios", 118 + noteExtra)
		}
		if let s = spec["energyApps"], on.contains(s.option) {
			let energyExtra = input.weeklyAppEnergyCount == 0
				? 0 : 22 + 20 * CGFloat(input.weeklyAppEnergyCount)
			out.append(PanelCardEntry(id: s.id, height: height(
				expanded: 44 + 26 * CGFloat(max(1, min(3, input.significantEnergyAppCount))) + energyExtra,
				collapsed: collapsed.contains(s.option.rawValue))))
		}

		// —— 外设与事件 ——
		if input.powerEventCount > 0 {
			push("powerEvents", 44 + 26 * CGFloat(min(6, input.powerEventCount)))
		}
		if input.bluetoothDeviceCount > 0, let s = spec["bluetooth"], on.contains(s.option) {
			out.append(PanelCardEntry(id: s.id, height: height(
				expanded: 40 + 34 * CGFloat(input.bluetoothDeviceCount),
				collapsed: collapsed.contains(s.option.rawValue))))
		}
		return out
	}
}
