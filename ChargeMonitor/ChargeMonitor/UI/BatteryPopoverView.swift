import AppKit
import SwiftUI

struct BatteryPopoverView: View {
	@ObservedObject var monitor: BatteryMonitor
	@ObservedObject var configurationManager: ConfigurationManager
	@ObservedObject var historyRecorder: BatteryHistoryRecorder
	@ObservedObject var alertController: BatteryAlertController
	// 面板"设置"行打开独立设置窗口
	@Environment(\.openSettings) private var openSettings
	// 充电记录行打开独立曲线窗口（不用 sheet：会连带弹窗窗口跳动）
	@Environment(\.openWindow) private var openWindow
	
	// 面板打开期间已分好列的卡片：后到的新卡只追加到较矮列，已有卡不滑动不换位，
	// 避免曲线数据陆续到位时整个面板在眼皮底下洗牌；关闭面板后清空，下次打开重新配平
	@State private var assignedLeft: [CardID] = []
	@State private var assignedRight: [CardID] = []
	// 入场动画开关：面板打开时从 false→true 驱动淡入上滑，关闭时复位供下次重播
	@State private var didAppear = false
	// 首次打开播错峰级联，之后每次打开整块淡入（高频开关面板不看腻）
	@State private var playCascade = false
	// "复制报告"的行内成功反馈
	@State private var reportCopied = false
	// "本会话只播一次级联"挂类型上：面板每次打开销毁重建，@State 撑不住跨打开
	private static var hasPlayedCascade = false
	
