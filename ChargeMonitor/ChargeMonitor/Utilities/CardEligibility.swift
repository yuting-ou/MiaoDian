import Foundation

// 卡片自定义布局·资格与预设层（目标模式 v1.15.0）。
// 模型/编辑器解耦的第一性落点：PanelLayout（PanelFlow.swift，华容网格 v4）仍是唯一契约，
// 本文件只补三样编辑器共用的纯函数——资格集 eligibleCards、预设 applyPreset、上下移 move——
// 设置窗口「卡片管理」与面板编辑模式都往同一模型写，互不重复实现。
// 注：列式 column(auto/left/right) 设计已被高度门实测否决（行式密铺出厂态超屏），
// v4 用「行配对 + 宽窄切换」表达列意图，本层不再引入列字段。

// MARK: - 布局卡身份

/// 布局卡的规范 id/标题：镜像 BatteryPopoverView.CardID（private 嵌套枚举，无法直接引用）。
/// rawValue 必须与面板 CardID 保持一致——normalize(known:) 对不一致是优雅降级
/// （多出的 id 被面板丢弃、缺失的 id 追加末尾单行），但同步才是正解。
nonisolated enum LayoutCard: String, CaseIterable, Codable, Sendable, Identifiable {
	case powerInfo, batteryInfo, checkup, dailySummary, socChart, healthTrend
	case powerChart, temperatureChart, bluetooth, chargeHistory, powerEvents, energyApps
	case usageCalendar, habitInsight, hourlyDrain
	case runtimeScenarios, batteryIdentity

	var id: String { rawValue }

	var title: String {
		switch self {
		case .powerInfo: return "充电协议与功率"
		case .batteryInfo: return "电池状态"
		case .checkup: return "电池体检"
		case .dailySummary: return "今日用电"
		case .socChart: return "24小时电量"
		case .healthTrend: return "健康度趋势"
		case .powerChart: return "功耗曲线"
		case .temperatureChart: return "温度曲线"
		case .bluetooth: return "蓝牙外设"
		case .chargeHistory: return "充电记录"
		case .powerEvents: return "电源事件"
		case .energyApps: return "高耗电应用"
		case .usageCalendar: return "用电日历"
		case .habitInsight: return "洞察"
		case .hourlyDrain: return "时段用电"
		case .runtimeScenarios: return "续航换算"
		case .batteryIdentity: return "电池身份证"
		}
	}

	/// 设置列表一行小注：这张卡现在有没有数据/为什么没出现
	var detail: String {
		switch self {
		case .powerInfo: return "协议、档位与实时功率"
		case .batteryInfo: return "电量、温度与健康度"
		case .checkup: return "健康度加权评分"
		case .dailySummary: return "今天用电与充入小结"
		case .socChart: return "最近 24 小时电量走势"
		case .healthTrend: return "每天一个健康度采样"
		case .powerChart: return "最近 5 分钟整机功耗"
		case .temperatureChart: return "最近 30 分钟电池温度"
		case .bluetooth: return "耳机、鼠标等外设电量"
		case .chargeHistory: return "最近几次充电记录"
		case .powerEvents: return "插拔电与睡眠唤醒时间线"
		case .energyApps: return "耗电大户排行"
		case .usageCalendar: return "按天展示用电强度"
		case .habitInsight: return "保养建议一句话"
		case .hourlyDrain: return "一天 24 小时用电热力图"
		case .runtimeScenarios: return "三种场景还能用多久"
		case .batteryIdentity: return "序列号与出厂信息"
		}
	}

	/// 折叠状态挂载的 DisplayOption（collapsedCards 存 option rawValue）；nil = 该卡不支持折叠
	var collapseOption: DisplayOption? {
		switch self {
		// 面板里只有这 11 张卡渲染折叠按钮（isCardCollapsed 在案）；
		// habitInsight 虽走 cardHeight 但无折叠 UI，设置里也不给开关
		case .powerInfo, .batteryInfo, .checkup, .bluetooth, .energyApps, .habitInsight: return nil
		case .dailySummary: return .dailySummary
		case .socChart: return .socChart
		case .healthTrend: return .healthTrend
		case .powerChart: return .powerChart
		case .temperatureChart: return .temperatureChart
		case .chargeHistory: return .chargeHistory
		case .powerEvents: return .powerEvents
		case .usageCalendar: return .usageCalendar
		case .hourlyDrain: return .hourlyDrainChart
		case .runtimeScenarios: return .runtimeScenarios
		case .batteryIdentity: return .batteryIdentity
		}
	}
}

// MARK: - 资格判定（eligibility）

/// 运行时数据在场事实：visibleCards 判定里「有没有数据」那一半的可注入快照。
/// 开关门（enabledOptions）不在这里——那是配置本身，直接传 AppConfiguration。
nonisolated struct CardEligibilityFacts: Equatable, Sendable {
	var hasPowerItems = false
	var hasBatteryItems = false
	var hasChargeHistory = false
	var hasCheckup = false
	var hasBatteryIdentity = false
	var hasHabitInsight = false
	var hasTemperatureSamples = false
	var showsHealthCurve = false
	var hasDailySummary = false
	var hasUsageCalendar = false
	var hasHourlyDrain = false
	var hasSOCSamples = false
	var hasPowerSamples = false
	var hasRuntimeScenarios = false
	var hasPowerEvents = false
	var hasBluetoothDevices = false
	// energyApps 无数据门：开关开着就出现（面板里带预热态），故无对应事实位

	static let allPresent: CardEligibilityFacts = CardEligibilityFacts(
		hasPowerItems: true, hasBatteryItems: true, hasChargeHistory: true, hasCheckup: true,
		hasBatteryIdentity: true, hasHabitInsight: true, hasTemperatureSamples: true, showsHealthCurve: true,
		hasDailySummary: true, hasUsageCalendar: true, hasHourlyDrain: true, hasSOCSamples: true,
		hasPowerSamples: true, hasRuntimeScenarios: true, hasPowerEvents: true, hasBluetoothDevices: true
	)
}

nonisolated enum CardEligibility {
	/// 资格集：开关门 ∧ 数据门，按面板语义阅读序输出（充电中 → 电池健康 → 用电行为 → 外设与事件）。
	/// 判定条件与 BatteryPopoverView.visibleCards 逐条同步（只取出现条件，不含高度）；
	/// 改面板出现条件时必须同步改这里——测试「默认布局==今日顺序」会守住顺序。
	static func eligibleCards(configuration: AppConfiguration, facts: CardEligibilityFacts) -> [LayoutCard] {
		let options = configuration.enabledOptions
		var result: [LayoutCard] = []
		if facts.hasPowerItems { result.append(.powerInfo) }
		if options.contains(.chargeHistory), facts.hasChargeHistory { result.append(.chargeHistory) }
		if facts.hasBatteryItems { result.append(.batteryInfo) }
		if options.contains(.batteryCheckup), facts.hasCheckup { result.append(.checkup) }
		if options.contains(.batteryIdentity), facts.hasBatteryIdentity { result.append(.batteryIdentity) }
		if options.contains(.habitInsight), facts.hasHabitInsight { result.append(.habitInsight) }
		if options.contains(.temperatureChart), facts.hasTemperatureSamples { result.append(.temperatureChart) }
		if options.contains(.healthTrend), facts.showsHealthCurve { result.append(.healthTrend) }
		if options.contains(.dailySummary), facts.hasDailySummary { result.append(.dailySummary) }
		if options.contains(.usageCalendar), facts.hasUsageCalendar { result.append(.usageCalendar) }
		if options.contains(.hourlyDrainChart), facts.hasHourlyDrain { result.append(.hourlyDrain) }
		if options.contains(.socChart), facts.hasSOCSamples { result.append(.socChart) }
		if options.contains(.powerChart), facts.hasPowerSamples { result.append(.powerChart) }
		if options.contains(.runtimeScenarios), facts.hasRuntimeScenarios { result.append(.runtimeScenarios) }
		if options.contains(.significantEnergyApps) { result.append(.energyApps) }
		if options.contains(.powerEvents), facts.hasPowerEvents { result.append(.powerEvents) }
		if options.contains(.bluetoothDevices), facts.hasBluetoothDevices { result.append(.bluetooth) }
		return result
	}

	/// 洞察卡资格：与面板 habitInsights 同一套分析器组合（面板那份是 private，这里供设置窗口复用）
	static func hasHabitInsight(
		events: [PowerEvent],
		dailyHistory: [DailyUsage],
		snapshot: BatterySnapshot,
		careHolding: Bool,
		careThresholdPercent: Int,
		drain: HourlyDrainStats,
		temp: HourlyTempStats,
		currentCharger: ChargerProfile?,
		knownChargers: [ChargerProfile]
	) -> Bool {
		let base = ChargingHabitAnalyzer.analyze(events: events, dailyHistory: dailyHistory, snapshot: snapshot)
		let heat = UsagePatternAnalyzer.heatUsageOverlapInsight(drain: drain, temp: temp)
			.map { ChargingHabitInsight(message: $0, symbol: "thermometer.sun.fill") }
		let charger = ChargingHabitAnalyzer.analyzeCharger(
			snapshot: snapshot, currentCharger: currentCharger, knownChargers: knownChargers
		)
		return !UsagePatternAnalyzer.chargingInsights(
			habitBase: base,
			careHolding: careHolding,
			careThresholdPercent: careThresholdPercent,
			heatOverlap: heat,
			chargerInsight: charger
		).isEmpty
	}
}