	var body: some View {
		let configuration = configurationManager.configuration
		// 健康趋势曲线能显示时，信息行里的文字版趋势就不再重复展示
		let showsHealthCurve = configuration.enabledOptions.contains(.healthTrend) && historyRecorder.healthSamples.count >= 2
		let formatter = BatteryInfoFormatter(
			snapshot: monitor.snapshot,
			configuration: configuration,
			drainEstimate: monitor.drainEstimate,
			healthTrend: showsHealthCurve ? nil : historyRecorder.healthTrend,
			sleepDrain: historyRecorder.lastSleepDrain,
			chargerProfile: historyRecorder.currentChargerProfile,
			chargerStats: historyRecorder.currentChargerPowerStats,
			omitsTimeEstimates: true
		)
		let powerItems = formatter.makeItems(in: .power)
		let batteryItems = formatter.makeItems(in: .battery)
		// 按预估高度枚举当前可见卡片；≥ 5 张就拉宽面板双列，否则窄单列
		let cards = visibleCards(configuration, showsHealthCurve: showsHealthCurve, powerItems: powerItems, batteryItems: batteryItems)
		let twoColumns = cards.count >= 5
		// 宽面板时体检评分搬进头部右侧的空白区，不再占卡片位
		let checkup = configuration.enabledOptions.contains(.batteryCheckup) ? BatteryCheckup.evaluate(
			healthPercent: monitor.snapshot.healthPercent,
			cycleCount: monitor.snapshot.cycleCount,
			temperatureC: monitor.snapshot.temperatureC,
			highSocDwellShare: historyRecorder.todayUsage?.highSocDwellShare
		) : nil
		let displayCards = twoColumns ? cards.filter { $0.id != .checkup } : cards
		let cardIDs = displayCards.map(\.id)
		// 预先算好分列与“控制行”的级联档位（供入场错峰动画与 onAppear 固化共用）
		let split = mergedColumns(displayCards, left: assignedLeft, right: assignedRight)
		let controlStep = (twoColumns ? max(split.left.count, split.right.count) : cardIDs.count) + 1
		
		VStack(alignment: .leading, spacing: 8) {
			BatteryHeaderView(
				snapshot: monitor.snapshot,
				drainEstimate: monitor.drainEstimate,
				lowBatteryThreshold: configuration.lowBatteryThresholdPercent,
				checkup: twoColumns ? checkup : nil
			)
			.modifier(CascadeIn(step: 0, active: didAppear))

			if twoColumns {
				// 头部续航横幅之下用一条细分隔线收口，再分左右两列
				Divider()
					.modifier(CascadeIn(step: cascadeStep(1), active: didAppear))
				HStack(alignment: .top, spacing: 10) {
					VStack(alignment: .leading, spacing: 8) {
						ForEach(Array(split.left.enumerated()), id: \.element) { index, id in
							cardView(id, powerItems: powerItems, batteryItems: batteryItems, configuration: configuration, showsHealthCurve: showsHealthCurve)
								.modifier(CascadeIn(step: cascadeStep(index + 1), active: didAppear))
						}
					}
					.frame(maxWidth: .infinity, alignment: .topLeading)

					VStack(alignment: .leading, spacing: 8) {
						ForEach(Array(split.right.enumerated()), id: \.element) { index, id in
							cardView(id, powerItems: powerItems, batteryItems: batteryItems, configuration: configuration, showsHealthCurve: showsHealthCurve)
								.modifier(CascadeIn(step: cascadeStep(index + 1), active: didAppear))
						}
					}
					.frame(maxWidth: .infinity, alignment: .topLeading)
				}
			} else {
				ForEach(Array(cardIDs.enumerated()), id: \.element) { index, id in
					cardView(id, powerItems: powerItems, batteryItems: batteryItems, configuration: configuration, showsHealthCurve: showsHealthCurve)
						.modifier(CascadeIn(step: cascadeStep(index + 1), active: didAppear))
				}
			}

			Divider()
				.modifier(CascadeIn(step: cascadeStep(controlStep), active: didAppear))

			controlRows
				.modifier(CascadeIn(step: cascadeStep(controlStep), active: didAppear))
		}
		.padding(.horizontal, 12)
		.padding(.top, 12)
		.padding(.bottom, 8)
		.frame(width: twoColumns ? 584 : 292)
		// 容器只留一层极快的背景淡入（纯 opacity，不做 scale 避免与内部 CascadeIn 的缩放叠加）；
		// “浮现”观感完全交给内部各块的级联动画，单一时序才不会两套动画叠加相互干扰
		.opacity(didAppear ? 1 : 0)
		.animation(.easeOut(duration: 0.15), value: didAppear)
		.onAppear {
			monitor.startPolling()
			// 用户可能刚在系统设置里改过通知权限，每次打开面板重新查
			alertController.refreshAuthorizationStatus()
			let next = mergedColumns(displayCards, left: assignedLeft, right: assignedRight)
			assignedLeft = next.left
			assignedRight = next.right
			// 本会话第一次打开播错峰级联，之后 cascadeStep 全归零、整块同时落位
			playCascade = !Self.hasPlayedCascade
			Self.hasPlayedCascade = true
			// 置 true 触发入场：容器自带淡入动画，内部各块由 CascadeIn 按档位落位
			didAppear = true
		}
		.onChange(of: cardIDs) {
			// 卡片增减时把最新分列结果固化下来，已有卡片的归属不变
			let configuration = configurationManager.configuration
			let showsHealthCurve = configuration.enabledOptions.contains(.healthTrend) && historyRecorder.healthSamples.count >= 2
			let cards = visibleCards(configuration, showsHealthCurve: showsHealthCurve, powerItems: powerItems, batteryItems: batteryItems)
			let display = cards.count >= 5 ? cards.filter { $0.id != .checkup } : cards
			let split = mergedColumns(display, left: assignedLeft, right: assignedRight)
			assignedLeft = split.left
			assignedRight = split.right
		}
		.onDisappear {
			monitor.stopPolling()
			// 下次打开时重新配平，避免上一次的历史分配越积越歪
			assignedLeft = []
			assignedRight = []
			// 复位入场动画标志，下次打开才会重新淡入
			didAppear = false
		}
	}
	
	// MARK: - 卡片枚举与自适应分列
	
	private enum CardID: Hashable {
		case powerInfo, batteryInfo, checkup, dailySummary, socChart, healthTrend
		case powerChart, temperatureChart, bluetooth, chargeHistory, powerEvents, energyApps
		case usageCalendar, habitInsight, hourlyDrain
		case runtimeScenarios, batteryIdentity
	}
	
	// 当前能显示出来的卡片及其预估高度（按自然阅读顺序）；高度用于两列配平
	private func visibleCards(
		_ configuration: AppConfiguration,
		showsHealthCurve: Bool,
		powerItems: [BatteryInfoItem],
		batteryItems: [BatteryInfoItem]
	) -> [(id: CardID, height: CGFloat)] {
		let options = configuration.enabledOptions
		var result: [(CardID, CGFloat)] = []
		if !powerItems.isEmpty { result.append((.powerInfo, 22 + 26 * CGFloat(powerItems.count))) }
		if !batteryItems.isEmpty { result.append((.batteryInfo, 22 + 26 * CGFloat(batteryItems.count))) }
		// 续航换算：只在电池模式且有掉电估算时出现
		if options.contains(.runtimeScenarios), monitor.snapshot.powerSource == .battery,
			let estimate = monitor.drainEstimate, estimate.percentPerHour > 0,
			monitor.snapshot.stateOfChargePercent != nil {
			result.append((.runtimeScenarios, cardHeight(.runtimeScenarios, expanded: 118)))
		}
		if options.contains(.batteryCheckup), monitor.snapshot.healthPercent != nil { result.append((.checkup, 58)) }
		// 电池身份证：静态出厂信息，有跳变记录时多留一行状态位
		if options.contains(.batteryIdentity), let identity = monitor.batteryIdentity, identity.isMeaningful {
			let jumpExtra: CGFloat = socJumpCount30d > 0 ? 26 : 0
			result.append((.batteryIdentity, cardHeight(.batteryIdentity, expanded: 104 + jumpExtra)))
		}
		if options.contains(.habitInsight), habitInsight != nil { result.append((.habitInsight, 52)) }
		if options.contains(.dailySummary), let usage = historyRecorder.todayUsage,
		   usage.drainedPercent > 0 || usage.chargedPercent > 0 {
			result.append((.dailySummary, cardHeight(.dailySummary, expanded: historyRecorder.dailyHistory.count >= 2 ? 135 : 92)))
		}
		if options.contains(.usageCalendar), historyRecorder.dailyHistory.count >= 3 {
			result.append((.usageCalendar, cardHeight(.usageCalendar, expanded: 128)))
		}
		if options.contains(.hourlyDrainChart), historyRecorder.hourlyDrainStats.accumulatedDays >= 3 {
			result.append((.hourlyDrain, cardHeight(.hourlyDrainChart, expanded: 96)))
		}
		if options.contains(.socChart), historyRecorder.socSamples.count >= 2 { result.append((.socChart, cardHeight(.socChart, expanded: 120))) }
		if options.contains(.healthTrend), showsHealthCurve { result.append((.healthTrend, cardHeight(.healthTrend, expanded: 142))) }
		if options.contains(.powerChart), monitor.powerSamples.count >= 2 { result.append((.powerChart, cardHeight(.powerChart, expanded: 102))) }
		if options.contains(.temperatureChart), monitor.temperatureSamples.count >= 2 { result.append((.temperatureChart, cardHeight(.temperatureChart, expanded: 96))) }
		if options.contains(.bluetoothDevices), !monitor.bluetoothDevices.isEmpty {
			result.append((.bluetooth, 40 + 34 * CGFloat(monitor.bluetoothDevices.count)))
		}
		if options.contains(.chargeHistory), !historyRecorder.recentSessions.isEmpty {
			result.append((.chargeHistory, cardHeight(.chargeHistory, expanded: 50 + 40 * CGFloat(min(3, historyRecorder.recentSessions.count)))))
		}
		if options.contains(.powerEvents), !historyRecorder.powerEvents.isEmpty {
			result.append((.powerEvents, cardHeight(.powerEvents, expanded: 44 + 26 * CGFloat(min(6, historyRecorder.powerEvents.count)))))
		}
		if options.contains(.significantEnergyApps) {
			let energyExtra = weeklyAppEnergy.isEmpty ? 0 : 22 + 20 * CGFloat(weeklyAppEnergy.count)
			result.append((.energyApps, 44 + 26 * CGFloat(max(1, min(3, monitor.significantEnergyApps.count))) + energyExtra))
		}
		return result.map { (id: $0.0, height: $0.1) }
	}
	