// MARK: - 预设

/// 卡片布局预设：只在资格集内生效，绝不强行显示空卡。
nonisolated enum LayoutPreset: String, CaseIterable, Identifiable, Sendable {
	case standard, minimal, charging, dataNerd

	var id: String { rawValue }

	var title: String {
		switch self {
		case .standard: return "默认（自动配平）"
		case .minimal: return "极简"
		case .charging: return "充电党"
		case .dataNerd: return "数据控"
		}
	}

	var detail: String {
		switch self {
		case .standard: return "回到贪心配平，位置交给系统"
		case .minimal: return "只留充电、电池、今日与 24 小时电量"
		case .charging: return "充电协议/记录/体检/事件优先"
		case .dataNerd: return "全部有数据的卡都显示"
		}
	}
}

nonisolated enum PanelPresets {
	/// 应用预设 → 新布局；nil = 默认预设（回自动模式，panelLayout 置空）。
	/// kept 白名单 ∩ 资格集按资格序成对落行；资格集内其余进 hidden；
	/// 资格集外的卡保持原状（不显示、也不由预设代用户表态）。
	static func apply(_ preset: LayoutPreset, eligible: [LayoutCard], base: PanelLayout?) -> PanelLayout? {
		guard preset != .standard else { return nil }
		let whitelist: [LayoutCard]
		switch preset {
		case .standard: return nil
		case .minimal: whitelist = [.powerInfo, .batteryInfo, .dailySummary, .socChart]
		case .charging: whitelist = [.powerInfo, .chargeHistory, .batteryInfo, .checkup, .dailySummary, .powerEvents, .habitInsight]
		case .dataNerd: whitelist = LayoutCard.allCases
		}
		let kept = eligible.filter { whitelist.contains($0) }
		let hiddenNow = eligible.filter { !whitelist.contains($0) }.map(\.rawValue)
		let eligibleIDs = Set(eligible.map(\.rawValue))
		let carriedHidden = (base?.hidden ?? []).filter { !eligibleIDs.contains($0) }
		return PanelLayout(rows: paired(kept), hidden: hiddenNow + carriedHidden)
	}

	/// 阅读序 → 行存储：两张一行，落单成宽行（设置编辑器播种/预设共用）
	static func paired(_ cards: [LayoutCard]) -> [[String]] {
		var rows: [[String]] = []
		var iterator = cards.makeIterator()
		while let first = iterator.next() {
			if let second = iterator.next() {
				rows.append([first.rawValue, second.rawValue])
			} else {
				rows.append([first.rawValue])
			}
		}
		return rows
	}

	/// 自动模式下行存储播种：按资格阅读序成对。设置编辑器里第一次改动（隐藏/移动）前调用，
	/// 语义对齐面板编辑入口的 alignColumns 播种（那边有会话冻结列，这边没有，用阅读序配对）。
	static func seed(eligible: [LayoutCard]) -> PanelLayout {
		PanelLayout(rows: paired(eligible))
	}
}

// MARK: - 上下移（设置列表用；面板拖拽走 insert，互不干扰）

extension PanelFlow {
	/// 阅读序上移/下移一步：与相邻卡原地换位置（行形态不变，成对还是成对）。
	/// 已在首/末或卡不在板上 → 原样返回（no-op，UI 据此禁用按钮）。
	nonisolated static func move(_ layout: PanelLayout, card: String, up: Bool) -> PanelLayout {
		let order = layout.effectiveRows.flatMap { $0 }
		guard let i = order.firstIndex(of: card) else { return layout }
		let j = up ? i - 1 : i + 1
		guard order.indices.contains(j) else { return layout }
		var l = layout
		let a = order[i], b = order[j]
		l.rows = l.effectiveRows.map { row in
			row.map { $0 == a ? b : ($0 == b ? a : $0) }
		}
		l.left = []
		l.right = []
		return l
	}
}