	// 可折叠卡片折起后只剩一行标题，配平时按 32pt 算，否则按展开高度
	private func cardHeight(_ option: DisplayOption, expanded: CGFloat) -> CGFloat {
		configurationManager.configuration.collapsedCards.contains(option.rawValue) ? 32 : expanded
	}
	
	// 贪心配平：按顺序把每张卡片塞进当前较矮的那列，不管哪些卡片出现都能两列收齐
	private func balancedSplit(_ cards: [(id: CardID, height: CGFloat)]) -> (left: [CardID], right: [CardID]) {
		var left: [CardID] = []
		var right: [CardID] = []
		var leftHeight: CGFloat = 0
		var rightHeight: CGFloat = 0
		for card in cards {
			if leftHeight <= rightHeight {
				left.append(card.id)
				leftHeight += card.height
			} else {
				right.append(card.id)
				rightHeight += card.height
			}
		}
		return (left, right)
	}
	
	// 沿用面板打开期间已有的分列：还在场的卡片保持原列原顺序，新到的追加到当前较矮列，
	// 消失的卡片剔除；首次（无历史分配）直接走贪心配平
	private func mergedColumns(
		_ cards: [(id: CardID, height: CGFloat)],
		left: [CardID],
		right: [CardID]
	) -> (left: [CardID], right: [CardID]) {
		let valid = Set(cards.map(\.id))
		let knownLeft = left.filter { valid.contains($0) }
		let knownRight = right.filter { valid.contains($0) }
		if knownLeft.isEmpty, knownRight.isEmpty {
			return balancedSplit(cards)
		}
		
		let heightByID = Dictionary(cards.map { ($0.id, $0.height) }, uniquingKeysWith: { a, _ in a })
		var resultLeft = knownLeft
		var resultRight = knownRight
		var leftHeight = knownLeft.reduce(0) { $0 + (heightByID[$1] ?? 0) }
		var rightHeight = knownRight.reduce(0) { $0 + (heightByID[$1] ?? 0) }
		
		let placed = Set(knownLeft + knownRight)
		for card in cards where !placed.contains(card.id) {
			if leftHeight <= rightHeight {
				resultLeft.append(card.id)
				leftHeight += card.height
			} else {
				resultRight.append(card.id)
				rightHeight += card.height
			}
		}
		return (resultLeft, resultRight)
	}
	
	@ViewBuilder
	private func cardView(
		_ id: CardID,
		powerItems: [BatteryInfoItem],
		batteryItems: [BatteryInfoItem],
		configuration: AppConfiguration,
		showsHealthCurve: Bool
	) -> some View {
		switch id {
		case .powerInfo: powerInfoCard(powerItems)
		case .batteryInfo: batteryInfoCard(batteryItems)
		case .checkup: checkupCard(configuration)
		case .habitInsight: habitInsightCard(configuration)
		case .dailySummary: dailySummaryCard(configuration)
		case .usageCalendar: usageCalendarCard(configuration)
		case .socChart: socChartCard(configuration)
		case .healthTrend: healthTrendCard(configuration, showsHealthCurve: showsHealthCurve)
		case .powerChart: powerChartCard(configuration)
		case .temperatureChart: temperatureChartCard(configuration)
		case .bluetooth: bluetoothCard(configuration)
		case .chargeHistory: chargeHistoryCard(configuration)
		case .powerEvents: powerEventsCard(configuration)
		case .energyApps: energyAppsCard(configuration)
		case .hourlyDrain: hourlyDrainCard(configuration)
		case .runtimeScenarios: runtimeScenariosCard(configuration)
		case .batteryIdentity: batteryIdentityCard(configuration)
		}
	}
	
	// MARK: - 卡片拼装（单列/双列共用同一套条件）
	
	@ViewBuilder
	private func powerInfoCard(_ powerItems: [BatteryInfoItem]) -> some View {
		if !powerItems.isEmpty {
			PopoverCard {
				ForEach(powerItems) { PopoverInfoRow(item: $0) }
			}
		}
	}
	
	@ViewBuilder
	private func batteryInfoCard(_ batteryItems: [BatteryInfoItem]) -> some View {
		if !batteryItems.isEmpty {
			PopoverCard {
				ForEach(batteryItems) { PopoverInfoRow(item: $0) }
			}
		}
	}
	
	@ViewBuilder
	private func checkupCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.batteryCheckup),
		   let checkup = BatteryCheckup.evaluate(
			healthPercent: monitor.snapshot.healthPercent,
			cycleCount: monitor.snapshot.cycleCount,
			temperatureC: monitor.snapshot.temperatureC,
			highSocDwellShare: historyRecorder.todayUsage?.highSocDwellShare
		   ) {
			BatteryCheckupSection(checkup: checkup)
		}
	}
	
	@ViewBuilder
	private func dailySummaryCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.dailySummary), let usage = historyRecorder.todayUsage,
		   usage.drainedPercent > 0 || usage.chargedPercent > 0 {
			DailySummarySection(
				usage: usage,
				chargeCount: todayChargeCount,
				history: historyRecorder.dailyHistory,
				isCollapsed: isCardCollapsed(.dailySummary),
				onToggle: { toggleCard(.dailySummary) }
			)
		}
	}
	
	// 最近 30 天电量跳变次数（身份证卡片与校准提醒共用同一口径）
	private var socJumpCount30d: Int {
		UsagePatternAnalyzer.socJumpCount(historyRecorder.socJumpEvents, withinDays: 30, now: Date())
	}

	// 续航换算：电池模式下把当前掉电速度换算成各场景还能撑多久
	@ViewBuilder
	private func runtimeScenariosCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.runtimeScenarios),
			monitor.snapshot.powerSource == .battery,
			let estimate = monitor.drainEstimate, estimate.percentPerHour > 0,
			let soc = monitor.snapshot.stateOfChargePercent {
			RuntimeScenarioSection(
				estimate: estimate,
				socPercent: soc,
				isCollapsed: isCardCollapsed(.runtimeScenarios),
				onToggle: { toggleCard(.runtimeScenarios) }
			)
		}
	}

	// 电池身份证：出厂静态信息 + 电量计跳变状态
	@ViewBuilder
	private func batteryIdentityCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.batteryIdentity),
			let identity = monitor.batteryIdentity, identity.isMeaningful {
			BatteryIdentitySection(
				identity: identity,
				maxCapacityMAh: monitor.snapshot.maxCapacityMAh,
				jumpCount30d: socJumpCount30d,
				needsCalibration: UsagePatternAnalyzer.gaugeNeedsCalibration(jumpCount: socJumpCount30d),
				isCollapsed: isCardCollapsed(.batteryIdentity),
				onToggle: { toggleCard(.batteryIdentity) }
			)
		}
	}

	// 充电习惯建议（有可用洞察才显示）；先看习惯规律，再看当前充电器是否偏慢
	private var habitInsight: ChargingHabitInsight? {
		if let base = ChargingHabitAnalyzer.analyze(
			events: historyRecorder.powerEvents,
			dailyHistory: historyRecorder.dailyHistory,
			snapshot: monitor.snapshot
		) {
			return base
		}
		return ChargingHabitAnalyzer.analyzeCharger(
			snapshot: monitor.snapshot,
			currentCharger: historyRecorder.currentChargerProfile,
			knownChargers: historyRecorder.chargerProfiles
		)
	}
	
	@ViewBuilder
	private func habitInsightCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.habitInsight), let insight = habitInsight {
			HabitInsightSection(insight: insight)
		}
	}
	
	@ViewBuilder
	private func usageCalendarCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.usageCalendar), historyRecorder.dailyHistory.count >= 3 {
			UsageCalendarSection(
				history: historyRecorder.dailyHistory,
				isCollapsed: isCardCollapsed(.usageCalendar),
				onToggle: { toggleCard(.usageCalendar) }
			)
		}
	}
	
	@ViewBuilder
	private func socChartCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.socChart), historyRecorder.socSamples.count >= 2 {
			SOCChartSection(
				samples: historyRecorder.socSamples,
				lowThreshold: configuration.lowBatteryThresholdPercent,
				isCollapsed: isCardCollapsed(.socChart),
				onToggle: { toggleCard(.socChart) }
			)
		}
	}
	
	@ViewBuilder
	private func healthTrendCard(_ configuration: AppConfiguration, showsHealthCurve: Bool) -> some View {
		if configuration.enabledOptions.contains(.healthTrend), showsHealthCurve {
			HealthTrendSection(
				// 只画电池更换之后的样本：换电池前的旧曲线与新电池不可比
				samples: historyRecorder.trendHealthSamples,
				isCollapsed: isCardCollapsed(.healthTrend),
				onToggle: { toggleCard(.healthTrend) }
			)
		}
	}
	
	@ViewBuilder
	private func powerChartCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.powerChart), monitor.powerSamples.count >= 2 {
			PowerChartSection(
				samples: monitor.powerSamples,
				isCollapsed: isCardCollapsed(.powerChart),
				onToggle: { toggleCard(.powerChart) }
			)
		}
	}
	
	@ViewBuilder
	private func temperatureChartCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.temperatureChart), monitor.temperatureSamples.count >= 2 {
			TemperatureChartSection(
				samples: monitor.temperatureSamples,
				thresholdC: configuration.highTemperatureThresholdC,
				isCollapsed: isCardCollapsed(.temperatureChart),
				onToggle: { toggleCard(.temperatureChart) }
			)
		}
	}
	
	@ViewBuilder
	private func bluetoothCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.bluetoothDevices), !monitor.bluetoothDevices.isEmpty {
			BluetoothDevicesSection(
				devices: monitor.bluetoothDevices,
				lowThreshold: configuration.deviceLowThresholdPercent
			)
		}
	}
	
	@ViewBuilder
	private func chargeHistoryCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.chargeHistory), !historyRecorder.recentSessions.isEmpty {
			ChargeHistorySection(
				sessions: historyRecorder.recentSessions,
				isCollapsed: isCardCollapsed(.chargeHistory),
				onToggle: { toggleCard(.chargeHistory) },
				onSelect: openChargeCurve
			)
		}
	}

	// 打开充电曲线独立窗口；先激活应用确保窗口浮到最上层（与"设置"同一套做法）
	private func openChargeCurve(_ session: ChargeSession) {
		ChargeCurveSelection.shared.startDate = session.startDate
		NSApp.activate(ignoringOtherApps: true)
		openWindow(id: "charge-curve")
	}
	
	@ViewBuilder
	private func powerEventsCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.powerEvents), !historyRecorder.powerEvents.isEmpty {
			PowerEventTimelineSection(
				events: historyRecorder.powerEvents,
				isCollapsed: isCardCollapsed(.powerEvents),
				onToggle: { toggleCard(.powerEvents) }
			)
		}
	}
	
	// 应用耗电"本周累计"排行：最近 7 天按累计秒数取前三（不足 1 分钟的不入榜）
	private var weeklyAppEnergy: [(name: String, seconds: Double)] {
		var keys = Set<String>()
		for offset in 0..<7 {
			if let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) {
				keys.insert(Self.weeklyKeyFormatter.string(from: date))
			}
		}
		return historyRecorder.appEnergy
			.map { ($0.name, $0.seconds(within: keys)) }
			.filter { $0.1 >= 60 }
			.sorted { $0.1 > $1.1 }
			.prefix(3)
			.map { (name: $0.0, seconds: $0.1) }
	}

	private static let weeklyKeyFormatter: DateFormatter = {
		let formatter = DateFormatter()
		// 与历史 dayKey 主键同源的 POSIX 公历
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter
	}()

	@ViewBuilder
	private func hourlyDrainCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.hourlyDrainChart), historyRecorder.hourlyDrainStats.accumulatedDays >= 3 {
			HourlyDrainSection(
				stats: historyRecorder.hourlyDrainStats,
				isCollapsed: isCardCollapsed(.hourlyDrainChart),
				onToggle: { toggleCard(.hourlyDrainChart) }
			)
		}
	}

	@ViewBuilder
	private func energyAppsCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.significantEnergyApps) {
			SignificantEnergySection(
				apps: monitor.significantEnergyApps,
				weeklyTop: weeklyAppEnergy,
				onRevealInFinder: revealInFinder(url:)
			)
		}
	}
	
	// 今天的充电次数：已归档的今日会话 + 进行中的这次
	// （含已充满但未拔电的存活会话——它还没归档，但确实充过）
	private var todayChargeCount: Int {
		let finished = historyRecorder.recentSessions.filter { Calendar.current.isDateInToday($0.startDate) }.count
		let ongoing = (monitor.snapshot.isCharging || historyRecorder.isChargingSessionAlive) ? 1 : 0
		return finished + ongoing
	}
	
	// 图表卡片折叠状态（随配置持久化）
	private func isCardCollapsed(_ option: DisplayOption) -> Bool {
		configurationManager.configuration.collapsedCards.contains(option.rawValue)
	}
	
	private func toggleCard(_ option: DisplayOption) {
		configurationManager.toggleCardCollapsed(option)
	}
	
	// 级联档位：playCascade=false 时全部归零，各块同时落位（无错峰延迟）
	private func cascadeStep(_ step: Int) -> Int {
		playCascade ? step : 0
	}

	private var controlRows: some View {
		VStack(spacing: 0) {
			// 开了提醒但系统不给发通知：提醒实际收不到，给个显眼的入口去开权限
			if configurationManager.configuration.enabledOptions.contains(.alerts),
			   alertController.isNotificationPermissionDenied {
				notificationPermissionWarning
			}
			// 设置已迁到独立设置窗口，这里只负责打开它；
			// 30+ 开关在窗口里按组分区（可搜索、带帮助），比面板子菜单好用得多
			PopoverActionRow("设置", systemImageName: "gear") {
				openSettingsWindow()
			}
			
			PopoverActionRow("导出报告", systemImageName: "square.and.arrow.up") {
				exportReport()
			}

			PopoverActionRow(reportCopied ? "已复制" : "复制报告",
							 systemImageName: reportCopied ? "checkmark.circle.fill" : "doc.on.doc") {
				copyReport()
			}

			PopoverActionRow("导出数据 (CSV)", systemImageName: "tablecells") {
				exportCSV()
			}
			
			// 体检分可算时才提供“生成分享卡片”
			if batteryCheckup != nil {
				PopoverActionRow("生成体检卡片", systemImageName: "photo.badge.checkmark") {
					exportShareCard()
				}
			}
			
			PopoverActionRow("电池设置", systemImageName: "slider.horizontal.3") {
				openBatterySettings()
			}
			
			PopoverActionRow("退出", systemImageName: "power") {
				NSApplication.shared.terminate(nil)
			}
			.keyboardShortcut("q")
		}
	}

	private func openSettingsWindow() {
		// 菜单栏应用(LSUIElement)没有 Dock 图标，直接 openSettings 可能不抢焦点、
		// 弹窗被其他 App 盖住。先激活本应用让它成为前台，设置窗口才会浮到最上层
		NSApp.activate(ignoringOtherApps: true)
		openSettings()
	}

	private func openBatterySettings() {
		guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery") else { return }
		NSWorkspace.shared.open(url)
	}
	
	private var notificationPermissionWarning: some View {
		Button(action: openNotificationSettings) {
			HoverHighlightRow {
				HStack(spacing: 6) {
					Image(systemName: "bell.slash.fill")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(Color.orange)
						.frame(width: 16)
					Text("通知权限未开启，提醒收不到 · 点此开启")
						.font(.system(size: 11))
						.foregroundStyle(Color.orange)
						.lineLimit(1)
						.minimumScaleFactor(0.8)
				}
				.frame(maxWidth: .infinity, minHeight: PopoverLayout.rowHeight, alignment: .leading)
				.padding(.horizontal, PopoverLayout.rowHorizontalPadding)
				.contentShape(Rectangle())
			}
		}
		.buttonStyle(.plain)
	}
	
	private func openNotificationSettings() {
		guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
		NSWorkspace.shared.open(url)
	}
	
	private func revealInFinder(url: URL?) {
		guard let url else { return }
		NSWorkspace.shared.activateFileViewerSelecting([url])
	}
	
	// 生成纯文本报告写入临时目录，并在访达中选中
	private func exportReport() {
		let report = buildReport()
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		let fileName = "电池报告-\(formatter.string(from: Date())).txt"
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
		
		do {
			try report.write(to: url, atomically: true, encoding: .utf8)
			NSWorkspace.shared.activateFileViewerSelecting([url])
		} catch {
			DiagnosticLog.failureOnce("export-report-failed", category: "BatteryPopoverView", "导出报告写入失败：\(error.localizedDescription)")
		}
	}
	
	// 复制纯文本报告到剪贴板；与"导出报告"同源，只是落点不同
	private func copyReport() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(buildReport(), forType: .string)
		// 静默成功没法确认是否生效，行内反馈 1.5 秒
		reportCopied = true
		Task {
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			reportCopied = false
		}
	}
	
	private func buildReport() -> String {
		BatteryReportBuilder(
			snapshot: monitor.snapshot,
			configuration: configurationManager.configuration,
			drainEstimate: monitor.drainEstimate,
			healthSamples: historyRecorder.healthSamples,
			sessions: historyRecorder.recentSessions,
			bluetoothDevices: monitor.bluetoothDevices,
			dailyHistory: historyRecorder.dailyHistory,
			chargerProfiles: historyRecorder.chargerProfiles,
			lastSleepDrain: historyRecorder.lastSleepDrain,
			powerEvents: historyRecorder.powerEvents,
			identity: monitor.batteryIdentity,
			socJumpCount30d: socJumpCount30d
		).build()
	}
	
	// 生成 CSV 数据写入临时目录，并在访达中选中；与"导出报告"互补——
	// 报告是人读的摘要，CSV 是给表格/脚本分析用的原数据
	private func exportCSV() {
		let csv = BatteryDataExporter.csv(
			sessions: historyRecorder.recentSessions,
			dailyHistory: historyRecorder.dailyHistory,
			healthSamples: historyRecorder.healthSamples,
			socSamples: historyRecorder.socSamples,
			powerEvents: historyRecorder.powerEvents
		)

		let formatter = DateFormatter()
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		let fileName = "电池数据-\(formatter.string(from: Date())).csv"
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

		do {
			try csv.write(to: url, atomically: true, encoding: .utf8)
			NSWorkspace.shared.activateFileViewerSelecting([url])
		} catch {
			DiagnosticLog.failureOnce("export-csv-failed", category: "BatteryPopoverView", "导出 CSV 写入失败：\(error.localizedDescription)")
		}
	}
	
	// 当前体检评分（供头部展示与分享卡片共用）
	private var batteryCheckup: BatteryCheckup? {
		guard configurationManager.configuration.enabledOptions.contains(.batteryCheckup) else { return nil }
		return BatteryCheckup.evaluate(
			healthPercent: monitor.snapshot.healthPercent,
			cycleCount: monitor.snapshot.cycleCount,
			temperatureC: monitor.snapshot.temperatureC,
			highSocDwellShare: historyRecorder.todayUsage?.highSocDwellShare
		)
	}
	
	// 生成体检分享卡片（PNG）写入临时目录，并在访达中选中
	private func exportShareCard() {
		guard let checkup = batteryCheckup else { return }
		let card = BatteryShareCardRenderer.render(BatteryShareCardRenderer.CardData(
			score: checkup.score,
			verdict: checkup.verdict,
			healthPercent: monitor.snapshot.healthPercent,
			cycleCount: monitor.snapshot.cycleCount,
			temperatureC: monitor.snapshot.temperatureC,
			generatedAt: Date()
		))
		if let url = BatteryShareCardRenderer.writePNG(card) {
			NSWorkspace.shared.activateFileViewerSelecting([url])
		}
	}
}
