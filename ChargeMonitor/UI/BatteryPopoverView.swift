import AppKit
import SwiftUI

struct BatteryPopoverView: View {
	@ObservedObject var monitor: BatteryMonitor
	@ObservedObject var configurationManager: ConfigurationManager
	@ObservedObject var historyRecorder: BatteryHistoryRecorder
	@ObservedObject var alertController: BatteryAlertController
	
	// 面板打开期间已分好列的卡片：后到的新卡只追加到较矮列，已有卡不滑动不换位，
	// 避免曲线数据陆续到位时整个面板在眼皮底下洗牌；关闭面板后清空，下次打开重新配平
	@State private var assignedLeft: [CardID] = []
	@State private var assignedRight: [CardID] = []
	// 入场动画开关：面板打开时从 false→true 驱动淡入上滑，关闭时复位供下次重播
	@State private var didAppear = false
	
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
			acShare: historyRecorder.todayUsage?.acShare
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
					.modifier(CascadeIn(step: 1, active: didAppear))
				HStack(alignment: .top, spacing: 10) {
					VStack(alignment: .leading, spacing: 8) {
						ForEach(Array(split.left.enumerated()), id: \.element) { index, id in
							cardView(id, powerItems: powerItems, batteryItems: batteryItems, configuration: configuration, showsHealthCurve: showsHealthCurve)
								.modifier(CascadeIn(step: index + 1, active: didAppear))
						}
					}
					.frame(maxWidth: .infinity, alignment: .topLeading)
					
					VStack(alignment: .leading, spacing: 8) {
						ForEach(Array(split.right.enumerated()), id: \.element) { index, id in
							cardView(id, powerItems: powerItems, batteryItems: batteryItems, configuration: configuration, showsHealthCurve: showsHealthCurve)
								.modifier(CascadeIn(step: index + 1, active: didAppear))
						}
					}
					.frame(maxWidth: .infinity, alignment: .topLeading)
				}
			} else {
				ForEach(Array(cardIDs.enumerated()), id: \.element) { index, id in
					cardView(id, powerItems: powerItems, batteryItems: batteryItems, configuration: configuration, showsHealthCurve: showsHealthCurve)
						.modifier(CascadeIn(step: index + 1, active: didAppear))
				}
			}
			
			Divider()
				.modifier(CascadeIn(step: controlStep, active: didAppear))
			
			controlRows
				.modifier(CascadeIn(step: controlStep, active: didAppear))
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
			// 置 true 触发入场：容器自带淡入动画，内部各块由 CascadeIn 按档位错峰落位
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
		case usageCalendar, habitInsight
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
		if options.contains(.batteryCheckup), monitor.snapshot.healthPercent != nil { result.append((.checkup, 58)) }
		if options.contains(.habitInsight), habitInsight != nil { result.append((.habitInsight, 52)) }
		if options.contains(.dailySummary), let usage = historyRecorder.todayUsage,
		   usage.drainedPercent > 0 || usage.chargedPercent > 0 {
			result.append((.dailySummary, cardHeight(.dailySummary, expanded: historyRecorder.dailyHistory.count >= 2 ? 135 : 92)))
		}
		if options.contains(.usageCalendar), historyRecorder.dailyHistory.count >= 3 {
			result.append((.usageCalendar, cardHeight(.usageCalendar, expanded: 128)))
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
			result.append((.energyApps, 44 + 26 * CGFloat(max(1, min(3, monitor.significantEnergyApps.count)))))
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
			acShare: historyRecorder.todayUsage?.acShare
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
	
	// 充电习惯建议（有可用洞察才显示）
	private var habitInsight: ChargingHabitInsight? {
		ChargingHabitAnalyzer.analyze(
			events: historyRecorder.powerEvents,
			dailyHistory: historyRecorder.dailyHistory,
			snapshot: monitor.snapshot
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
				samples: historyRecorder.healthSamples,
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
				onToggle: { toggleCard(.chargeHistory) }
			)
		}
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
	
	@ViewBuilder
	private func energyAppsCard(_ configuration: AppConfiguration) -> some View {
		if configuration.enabledOptions.contains(.significantEnergyApps) {
			SignificantEnergySection(
				apps: monitor.significantEnergyApps,
				onRevealInFinder: revealInFinder(url:)
			)
		}
	}
	
	// 今天的充电次数：已归档的今日会话 + 正在进行的这次
	private var todayChargeCount: Int {
		let finished = historyRecorder.recentSessions.filter { Calendar.current.isDateInToday($0.startDate) }.count
		let ongoing = monitor.snapshot.isCharging ? 1 : 0
		return finished + ongoing
	}
	
	// 图表卡片折叠状态（随配置持久化）
	private func isCardCollapsed(_ option: DisplayOption) -> Bool {
		configurationManager.configuration.collapsedCards.contains(option.rawValue)
	}
	
	private func toggleCard(_ option: DisplayOption) {
		configurationManager.toggleCardCollapsed(option)
	}
	
	private var controlRows: some View {
		VStack(spacing: 0) {
			// 开了提醒但系统不给发通知：提醒实际收不到，给个显眼的入口去开权限
			if configurationManager.configuration.enabledOptions.contains(.alerts),
			   alertController.isNotificationPermissionDenied {
				notificationPermissionWarning
			}
			PopoverMenuRow("偏好设置", systemImageName: "gear") {
				// 三十多个开关按组收进子菜单，平铺早就没法看了
				ForEach(DisplayOption.Group.allCases, id: \.title) { group in
					Menu {
						ForEach(DisplayOption.allCases.filter { $0.group == group }) { option in
							Toggle(option.title, isOn: displayOptionBinding(option))
						}
						
						// 警示阈值跟提醒开关放一起，菜单栏变色/面板徽章/通知共用同一套
						if group == .alerts {
							Divider()
							
							Picker("低电量警示线", selection: lowBatteryThresholdBinding) {
								ForEach([10, 15, 20, 25, 30], id: \.self) { percent in
									Text("\(percent)%").tag(percent)
								}
							}
							
							Picker("高温警示线", selection: highTemperatureThresholdBinding) {
								ForEach([35, 38, 40, 42, 45], id: \.self) { celsius in
									Text("\(celsius)°C").tag(celsius)
								}
							}
							
							Picker("保养提醒线", selection: chargeCareThresholdBinding) {
								ForEach([70, 75, 80, 85, 90], id: \.self) { percent in
									Text("\(percent)%").tag(percent)
								}
							}
							
							Picker("外设低电线", selection: deviceLowThresholdBinding) {
								ForEach([10, 15, 20, 25, 30], id: \.self) { percent in
									Text("\(percent)%").tag(percent)
								}
							}
							
							Picker("耗电异常线", selection: highDrainThresholdBinding) {
								ForEach([15, 20, 25, 30], id: \.self) { rate in
									Text("\(rate)%/小时").tag(rate)
								}
							}
						}
					} label: {
						Label(group.title, systemImage: group.symbol)
					}
				}
				
				Divider()
				
				Picker("菜单栏显示", selection: menuBarContentBinding) {
					ForEach(MenuBarContent.allCases) { content in
						Text(content.title).tag(content)
					}
				}
			}
			
			PopoverActionRow("导出报告", systemImageName: "square.and.arrow.up") {
				exportReport()
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
			
			PopoverActionRow("检查更新\(appVersionSuffix)", systemImageName: "arrow.triangle.2.circlepath") {
				UpdateChecker.shared.check()
			}
			
			PopoverActionRow("退出", systemImageName: "power") {
				NSApplication.shared.terminate(nil)
			}
			.keyboardShortcut("q")
		}
	}
	
    private var appVersionSuffix: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let version, !version.isEmpty else { return "" }
        return " (\(version))"
    }
	
	private func displayOptionBinding(_ option: DisplayOption) -> Binding<Bool> {
		Binding(
			get: { configurationManager.configuration.enabledOptions.contains(option) },
			set: { configurationManager.setOption(option, isEnabled: $0) }
		)
	}
	
	private var menuBarContentBinding: Binding<MenuBarContent> {
		Binding(
			get: { configurationManager.configuration.menuBarContent },
			set: { configurationManager.setMenuBarContent($0) }
		)
	}
	
	private var lowBatteryThresholdBinding: Binding<Int> {
		Binding(
			get: { configurationManager.configuration.lowBatteryThresholdPercent },
			set: { configurationManager.setLowBatteryThreshold($0) }
		)
	}
	
	private var highTemperatureThresholdBinding: Binding<Int> {
		Binding(
			get: { configurationManager.configuration.highTemperatureThresholdC },
			set: { configurationManager.setHighTemperatureThreshold($0) }
		)
	}
	
	private var chargeCareThresholdBinding: Binding<Int> {
		Binding(
			get: { configurationManager.configuration.chargeCareThresholdPercent },
			set: { configurationManager.setChargeCareThreshold($0) }
		)
	}
	
	private var deviceLowThresholdBinding: Binding<Int> {
		Binding(
			get: { configurationManager.configuration.deviceLowThresholdPercent },
			set: { configurationManager.setDeviceLowThreshold($0) }
		)
	}
	
	private var highDrainThresholdBinding: Binding<Int> {
		Binding(
			get: { configurationManager.configuration.highDrainThresholdPerHour },
			set: { configurationManager.setHighDrainThreshold($0) }
		)
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
		let report = BatteryReportBuilder(
			snapshot: monitor.snapshot,
			configuration: configurationManager.configuration,
			drainEstimate: monitor.drainEstimate,
			healthSamples: historyRecorder.healthSamples,
			sessions: historyRecorder.recentSessions,
			bluetoothDevices: monitor.bluetoothDevices,
			dailyHistory: historyRecorder.dailyHistory,
			chargerProfiles: historyRecorder.chargerProfiles,
			lastSleepDrain: historyRecorder.lastSleepDrain,
			powerEvents: historyRecorder.powerEvents
		).build()
		
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
	
	// 当前体检评分（供头部展示与分享卡片共用）
	private var batteryCheckup: BatteryCheckup? {
		guard configurationManager.configuration.enabledOptions.contains(.batteryCheckup) else { return nil }
		return BatteryCheckup.evaluate(
			healthPercent: monitor.snapshot.healthPercent,
			cycleCount: monitor.snapshot.cycleCount,
			temperatureC: monitor.snapshot.temperatureC,
			acShare: historyRecorder.todayUsage?.acShare
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

// 顶部大电量数字 + 圆环仪表
private struct BatteryHeaderView: View {
	let snapshot: BatterySnapshot
	let drainEstimate: DrainRateEstimate?
	let lowBatteryThreshold: Int
	// 宽面板时传入体检评分，展在头部右侧的空白区；窄面板为 nil、体检仍走卡片
	var checkup: BatteryCheckup? = nil
	
	var body: some View {
		HStack(spacing: 12) {
			gauge
				.accessibilityHidden(true)   // 圆环仅装饰，信息已并入下方文字的组合朗读
			
			VStack(alignment: .leading, spacing: 3) {
				HStack(alignment: .firstTextBaseline, spacing: 2) {
					Text("\(snapshot.stateOfChargePercent ?? 0)")
						.font(.system(size: 27, weight: .bold, design: .rounded))
						.contentTransition(.numericText())
					Text("%")
						.font(.system(size: 15, weight: .semibold, design: .rounded))
						.foregroundStyle(.secondary)
				}
				
				statusView
				
				// 打开面板最想知道的一句话：还能用多久 / 还要充多久
				if let subtitleText {
					Text(subtitleText)
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.minimumScaleFactor(0.8)
				}
			}
			// 左侧一组（电量/状态/续航）合并为一句朗读，免得 VoiceOver 逐个小元素念得很碎
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(headerAccessibilityLabel)
			
			Spacer(minLength: 0)
			
			// 宽面板头部右侧：体检小圆环 + 评语，填上以前空着的一大块
			if let checkup {
				headerCheckup(checkup)
					.accessibilityElement(children: .ignore)
					.accessibilityLabel("电池体检 \(checkup.score) 分，\(checkup.verdict)")
			}
		}
		.padding(.horizontal, 4)
	}
	
	// 头部组合朗读：电量 + 状态 + 续航，拼成一句自然语句
	private var headerAccessibilityLabel: String {
		var parts = ["电量 \(snapshot.stateOfChargePercent ?? 0)%", statusText]
		if snapshot.isLowPowerModeEnabled { parts.append("低电量模式") }
		if let subtitleText { parts.append(subtitleText) }
		return parts.joined(separator: "，")
	}
	
	// 头部版体检徽章：环形进度 + 中心分数 + 右侧评语
	private func headerCheckup(_ checkup: BatteryCheckup) -> some View {
		HStack(spacing: 7) {
			ZStack {
				Circle()
					.stroke(checkupColor(checkup.score).opacity(0.15), lineWidth: 3)
				Circle()
					.trim(from: 0, to: CGFloat(checkup.score) / 100)
					.stroke(checkupColor(checkup.score), style: StrokeStyle(lineWidth: 3, lineCap: .round))
					.rotationEffect(.degrees(-90))
				Text("\(checkup.score)")
					.font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
					.foregroundStyle(checkupColor(checkup.score))
			}
			.frame(width: 34, height: 34)
			
			VStack(alignment: .leading, spacing: 1) {
				Text("电池体检")
					.font(.system(size: 9))
					.foregroundStyle(.secondary)
				Text(checkup.verdict)
					.font(.system(size: 10.5, weight: .medium))
					.foregroundStyle(.primary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(width: 92, alignment: .leading)
		}
		.help("综合健康度、循环次数、温度与充电习惯的加权评分")
	}
	
	private func checkupColor(_ score: Int) -> Color {
		switch BatteryCheckup.tier(for: score) {
		case .excellent: return .green
		case .good: return .teal
		case .aging: return .orange
		case .poor: return .red
		}
	}
	
	private var percentFraction: CGFloat {
		CGFloat(snapshot.stateOfChargePercent ?? 0) / 100
	}
	
	private var gaugeColor: Color {
		if snapshot.isCharging || snapshot.isFull { return .green }
		if (snapshot.stateOfChargePercent ?? 100) <= lowBatteryThreshold { return .red }
		return .accentColor
	}
	
	private var gauge: some View {
		ZStack {
			Circle()
				.stroke(gaugeColor.opacity(0.15), lineWidth: 4.5)
			
			// 进度弧：沿弧线方向由淡到浓的角度渐变，更有质感
			Circle()
				.trim(from: 0, to: max(0.02, percentFraction))
				.stroke(
					AngularGradient(
						colors: [gaugeColor.opacity(0.45), gaugeColor],
						center: .center,
						startAngle: .degrees(0),
						endAngle: .degrees(360 * percentFraction)
					),
					style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
				)
				.rotationEffect(.degrees(-90))
				.animation(.easeOut(duration: 0.4), value: percentFraction)
			
			// 充电且未充满时：进度弧尽头一颗呼吸光点，克制不喧闹
			// 充满后光点停在 12 点钟方向持续呼吸没意义，不再显示
			if snapshot.isCharging && !snapshot.isFull {
				ChargingBreathingDot(color: gaugeColor)
					.offset(y: -23)
					.rotationEffect(.degrees(360 * percentFraction))
			}
			
			Image(systemName: centerSymbol)
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(gaugeColor)
		}
		.frame(width: 46, height: 46)
	}
	
	// 呼吸光点：限帧到 12fps（慢呼吸肉眼无差），模糊半径固定不变避免逐帧重算高斯模糊，
	// 呼吸只动透明度和缩放。不用 repeatForever/symbolEffect 是因为那类持续动画
	// 会以屏幕满帧率驱动整个面板视图树重算，CPU 开销大得多
	private struct ChargingBreathingDot: View {
		let color: Color
		
		var body: some View {
			TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
				let time = context.date.timeIntervalSinceReferenceDate
				let breathe = 0.5 + 0.5 * sin(time * 2 * .pi / 1.8)
				Circle()
					.fill(.white)
					.frame(width: 4.5, height: 4.5)
					.shadow(color: color, radius: 3)
					.opacity(0.55 + 0.45 * breathe)
					.scaleEffect(0.9 + 0.25 * breathe)
			}
		}
	}
	
	// 充电/充满用绿色胶囊徽章，低电量用红色胶囊警示，其余状态保持素雅文字
	@ViewBuilder
	private var statusView: some View {
		if snapshot.isCharging || snapshot.isFull {
			statusBadge(
				symbol: snapshot.isFull ? "checkmark.circle.fill" : "bolt.fill",
				text: statusText,
				color: .green
			)
		} else if isLowBattery {
			// 和菜单栏变红、低电量通知同一套警示语言，阈值统一走用户设置
			statusBadge(
				symbol: "exclamationmark.triangle.fill",
				text: "电量偏低",
				color: .red
			)
		} else {
			Text(plainStatusText)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
		}
	}
	
	private func statusBadge(symbol: String, text: String, color: Color) -> some View {
		HStack(spacing: 3) {
			Image(systemName: symbol)
				.font(.system(size: 9, weight: .bold))
			Text(text)
				.font(.system(size: 10.5, weight: .medium))
		}
		.foregroundStyle(color)
		.padding(.horizontal, 7)
		.padding(.vertical, 2.5)
		.background(Capsule().fill(color.opacity(0.13)))
	}
	
	private var isLowBattery: Bool {
		snapshot.powerSource == .battery && (snapshot.stateOfChargePercent ?? 100) <= lowBatteryThreshold
	}
	
	private var centerSymbol: String {
		if snapshot.isCharging { return "bolt.fill" }
		if snapshot.powerSource == .powerAdapter { return "powerplug.fill" }
		return "minus.plus.batteryblock.fill"
	}
	
	private var statusText: String {
		if snapshot.isFull { return "已充满 · 电源适配器" }
		if snapshot.isCharging { return snapshot.isFastCharging ? "正在快充" : "正在充电" }
		if snapshot.powerSource == .powerAdapter { return "已接通电源 · 未充电" }
		return "正在使用电池"
	}
	
	// 状态是素雅文字时，低电量模式直接拼在后面
	private var plainStatusText: String {
		snapshot.isLowPowerModeEnabled ? statusText + " · 低电量模式" : statusText
	}
	
	// 状态是胶囊徽章时（充电/充满/低电量），徽章里装不下低电量模式，挪到副标题行
	private var showsStatusBadge: Bool {
		snapshot.isCharging || snapshot.isFull || isLowBattery
	}
	
	// 副标题行：续航一句话 + 低电量模式标记
	private var subtitleText: String? {
		var parts: [String] = []
		if let remainingText { parts.append(remainingText) }
		if snapshot.isLowPowerModeEnabled && showsStatusBadge { parts.append("低电量模式") }
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}
	
	// 头部一句话续航：充电看还要多久充满，用电池看还能撑多久，都附上具体时刻
	// 系统估算没出来时（刚拔插常见），用最近一小时掉电速度兜底
	private var remainingText: String? {
		if snapshot.isCharging, !snapshot.isFull,
		   let minutes = snapshot.timeToFullChargeMinutes, minutes > 0 {
			return "约 \(DurationFormatter.chinese(minutes: minutes)) 后充满（\(Self.clockText(after: minutes))）"
		}
		if snapshot.powerSource == .battery, !snapshot.isCharging {
			if let minutes = snapshot.timeToEmptyMinutes, minutes > 0 {
				return "预计还能用 \(DurationFormatter.chinese(minutes: minutes))（到 \(Self.clockText(after: minutes))）"
			}
			if let minutes = drainEstimate?.estimatedMinutesRemaining, minutes > 0 {
				return "预计还能用 \(DurationFormatter.chinese(minutes: minutes))（到 \(Self.clockText(after: minutes))）"
			}
		}
		return nil
	}
	
	// 从现在算起 N 分钟后的时刻，跨天时加“明天”免得误以为是今天
	private static func clockText(after minutes: Int) -> String {
		let target = Date().addingTimeInterval(TimeInterval(minutes) * 60)
		let time = clockFormatter.string(from: target)
		return Calendar.current.isDateInTomorrow(target) ? "明天 " + time : time
	}
	
	private static let clockFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()
}

// 今日小结：电池模式掉了多少、充进去多少、充了几次；有多天数据时附七天柱状图
private struct DailySummarySection: View {
	let usage: DailyUsage
	let chargeCount: Int
	let history: [DailyUsage]
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "今日小结", isCollapsed: isCollapsed, onToggle: onToggle) {
				// 折叠时留一句概要，不点开也能瞥一眼
				if isCollapsed {
					Text("用电 \(usage.drainedPercent)% · 充入 \(usage.chargedPercent)%")
						.font(.system(size: 10).monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			.padding(.bottom, isCollapsed ? 0 : 2)
			
			if !isCollapsed {
				HStack(spacing: 0) {
					statItem(symbol: "arrow.down.circle.fill", color: .orange, value: "\(usage.drainedPercent)%", label: "用电")
					statItem(symbol: "bolt.circle.fill", color: .green, value: "\(usage.chargedPercent)%", label: "充入")
					statItem(symbol: "repeat.circle.fill", color: .blue, value: "\(chargeCount) 次", label: "充电")
				}
				.padding(.vertical, 2)
				
				// 插电占比：长期插电党能看到自己的习惯
				if let share = usage.acShare {
					Text(String(format: "今天 %.0f%% 的时间插着电源", share * 100))
						.font(.system(size: 9))
						.foregroundStyle(.tertiary)
						.padding(.top, 1)
				}
				
				// 至少两天数据才画对比图，单天没得比
				if history.count >= 2 {
					weekChart
						.padding(.top, 4)
				}
			}
		}
	}
	
	// 历史只存有数据的天；中间哪天没开机会断档，直接并排会误导成连续日期
	// 这里从窗口内最早一天连续排到今天，缺勤的日子补空柱占位
	private var paddedHistory: [DailyUsage] {
		let calendar = Calendar.current
		let today = calendar.startOfDay(for: Date())
		guard
			let firstKey = history.first?.dayKey,
			let firstDate = Self.dayKeyFormatter.date(from: firstKey),
			let windowStart = calendar.date(byAdding: .day, value: -6, to: today)
		else { return history }
		
		let byKey = Dictionary(history.map { ($0.dayKey, $0) }, uniquingKeysWith: { _, newer in newer })
		var result: [DailyUsage] = []
		var date = max(calendar.startOfDay(for: firstDate), windowStart)
		while date <= today {
			let key = Self.dayKeyFormatter.string(from: date)
			result.append(byKey[key] ?? DailyUsage(dayKey: key))
			guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
			date = next
		}
		return result
	}
	
	// 每天两根柱：橙色用电、绿色充入，高度按七天内最大值归一化
	private var weekChart: some View {
		let days = paddedHistory
		let maxValue = max(days.flatMap { [$0.drainedPercent, $0.chargedPercent] }.max() ?? 1, 1)
		return HStack(alignment: .bottom, spacing: 8) {
			ForEach(days, id: \.dayKey) { day in
				VStack(spacing: 2) {
					HStack(alignment: .bottom, spacing: 2) {
						bar(value: day.drainedPercent, maxValue: maxValue, color: .orange)
						bar(value: day.chargedPercent, maxValue: maxValue, color: .green)
					}
					.frame(height: 26, alignment: .bottom)
					
					Text(Self.dayLabel(day.dayKey))
						.font(.system(size: 8))
						.foregroundStyle(day.dayKey == days.last?.dayKey ? Color.primary : Color.secondary)
				}
				.frame(maxWidth: .infinity)
				// 悬停某天的柱子看具体数值（系统原生 tooltip）
				.help(Self.dayHelp(day))
			}
		}
	}
	
	private static func dayHelp(_ day: DailyUsage) -> String {
		let dateText = dayKeyFormatter.date(from: day.dayKey).map { helpDateFormatter.string(from: $0) } ?? day.dayKey
		return "\(dateText)：用电 \(day.drainedPercent)% · 充入 \(day.chargedPercent)%"
	}
	
	private static let helpDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "M月d日"
		return formatter
	}()
	
	private func bar(value: Int, maxValue: Int, color: Color) -> some View {
		Capsule()
			.fill(value > 0 ? color.opacity(0.85) : Color.secondary.opacity(0.18))
			.frame(width: 5, height: max(2, 26 * CGFloat(value) / CGFloat(maxValue)))
	}
	
	// 日期键转星期字，今天显示“今”
	private static func dayLabel(_ dayKey: String) -> String {
		guard let date = dayKeyFormatter.date(from: dayKey) else { return "" }
		if Calendar.current.isDateInToday(date) { return "今" }
		let weekday = Calendar.current.component(.weekday, from: date)
		return ["", "日", "一", "二", "三", "四", "五", "六"][weekday]
	}
	
	private static let dayKeyFormatter: DateFormatter = {
		let formatter = DateFormatter()
		// 解析落盘主键 dayKey，locale 必须与生成时一致用 POSIX 公历，否则非公历系统下解析会失败
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter
	}()
	
	private func statItem(symbol: String, color: Color, value: String, label: String) -> some View {
		HStack(spacing: 5) {
			Image(systemName: symbol)
				.font(.system(size: 13))
				.foregroundStyle(color)
			VStack(alignment: .leading, spacing: 0) {
				Text(value)
					.font(.system(size: PopoverLayout.bodyFontSize, weight: .semibold).monospacedDigit())
				Text(label)
					.font(.system(size: 9))
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

// 健康趋势图（自包含）：历史实线 + 可选的老化预测虚线，同一 Canvas 同一映射才对齐
// 有预测时历史只占左侧 62%，右侧留给延伸虚线；无预测时历史铺满全宽
private struct HealthTrendChart: View {
	let samples: [HealthSample]
	let hasProjection: Bool
	
	var body: some View {
		Canvas { context, size in
			let values = samples.map { Double($0.healthPercent) }
			guard values.count >= 2, let maxV = values.max(), let minV = values.min() else { return }
			// 有预测时把 80% 纳入下界，保证交汇点在画布内；无预测则沿用原来的下限 2
			let lo = hasProjection ? min(minV, 80) : minV
			let range = max(maxV - lo, 2)
			let histFraction: CGFloat = hasProjection ? 0.62 : 1.0
			let histWidth = size.width * histFraction
			
			func yPos(_ v: Double) -> CGFloat {
				size.height * (0.88 - 0.72 * CGFloat((v - lo) / range))
			}
			
			let points = values.enumerated().map { index, value in
				CGPoint(x: histWidth * CGFloat(index) / CGFloat(values.count - 1), y: yPos(value))
			}
			
			// 中点二次曲线平滑
			var line = Path()
			line.move(to: points[0])
			for index in 1..<points.count {
				let prev = points[index - 1]
				let cur = points[index]
				let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
				line.addQuadCurve(to: mid, control: prev)
			}
			if let last = points.last { line.addLine(to: last) }
			
			var fill = line
			fill.addLine(to: CGPoint(x: histWidth, y: size.height))
			fill.addLine(to: CGPoint(x: 0, y: size.height))
			fill.closeSubpath()
			context.fill(fill, with: .linearGradient(
				Gradient(colors: [Color.green.opacity(0.3), Color.green.opacity(0.02)]),
				startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
			))
			context.stroke(line, with: .color(.green), lineWidth: 1.5)
			
			guard let lastPoint = points.last else { return }
			let halo = Path(ellipseIn: CGRect(x: lastPoint.x - 4, y: lastPoint.y - 4, width: 8, height: 8))
			context.fill(halo, with: .color(Color.green.opacity(0.25)))
			let dot = Path(ellipseIn: CGRect(x: lastPoint.x - 2, y: lastPoint.y - 2, width: 4, height: 4))
			context.fill(dot, with: .color(.green))
			
			// 老化预测虚线：从实线末端延到右边缘的 80% 点
			if hasProjection {
				let endPoint = CGPoint(x: size.width, y: yPos(80))
				var dash = Path()
				dash.move(to: lastPoint)
				dash.addLine(to: endPoint)
				context.stroke(dash, with: .color(Color.orange.opacity(0.75)), style: StrokeStyle(lineWidth: 1.3, dash: [3, 2]))
				
				let ring = Path(ellipseIn: CGRect(x: endPoint.x - 3, y: endPoint.y - 3, width: 6, height: 6))
				context.stroke(ring, with: .color(.orange), lineWidth: 1.3)
				let label = context.resolve(Text("80%").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.orange))
				let ls = label.measure(in: size)
				context.draw(label, at: CGPoint(x: size.width - ls.width / 2 - 1, y: max(endPoint.y - 9, ls.height / 2)), anchor: .center)
			}
		}
	}
}

// 充电习惯建议：一条本地统计得出的软提示（图标 + 一句话）
private struct HabitInsightSection: View {
	let insight: ChargingHabitInsight
	
	var body: some View {
		PopoverCard {
			HStack(spacing: 9) {
				Image(systemName: insight.symbol)
					.font(.system(size: 16))
					.symbolRenderingMode(.hierarchical)
					.foregroundStyle(Color.accentColor)
					.frame(width: 22)
				
				VStack(alignment: .leading, spacing: 1) {
					Text("小建议")
						.font(.system(size: 9))
						.foregroundStyle(.secondary)
					Text(insight.message)
						.font(.system(size: 11))
						.foregroundStyle(.primary)
						.fixedSize(horizontal: false, vertical: true)
				}
				
				Spacer(minLength: 0)
			}
			.padding(.vertical, 1)
		}
	}
}

// 用电日历热力图：一格一天，颜色越深那天用电越狠（仅统计电池模式掉电）
// 仿 GitHub 贡献格子，按周列排，一眼看出长期用电规律
private struct UsageCalendarSection: View {
	let history: [DailyUsage]
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	// 最多展示最近 N 周（面板宽度有限）
	private static let weeks = 10
	private static let cellSize: CGFloat = 11
	private static let cellGap: CGFloat = 3
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "用电日历", isCollapsed: isCollapsed, onToggle: onToggle) {
				if let peak = history.map(\.drainedPercent).max(), peak > 0 {
					Text("峰值 \(peak)%")
						.font(.system(size: 10, weight: .semibold).monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			
			if !isCollapsed {
				grid
					.padding(.top, 6)
					.accessibilityElement(children: .ignore)
					.accessibilityLabel(calendarAccessibilityLabel)
				
				HStack(spacing: 4) {
					Text("少")
						.font(.system(size: 9))
						.foregroundStyle(.tertiary)
					ForEach([0.0, 0.3, 0.6, 1.0], id: \.self) { level in
						RoundedRectangle(cornerRadius: 2, style: .continuous)
							.fill(Self.cellColor(level))
							.frame(width: 9, height: 9)
					}
					Text("多")
						.font(.system(size: 9))
						.foregroundStyle(.tertiary)
					Spacer()
				}
				.padding(.top, 6)
			}
		}
	}
	
	// 日历热力图是一堆彩色方格，VoiceOver 读不出；给个天数 + 峰值的汇总朗读
	private var calendarAccessibilityLabel: String {
		let days = history.filter { $0.drainedPercent > 0 }.count
		let peak = history.map(\.drainedPercent).max() ?? 0
		return "用电日历，近 \(days) 天有用电记录，单日峰值 \(peak)%"
	}
	
	// 按周分列：每列一周（周日到周六），从早到晚从左到右
	private var grid: some View {
		let columns = Self.buildColumns(history)
		let maxDrain = max(history.map(\.drainedPercent).max() ?? 1, 1)
		return HStack(alignment: .top, spacing: Self.cellGap) {
			ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
				VStack(spacing: Self.cellGap) {
					ForEach(0..<7, id: \.self) { weekday in
						cell(week[weekday], maxDrain: maxDrain)
					}
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
	
	@ViewBuilder
	private func cell(_ day: DailyUsage?, maxDrain: Int) -> some View {
		if let day {
			let level = Double(day.drainedPercent) / Double(maxDrain)
			RoundedRectangle(cornerRadius: 2, style: .continuous)
				.fill(Self.cellColor(level))
				.frame(width: Self.cellSize, height: Self.cellSize)
				.help("\(day.dayKey)：用电 \(day.drainedPercent)%")
		} else {
			// 窗口内但无数据的日子（没开机）留个极淡占位格
			RoundedRectangle(cornerRadius: 2, style: .continuous)
				.fill(Color.secondary.opacity(0.08))
				.frame(width: Self.cellSize, height: Self.cellSize)
		}
	}
	
	// 按用电强度映射绿→橙的热力色；0 用电用极淡底色
	private static func cellColor(_ level: Double) -> Color {
		if level <= 0.001 { return Color.secondary.opacity(0.12) }
		// 低→高：淡绿 → 绿 → 橙，透明度也随强度增大
		let clamped = min(max(level, 0), 1)
		let hue = 0.33 - 0.25 * clamped   // 0.33 绿 → 0.08 橙红
		return Color(hue: hue, saturation: 0.75, brightness: 0.85, opacity: 0.35 + 0.6 * clamped)
	}
	
	// 把用电历史按自然周排成列；每列 7 格（周日=0…周六=6），缺的天为 nil
	private static func buildColumns(_ history: [DailyUsage]) -> [[DailyUsage?]] {
		UsageCalendarLayout.buildColumns(history, weeks: weeks, today: Date(), calendar: .current)
	}
}

// 用电日历的周历排布（纯逻辑，抽出来可注入 today/calendar 供单测）
// 网格永远以「真实今天」为右下锚点，而非最后一条数据的日期——
// 否则今天还没产生用电数据时，日历会以昨天为基准，日期整体错位
enum UsageCalendarLayout {
	static let dayFormatter: DateFormatter = {
		let formatter = DateFormatter()
		// 与 dayKey 主键同源，固定 POSIX 公历，避免非公历系统下日期错乱
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter
	}()
	
	static func buildColumns(_ history: [DailyUsage], weeks: Int, today: Date, calendar: Calendar) -> [[DailyUsage?]] {
		let byKey = Dictionary(history.map { ($0.dayKey, $0) }, uniquingKeysWith: { _, b in b })
		let todayStart = calendar.startOfDay(for: today)
		
		// 从今天所在周往前数 weeks-1 周的周日作为起点
		let todayWeekday = calendar.component(.weekday, from: todayStart) - 1 // 0=周日
		guard let gridStart = calendar.date(byAdding: .day, value: -(todayWeekday + (weeks - 1) * 7), to: todayStart) else { return [] }
		
		var columns: [[DailyUsage?]] = []
		var cursor = gridStart
		for _ in 0..<weeks {
			var week: [DailyUsage?] = []
			for _ in 0..<7 {
				if cursor > todayStart {
					week.append(nil)
				} else {
					let key = dayFormatter.string(from: cursor)
					week.append(byKey[key])
				}
				cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
			}
			columns.append(week)
		}
		return columns
	}
}

// 健康度趋势曲线：每天一个采样点，看健康度是稳还是在掉
private struct HealthTrendSection: View {
	let samples: [HealthSample]
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "健康度趋势", isCollapsed: isCollapsed, onToggle: onToggle) {
				if let first = samples.first, let last = samples.last {
					// 首尾对比一眼看出变化；没掉就是好消息
					Text(first.healthPercent == last.healthPercent
						? "稳定在 \(last.healthPercent)%"
						: "\(first.healthPercent)% → \(last.healthPercent)%")
						.font(.system(size: 10, weight: .semibold).monospacedDigit())
						.foregroundStyle(last.healthPercent < first.healthPercent ? Color.orange : Color.green)
				}
			}
			
			if !isCollapsed {
				// 无预测时历史铺满全宽；有预测时历史占左侧，右侧接一段延伸到 80% 的虚线
				HealthTrendChart(samples: samples, hasProjection: projection != nil)
					.frame(height: 36)
					.padding(.top, 4)
					.accessibilityElement(children: .ignore)
					.accessibilityLabel(healthChartAccessibilityLabel)
				
				HStack {
					Text(Self.dayText(samples.first?.date))
					Spacer()
					Text(Self.dayText(samples.last?.date))
				}
				.font(.system(size: 9))
				.foregroundStyle(.tertiary)
				.padding(.top, 2)
				
				// 数据跨度够长且确实在掉时，外推一句寿命预测
				if let lifespanText {
					Text(lifespanText)
						.font(.system(size: 9))
						.foregroundStyle(.secondary)
						.padding(.top, 3)
				}
			}
		}
	}
	
	// 图表纯 Canvas，VoiceOver 读不出，给个首尾健康度 + 寿命预测的朗读
	private var healthChartAccessibilityLabel: String {
		var text = "健康度趋势"
		if let first = samples.first, let last = samples.last {
			text += first.healthPercent == last.healthPercent
				? "，稳定在 \(last.healthPercent)%"
				: "，从 \(first.healthPercent)% 到 \(last.healthPercent)%"
		}
		if let lifespanText { text += "，" + lifespanText }
		return text
	}
	
	// 用首尾两点的平均掉速线性外推到 80%（苹果官方的换电池参考线）；复用 projection 避免两处公式不同步
	private var lifespanText: String? {
		guard let projection else { return nil }
		let months = Int((projection.remainingDays / 30).rounded())
		guard months >= 1 else {
			return "照此趋势快到 80% 了，可以考虑检测电池"
		}
		
		var span = ""
		if months / 12 > 0 { span += "\(months / 12) 年" }
		if months % 12 > 0 { span += "\(months % 12) 个月" }
		return "照此趋势，约 \(span)后降至 80%（官方换电池参考线）"
	}
	
	// 老化预测：外推到 80% 还需多少天；跨度不足 14 天或健康度没掉就不预测，免得拿噪声当趋势吓人
	private var projection: (remainingDays: Double, spanDays: Double)? {
		guard let first = samples.first, let last = samples.last else { return nil }
		let days = last.date.timeIntervalSince(first.date) / 86400
		guard days >= 14, first.healthPercent > last.healthPercent, last.healthPercent > 80 else { return nil }
		let declinePerDay = Double(first.healthPercent - last.healthPercent) / days
		guard declinePerDay > 0 else { return nil }
		let remainingDays = Double(last.healthPercent - 80) / declinePerDay
		return (remainingDays, days)
	}
	
	private static func dayText(_ date: Date?) -> String {
		guard let date else { return "" }
		return dayFormatter.string(from: date)
	}
	
	private static func dayText(_ date: Date) -> String {
		dayFormatter.string(from: date)
	}
	
	private static let dayFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "M月d日"
		return formatter
	}()
}

// 最近 5 分钟的功耗迷你曲线（平滑 + 渐变填充，悬停可查每个时刻的功率）
private struct PowerChartSection: View {
	let samples: [PowerSample]
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "功耗曲线", isCollapsed: isCollapsed, onToggle: onToggle) {
				// 当前功率是最受关注的数字，用主色突出；峰值作为参照置于后
				// 此值每 2 秒刷新，转场用淡入淡出而非 numericText，避免插值字形位图持续堆积
				Text(currentText)
					.font(.system(size: 10, weight: .semibold).monospacedDigit())
					.foregroundStyle(Color.accentColor)
					.contentTransition(.opacity)
					.animation(.easeInOut(duration: 0.3), value: currentText)
				Text(peakText)
					.font(.system(size: 10).monospacedDigit())
					.foregroundStyle(.secondary)
			}
			
			if !isCollapsed {
				SparkAreaChart(
					values: samples.map(\.watts),
					color: .accentColor,
					minRange: 0.5,
					bandBottom: 0.94,
					bandHeight: 0.86,
					hoverLabel: { index in
						String(format: "%@ · %.1fW", Self.timeText(samples[index].date), samples[index].watts)
					}
				)
				.frame(height: 40)
				.padding(.top, 4)
				// 曲线是纯 Canvas，VoiceOver 读不出；给个概括当前/峰值的朗读
				.accessibilityElement(children: .ignore)
				.accessibilityLabel("功耗曲线，\(currentText)，\(peakText.replacingOccurrences(of: "· ", with: ""))")
			}
		}
	}
	
	private var currentText: String {
		String(format: "当前%.1fW", samples.last?.watts ?? 0)
	}
	
	private var peakText: String {
		let peak = samples.map(\.watts).max() ?? 0
		return String(format: "· 峰值%.1fW", peak)
	}
	
	private static func timeText(_ date: Date) -> String {
		timeFormatter.string(from: date)
	}
	
	private static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm:ss"
		return formatter
	}()
}

// 最近 30 分钟的温度迷你曲线，画法与功耗曲线同款，换橙色调
private struct TemperatureChartSection: View {
	let samples: [TemperatureSample]
	let thresholdC: Int
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "温度曲线", isCollapsed: isCollapsed, onToggle: onToggle) {
				// 当前温度超警示线时整个数字变红，不只是淡淡染色
				Text(currentText)
					.font(.system(size: 10, weight: .semibold).monospacedDigit())
					.foregroundStyle(isOverThreshold ? Color.red : Color.orange)
					.contentTransition(.opacity)
					.animation(.easeInOut(duration: 0.3), value: currentText)
				Text(peakText)
					.font(.system(size: 10).monospacedDigit())
					.foregroundStyle(.secondary)
			}
			
			if !isCollapsed {
				SparkAreaChart(
					values: samples.map(\.celsius),
					color: .orange,
					// 温度波动往往只有零点几度，range 给下限免得微小抖动被拉成大起大落
					minRange: 1.0,
					hoverLabel: { index in
						String(format: "%@ · %.1f°C", Self.timeText(samples[index].date), samples[index].celsius)
					}
				)
				.frame(height: 36)
				.padding(.top, 4)
				.accessibilityElement(children: .ignore)
				.accessibilityLabel("温度曲线，\(currentText)\(isOverThreshold ? "，超过警示线" : "")")
			}
		}
	}
	
	private var isOverThreshold: Bool {
		(samples.last?.celsius ?? 0) >= Double(thresholdC)
	}
	
	private var currentText: String {
		String(format: "当前%.1f°C", samples.last?.celsius ?? 0)
	}
	
	private var peakText: String {
		String(format: "· 峰值%.1f°C", samples.map(\.celsius).max() ?? 0)
	}
	
	private static func timeText(_ date: Date) -> String {
		timeFormatter.string(from: date)
	}
	
	private static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()
}

// 电池体检：四项加权出一个总分，一眼看电池状态
private struct BatteryCheckupSection: View {
	let checkup: BatteryCheckup
	
	var body: some View {
		PopoverCard {
			HStack(spacing: 8) {
				ZStack {
					Circle()
						.stroke(color.opacity(0.15), lineWidth: 3)
					Circle()
						.trim(from: 0, to: CGFloat(checkup.score) / 100)
						.stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
						.rotationEffect(.degrees(-90))
					Text("\(checkup.score)")
						.font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
						.foregroundStyle(color)
				}
				.frame(width: 30, height: 30)
				
				VStack(alignment: .leading, spacing: 1) {
					Text("电池体检")
						.font(.system(size: 11, weight: .semibold))
						.foregroundStyle(.secondary)
					Text(checkup.verdict)
						.font(.system(size: PopoverLayout.bodyFontSize, weight: .medium))
				}
				
				Spacer(minLength: 0)
			}
			.padding(.vertical, 1)
			.help("综合健康度、循环次数、温度与充电习惯的加权评分")
		}
	}
	
	private var color: Color {
		switch checkup.tier {
		case .excellent: return .green
		case .good: return .teal
		case .aging: return .orange
		case .poor: return .red
		}
	}
}

// 24 小时电量走势：充电段绿色、放电段主题色，断档（关机/长睡）不连线
private struct SOCChartSection: View {
	let samples: [SOCSample]
	let lowThreshold: Int
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	@State private var hoverX: CGFloat? = nil
	
	private static let windowSeconds: TimeInterval = 24 * 3600
	// 相邻采样间隔超过这个值视为断档，不连线
	private static let gapSeconds: TimeInterval = 45 * 60
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "24小时电量", isCollapsed: isCollapsed, onToggle: onToggle) {
				if let hoverText {
					Text(hoverText)
						.font(.system(size: 10, weight: .semibold).monospacedDigit())
						.foregroundStyle(Color.accentColor)
				} else if let last = samples.last {
					Text("现在 \(last.percent)%")
						.font(.system(size: 10, weight: .semibold).monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			
			if !isCollapsed {
				GeometryReader { geo in
					chartCanvas(width: geo.size.width)
						.onContinuousHover { phase in
							switch phase {
							case .active(let location): hoverX = location.x
							case .ended: hoverX = nil
							}
						}
						.frame(width: geo.size.width)
				}
				.frame(height: 44)
				.padding(.top, 4)
				.accessibilityElement(children: .ignore)
				.accessibilityLabel("24小时电量走势，现在 \(samples.last?.percent ?? 0)%")
				
				HStack {
					Text(Self.axisFormatter.string(from: Date().addingTimeInterval(-Self.windowSeconds)))
					Spacer()
					Text("现在")
				}
				.font(.system(size: 9))
				.foregroundStyle(.tertiary)
				.padding(.top, 2)
			}
		}
	}
	
	// 悬停处最近的采样点（用于标题栏展示“时刻 · 电量”）；宽度由调用方传入
	private func hoverSample(width: CGFloat) -> SOCSample? {
		guard let x = hoverX, width > 0 else { return nil }
		let start = Date().addingTimeInterval(-Self.windowSeconds)
		let target = start.addingTimeInterval(Self.windowSeconds * x / width)
		return samples.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
	}
	
	// 标题栏用的悬停文字：无需宽度，只要有悬停就按比例取最近点（与游标略有微差，不影响阅读）
	private var hoverText: String? {
		guard hoverX != nil, let sample = hoverSample(width: 1) ?? samples.last else { return nil }
		return "\(Self.axisFormatter.string(from: sample.date)) · \(sample.percent)%"
	}
	
	private func chartCanvas(width: CGFloat) -> some View {
		Canvas { context, size in
			let now = Date()
			let start = now.addingTimeInterval(-Self.windowSeconds)
			let hovered = hoverSample(width: size.width)
			
			func xPos(_ date: Date) -> CGFloat {
				size.width * CGFloat(date.timeIntervalSince(start) / Self.windowSeconds)
			}
			func yPos(_ percent: Int) -> CGFloat {
				size.height * (0.95 - 0.9 * CGFloat(percent) / 100)
			}
			
			// 低电警示线：淡红色虚线参照
			var thresholdLine = Path()
			thresholdLine.move(to: CGPoint(x: 0, y: yPos(lowThreshold)))
			thresholdLine.addLine(to: CGPoint(x: size.width, y: yPos(lowThreshold)))
			context.stroke(thresholdLine, with: .color(Color.red.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
			
			// 按“时间断档 / 充电状态翻转”切分段落，充电段绿色、放电段主题色
			var runs: [[SOCSample]] = []
			var current: [SOCSample] = []
			for sample in samples {
				if let last = current.last,
				   sample.date.timeIntervalSince(last.date) > Self.gapSeconds || last.isCharging != sample.isCharging {
					// 状态翻转时把前一点也塞进新段，曲线才衔接不断口（断档除外）
					runs.append(current)
					current = sample.date.timeIntervalSince(last.date) > Self.gapSeconds ? [] : [last]
				}
				current.append(sample)
			}
			if !current.isEmpty { runs.append(current) }
			
			for run in runs where run.count >= 2 {
				let color: Color = (run.last?.isCharging ?? false) ? .green : .accentColor
				var line = Path()
				line.move(to: CGPoint(x: xPos(run[0].date), y: yPos(run[0].percent)))
				for sample in run.dropFirst() {
					line.addLine(to: CGPoint(x: xPos(sample.date), y: yPos(sample.percent)))
				}
				
				var fill = line
				fill.addLine(to: CGPoint(x: xPos(run[run.count - 1].date), y: size.height))
				fill.addLine(to: CGPoint(x: xPos(run[0].date), y: size.height))
				fill.closeSubpath()
				context.fill(
					fill,
					with: .linearGradient(
						Gradient(colors: [color.opacity(0.18), color.opacity(0.02)]),
						startPoint: .zero,
						endPoint: CGPoint(x: 0, y: size.height)
					)
				)
				context.stroke(line, with: .color(color), lineWidth: 1.5)
			}
			
			// 末端当前点
			if let last = samples.last {
				let point = CGPoint(x: xPos(last.date), y: yPos(last.percent))
				let color: Color = last.isCharging ? .green : .accentColor
				context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(color.opacity(0.25)))
				context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(color))
			}
			
			// 悬停游标
			if let sample = hovered {
				let x = xPos(sample.date)
				var cursor = Path()
				cursor.move(to: CGPoint(x: x, y: 0))
				cursor.addLine(to: CGPoint(x: x, y: size.height))
				context.stroke(cursor, with: .color(Color.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
				let marker = Path(ellipseIn: CGRect(x: x - 2.5, y: yPos(sample.percent) - 2.5, width: 5, height: 5))
				context.fill(marker, with: .color(sample.isCharging ? .green : .accentColor))
			}
		}
	}
	
	private static let axisFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()
}

// 电源事件时间线：最近的插拔电/充满/睡眠唤醒记录，排查“电去哪了”用
private struct PowerEventTimelineSection: View {
	let events: [PowerEvent]
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	private static let maxVisible = 6
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "电源事件", isCollapsed: isCollapsed, onToggle: onToggle) {
				if isCollapsed, let last = events.last {
					Text("\(Self.style(last.kind).title) \(Self.timeText(last.date))")
						.font(.system(size: 10).monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			.padding(.bottom, isCollapsed ? 0 : 2)
			
			if !isCollapsed {
				ForEach(events.suffix(Self.maxVisible).reversed()) { event in
					let style = Self.style(event.kind)
					HStack(spacing: 8) {
						Image(systemName: style.symbol)
							.font(.system(size: 10, weight: .medium))
							.symbolRenderingMode(.hierarchical)
							.foregroundStyle(style.color)
							.frame(width: 16)
						
						Text(style.title)
							.font(.system(size: PopoverLayout.bodyFontSize))
						
						Spacer(minLength: 8)
						
						Text(Self.timeText(event.date))
							.font(.system(size: 10).monospacedDigit())
							.foregroundStyle(.secondary)
					}
					.padding(.vertical, 2)
				}
			}
		}
	}
	
	private static func style(_ kind: PowerEventKind) -> (symbol: String, color: Color, title: String) {
		switch kind {
		case .pluggedIn: return ("powerplug.fill", .green, "接上电源")
		case .unplugged: return ("powerplug", .orange, "拔掉电源")
		case .chargedFull: return ("battery.100percent.bolt", .green, "充满电")
		case .sleep: return ("moon.fill", .indigo, "进入睡眠")
		case .wake: return ("sun.max.fill", .yellow, "唤醒")
		}
	}
	
	// 今天/昨天只显示时刻，更早带上日期
	private static func timeText(_ date: Date) -> String {
		let calendar = Calendar.current
		if calendar.isDateInToday(date) { return timeFormatter.string(from: date) }
		if calendar.isDateInYesterday(date) { return "昨天 " + timeFormatter.string(from: date) }
		return dateFormatter.string(from: date)
	}
	
	private static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()
	
	private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "M月d日 HH:mm"
		return formatter
	}()
}

// 蓝牙外设（耳机、鼠标、键盘等）电量
private struct BluetoothDevicesSection: View {
	let devices: [BluetoothDeviceBattery]
	// 低电染红的阈值跟用户设置走同一条，与外设低电通知保持一致
	let lowThreshold: Int
	
	var body: some View {
		PopoverCard {
			PopoverSectionHeader("外设电量")
				.padding(.bottom, 2)
			
			ForEach(devices) { device in
				HStack(spacing: 8) {
					deviceBadge(for: device.kind)
					
					VStack(alignment: .leading, spacing: 1) {
						Text(device.name)
							.font(.system(size: PopoverLayout.bodyFontSize, weight: .medium))
							.lineLimit(1)
						
						Text(Self.kindTitle(device.kind))
							.font(.system(size: 9))
							.foregroundStyle(.secondary)
					}
					
					Spacer(minLength: 8)
					
					batteryBar(percent: device.percent)
					
					Text("\(device.percent)%")
						.font(.system(size: PopoverLayout.bodyFontSize, weight: .medium).monospacedDigit())
						.foregroundStyle(device.percent <= lowThreshold ? Color.red : Color.primary)
						.frame(width: 34, alignment: .trailing)
				}
				.padding(.vertical, 3)
			}
		}
	}
	
	// 彩色圆角图标块，按设备类型配色
	private func deviceBadge(for kind: BluetoothDeviceKind) -> some View {
		let style = Self.badgeStyle(kind)
		return RoundedRectangle(cornerRadius: 6, style: .continuous)
			.fill(style.color.opacity(0.16))
			.frame(width: 24, height: 24)
			.overlay {
				Image(systemName: style.symbol)
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(style.color)
			}
	}
	
	private func batteryBar(percent: Int) -> some View {
		let color: Color = percent <= lowThreshold ? .red : (percent <= 50 ? .orange : .green)
		return Capsule()
			.fill(Color.secondary.opacity(0.2))
			.frame(width: 36, height: 4)
			.overlay(alignment: .leading) {
				Capsule()
					.fill(color)
					.frame(width: 36 * CGFloat(percent) / 100)
			}
	}
	
	private static func badgeStyle(_ kind: BluetoothDeviceKind) -> (symbol: String, color: Color) {
		switch kind {
		case .mouse: return ("computermouse.fill", .blue)
		case .keyboard: return ("keyboard.fill", .purple)
		case .trackpad: return ("rectangle.and.hand.point.up.left.filled", .indigo)
		case .headphones: return ("headphones", .pink)
		case .speaker: return ("hifispeaker.fill", .orange)
		case .gamepad: return ("gamecontroller.fill", .green)
		case .phone: return ("iphone", .teal)
		case .other: return ("dot.radiowaves.left.and.right", .gray)
		}
	}
	
	private static func kindTitle(_ kind: BluetoothDeviceKind) -> String {
		switch kind {
		case .mouse: return "鼠标"
		case .keyboard: return "键盘"
		case .trackpad: return "触控板"
		case .headphones: return "耳机"
		case .speaker: return "音箱"
		case .gamepad: return "游戏手柄"
		case .phone: return "手机"
		case .other: return "蓝牙设备"
		}
	}
}

// 最近几次充电会话
private struct ChargeHistorySection: View {
	let sessions: [ChargeSession]
	let isCollapsed: Bool
	let onToggle: () -> Void
	
	private static let maxVisibleSessions = 3
	
	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "充电记录", isCollapsed: isCollapsed, onToggle: onToggle) {
				if isCollapsed, let last = sessions.last {
					Text("上次 \(last.startPercent)% → \(last.endPercent)%")
						.font(.system(size: 10).monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			.padding(.bottom, isCollapsed ? 0 : 2)
			
			if !isCollapsed {
				ForEach(sessions.suffix(Self.maxVisibleSessions).reversed()) { session in
					HStack(spacing: 8) {
						Image(systemName: "bolt.badge.clock")
							.font(.system(size: 11, weight: .medium))
							.foregroundStyle(Color.green)
							.frame(width: 16)
						
						// 两行式：第一行电量变化（核心信息不可被截），第二行时长·峰值·时间
						VStack(alignment: .leading, spacing: 1) {
							Text("\(session.startPercent)% → \(Text("\(session.endPercent)%").foregroundStyle(Color.green))")
								.font(.system(size: PopoverLayout.bodyFontSize, weight: .medium))
								.lineLimit(1)
							Text(Self.detail(session))
								.font(.system(size: 9))
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
						
						Spacer(minLength: 6)
						
						// 这次充电的电量走势小图；旧记录没曲线、不足 1 分钟的闪充画不出走势，都不占位
						if let curve = session.curve, curve.count >= 2, (curve.last?.minuteOffset ?? 0) > 0 {
							ChargeSparkline(curve: curve)
								.frame(width: 30, height: 12)
						}
					}
					.padding(.vertical, 3)
				}
			}
		}
	}
	
	private static func detail(_ session: ChargeSession) -> String {
		var text = "\(Self.dateText(session.startDate)) · \(session.durationMinutes)分钟"
		if session.peakInputW >= 1 {
			text += String(format: " · 峰值%.0fW", session.peakInputW)
		}
		return text
	}
	
	// 时间戳人性化：今天/昨天只显示时刻，更早才显示日期
	private static func dateText(_ date: Date) -> String {
		let calendar = Calendar.current
		if calendar.isDateInToday(date) {
			return "今天 " + timeFormatter.string(from: date)
		}
		if calendar.isDateInYesterday(date) {
			return "昨天 " + timeFormatter.string(from: date)
		}
		return dateFormatter.string(from: date)
	}
	
	private static let timeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter
	}()
	
	private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "MM-dd HH:mm"
		return formatter
	}()
}

// 充电会话的迷你电量曲线：横轴时间、纵轴电量，一眼看出充得快慢
private struct ChargeSparkline: View {
	let curve: [ChargePoint]
	
	var body: some View {
		Canvas { context, size in
			guard curve.count >= 2, let lastOffset = curve.last?.minuteOffset, lastOffset > 0 else { return }
			
			// 纵轴固定 0~100%，不同会话之间高度可比：充 40→80 的图就是比 70→80 的“高一截”
			let points = curve.map { point -> CGPoint in
				let x = size.width * CGFloat(point.minuteOffset) / CGFloat(lastOffset)
				let y = size.height * (1 - CGFloat(point.percent) / 100)
				return CGPoint(x: x, y: y)
			}
			
			var linePath = Path()
			linePath.move(to: points[0])
			for point in points.dropFirst() {
				linePath.addLine(to: point)
			}
			
			var fillPath = linePath
			fillPath.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
			fillPath.addLine(to: CGPoint(x: points[0].x, y: size.height))
			fillPath.closeSubpath()
			
			context.fill(fillPath, with: .color(Color.green.opacity(0.18)))
			context.stroke(linePath, with: .color(Color.green.opacity(0.9)), lineWidth: 1)
		}
	}
}

private struct SignificantEnergySection: View {
	let apps: [SignificantEnergyApp]
	let onRevealInFinder: (URL?) -> Void
	
	var body: some View {
		PopoverCard {
			PopoverSectionHeader("高耗电应用")
				.padding(.bottom, 2)
			
			if apps.isEmpty {
				// 没有耗电大户是好消息，直接用绿色对勾说清楚；
				// 之前的加载转圈会让人误以为一直在查
				HStack(spacing: 6) {
					Image(systemName: "checkmark.circle.fill")
						.font(.system(size: 12))
						.foregroundStyle(Color.green)
					Text("没有明显的耗电大户")
						.font(.system(size: PopoverLayout.bodyFontSize, weight: .regular))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.vertical, PopoverLayout.rowVerticalPadding)
			} else {
				ForEach(apps) { app in
					PopoverActionRow(app.name, icon: app.icon) {
						onRevealInFinder(app.bundleURL)
					}
				}
			}
		}
	}
}

// 单条信息：图标 + 标签 + 值（+ 可选着色）
struct BatteryInfoItem: Identifiable {
	enum Group {
		case power
		case battery
	}
	
	let group: Group
	let symbol: String
	let label: String
	let value: String
	var iconTint: Color? = nil
	var valueTint: Color? = nil
	
	var id: String { label }
}

struct BatteryInfoFormatter {
	let snapshot: BatterySnapshot
	let configuration: AppConfiguration
	var drainEstimate: DrainRateEstimate? = nil
	var healthTrend: (earliest: HealthSample, latest: HealthSample)? = nil
	// 上一觉合盖的掉电记录与当前充电器档案，面板传入；报告自建 formatter 走默认值
	var sleepDrain: SleepDrainRecord? = nil
	var chargerProfile: ChargerProfile? = nil
	// 面板头部已有"还能用多久 / 还要充多久"一句话，面板信息行不再重复这两条；
	// 导出报告自建 formatter 走默认值，报告里仍保留
	var omitsTimeEstimates = false
	
	func makeItems(in group: BatteryInfoItem.Group) -> [BatteryInfoItem] {
		makeItems().filter { $0.group == group }
	}
	
	func makeItems() -> [BatteryInfoItem] {
		var items: [BatteryInfoItem] = []
		
		appendIfPresent(timeToFullItem, to: &items)
		appendIfPresent(chargingProtocolItem, to: &items)
		appendIfPresent(negotiatedTierItem, to: &items)
		appendIfPresent(availableTiersItem, to: &items)
		appendIfPresent(inputPowerItem, to: &items)
		appendIfPresent(chargingPowerItem, to: &items)
		appendIfPresent(currentPowerItem, to: &items)
		
		if snapshot.powerSource == .powerAdapter {
			appendIfPresent(adapterNameItem, to: &items)
			appendIfPresent(adapterManufacturerItem, to: &items)
			appendIfPresent(chargerProfileItem, to: &items)
		}
		
		appendIfPresent(cycleCountItem, to: &items)
		appendIfPresent(healthItem, to: &items)
		appendIfPresent(healthTrendItem, to: &items)
		appendIfPresent(temperatureItem, to: &items)
		appendIfPresent(batteryCurrentVoltageItem, to: &items)
		appendIfPresent(timeToEmptyItem, to: &items)
		appendIfPresent(drainRateItem, to: &items)
		appendIfPresent(sleepDrainItem, to: &items)
		appendIfPresent(uptimeItem, to: &items)
		
		return items
	}
	
	// 报告用的纯文本行
	func makeLines() -> [String] {
		var lines: [String] = []
		
		lines.append(powerSourceLine)
		if snapshot.isLowPowerModeEnabled {
			lines.append("低电量模式：已开启")
		}
		if showsNotChargingWarning {
			lines.append("电池未在充电")
		}
		lines.append(chargingStatusLine)
		lines.append(contentsOf: makeItems().map { "\($0.label)：\($0.value)" })
		
		return lines
	}
	
	private var enabledOptions: Set<DisplayOption> {
		configuration.enabledOptions
	}
	
	private var powerSourceLine: String {
		switch snapshot.powerSource {
		case .powerAdapter: return "电源来源：电源适配器"
		case .battery: return "电源来源：电池"
		}
	}
	
	private var showsNotChargingWarning: Bool {
		snapshot.powerSource == .powerAdapter && !snapshot.isCharging && !snapshot.isFull
	}
	
	private var chargingStatusLine: String {
		if snapshot.isFull { return "充电：已充满" }
		
		let label = snapshot.isCharging && snapshot.isFastCharging ? "充电（快充）" : "充电"
		let value: String = {
			guard snapshot.isCharging else { return "否" }
			return snapshot.stateOfChargePercent.map { "\($0)%" } ?? "是"
		}()
		
		return "\(label)：\(value)"
	}
	
	// MARK: - 电源相关
	
	private var timeToFullItem: BatteryInfoItem? {
		guard !omitsTimeEstimates else { return nil }
		guard let minutes = snapshot.timeToFullChargeMinutes, minutes > 0, !snapshot.isFull else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "hourglass",
			label: "充满还需",
			value: DurationFormatter.chinese(minutes: minutes),
			iconTint: .green
		)
	}
	
	private var chargingProtocolItem: BatteryInfoItem? {
		guard enabledOptions.contains(.chargingProtocol) else { return nil }
		guard snapshot.powerSource == .powerAdapter else { return nil }
		guard let name = snapshot.chargingProtocol else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "bolt.horizontal.circle.fill",
			label: "充电协议",
			value: name,
			iconTint: .yellow
		)
	}
	
	private var negotiatedTierItem: BatteryInfoItem? {
		guard enabledOptions.contains(.powerTiers) else { return nil }
		guard snapshot.powerSource == .powerAdapter else { return nil }
		guard
			let voltageMV = snapshot.negotiatedVoltageMV,
			let currentMA = snapshot.negotiatedCurrentMA,
			voltageMV > 0, currentMA > 0
		else { return nil }
		
		let watts = Double(voltageMV) * Double(currentMA) / 1_000_000.0
		var value = "\(formatVoltage(voltageMV)) \(formatCurrent(currentMA))（\(formatTierWatts(watts))）"
		if let rated = snapshot.adapterRatedWatts, rated > 0 {
			value += " · 额定\(rated)W"
		}
		return BatteryInfoItem(
			group: .power,
			symbol: "speedometer",
			label: "当前档位",
			value: value,
			iconTint: .blue
		)
	}
	
	private var availableTiersItem: BatteryInfoItem? {
		guard enabledOptions.contains(.powerTiers) else { return nil }
		guard snapshot.powerSource == .powerAdapter, !snapshot.powerTiers.isEmpty else { return nil }
		
		let parts = snapshot.powerTiers.enumerated().map { index, tier -> String in
			let watts = Double(tier.maxVoltageMV) * Double(tier.maxCurrentMA) / 1_000_000.0
			let text = formatTierWatts(watts)
			return index == snapshot.activeTierIndex ? "✓\(text)" : text
		}
		return BatteryInfoItem(
			group: .power,
			symbol: "square.grid.2x2",
			label: "可选档位",
			value: parts.joined(separator: " / "),
			iconTint: .blue
		)
	}
	
	private var inputPowerItem: BatteryInfoItem? {
		guard enabledOptions.contains(.inputWatts) else { return nil }
		guard let watts = visibleWatts(snapshot.adapterInputPowerW) else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "arrow.down.circle.fill",
			label: "输入功率",
			value: formatWatts(watts),
			iconTint: .teal
		)
	}
	
	private var chargingPowerItem: BatteryInfoItem? {
		guard enabledOptions.contains(.chargingWatts) else { return nil }
		guard snapshot.isCharging, let watts = visibleWatts(snapshot.chargingPowerW) else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "bolt.circle.fill",
			label: "充电功率",
			value: formatWatts(watts),
			iconTint: .green
		)
	}
	
	private var currentPowerItem: BatteryInfoItem? {
		guard enabledOptions.contains(.currentWatts) else { return nil }
		guard let watts = visibleWatts(snapshot.currentPowerW) else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "cpu",
			label: "当前功耗",
			value: formatWatts(watts),
			iconTint: .purple
		)
	}
	
	private var adapterNameItem: BatteryInfoItem? {
		guard enabledOptions.contains(.adapterName) else { return nil }
		guard let name = snapshot.adapterName, !name.isEmpty else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "cable.connector",
			label: "适配器名称",
			value: name
		)
	}
	
	private var adapterManufacturerItem: BatteryInfoItem? {
		guard enabledOptions.contains(.adapterManufacturer) else { return nil }
		guard let value = snapshot.adapterManufacturer, !value.isEmpty else { return nil }
		return BatteryInfoItem(
			group: .power,
			symbol: "building.2",
			label: "制造商",
			value: value
		)
	}
	
	// 充电器档案：认识的充电器打个招呼，第一次见的标出来
	private var chargerProfileItem: BatteryInfoItem? {
		guard enabledOptions.contains(.chargerProfile) else { return nil }
		guard snapshot.powerSource == .powerAdapter, let profile = chargerProfile else { return nil }
		
		let isNew = profile.connectCount <= 1
		return BatteryInfoItem(
			group: .power,
			symbol: isNew ? "sparkles" : "checkmark.seal.fill",
			label: "充电器",
			value: isNew ? "新面孔 · 第一次见" : "老朋友 · 见过 \(profile.connectCount) 次",
			iconTint: isNew ? .orange : .green
		)
	}
	
	// MARK: - 电池相关
	
	private var cycleCountItem: BatteryInfoItem? {
		guard enabledOptions.contains(.cycleCount) else { return nil }
		return BatteryInfoItem(
			group: .battery,
			symbol: "arrow.triangle.2.circlepath",
			label: "循环次数",
			// 对比苹果标称的 1000 次循环寿命，数字才有参照系
			value: snapshot.cycleCount.map { "\($0) / 1000" } ?? "—",
			iconTint: .teal
		)
	}
	
	private var healthItem: BatteryInfoItem? {
		guard enabledOptions.contains(.batteryHealth) else { return nil }
		guard let percent = snapshot.healthPercent else { return nil }
		
		var value = "\(percent)%"
		if let max = snapshot.maxCapacityMAh, let design = snapshot.designCapacityMAh {
			value += "（\(max)/\(design) mAh）"
		}
		return BatteryInfoItem(
			group: .battery,
			symbol: "heart.fill",
			label: "电池健康",
			value: value,
			iconTint: .pink
		)
	}
	
	private var healthTrendItem: BatteryInfoItem? {
		guard enabledOptions.contains(.healthTrend) else { return nil }
		guard let trend = healthTrend else { return nil }
		
		let days = max(1, Int(trend.latest.date.timeIntervalSince(trend.earliest.date) / 86400))
		return BatteryInfoItem(
			group: .battery,
			symbol: "chart.line.uptrend.xyaxis",
			label: "健康趋势",
			value: "\(trend.earliest.healthPercent)% → \(trend.latest.healthPercent)% · 近\(days)天",
			iconTint: .mint
		)
	}
	
	private var temperatureItem: BatteryInfoItem? {
		guard enabledOptions.contains(.batteryTemperature) else { return nil }
		guard let temperature = snapshot.temperatureC else { return nil }
		return BatteryInfoItem(
			group: .battery,
			symbol: "thermometer.medium",
			label: "电池温度",
			value: String(format: "%.1f°C", temperature),
			iconTint: .orange,
			valueTint: temperature >= Double(configuration.highTemperatureThresholdC) ? .orange : nil
		)
	}
	
	// 电池端实时电流电压：正号在充、负号在放，一行看完
	private var batteryCurrentVoltageItem: BatteryInfoItem? {
		guard enabledOptions.contains(.batteryCurrentVoltage) else { return nil }
		guard let voltageMV = snapshot.batteryVoltageMV, let amperageMA = snapshot.batteryAmperageMA else { return nil }
		
		let volts = Double(voltageMV) / 1000
		let amps = Double(amperageMA) / 1000
		let sign = amps > 0 ? "+" : ""
		return BatteryInfoItem(
			group: .battery,
			symbol: "bolt.ring.closed",
			label: "电流电压",
			value: String(format: "%.2fV · \(sign)%.2fA", volts, amps),
			iconTint: .cyan
		)
	}
	
	private var timeToEmptyItem: BatteryInfoItem? {
		guard !omitsTimeEstimates else { return nil }
		guard enabledOptions.contains(.timeRemaining) else { return nil }
		guard snapshot.powerSource == .battery, !snapshot.isCharging else { return nil }
		guard let minutes = snapshot.timeToEmptyMinutes, minutes > 0 else { return nil }
		return BatteryInfoItem(
			group: .battery,
			symbol: "clock",
			label: "剩余可用时间",
			value: DurationFormatter.chinese(minutes: minutes),
			iconTint: .indigo
		)
	}
	
	// 掉电速度基于最近一小时的真实放电记录
	private var drainRateItem: BatteryInfoItem? {
		guard enabledOptions.contains(.drainRate) else { return nil }
		guard snapshot.powerSource == .battery, !snapshot.isCharging else { return nil }
		guard let estimate = drainEstimate else { return nil }
		
		var value = String(format: "%.1f%%/小时", estimate.percentPerHour)
		if let minutes = estimate.estimatedMinutesRemaining, minutes > 0 {
			value += " · 约可用\(DurationFormatter.chinese(minutes: minutes))"
		}
		return BatteryInfoItem(
			group: .battery,
			symbol: "arrow.down.right.circle",
			label: "掉电速度",
			value: value,
			iconTint: .red
		)
	}
	
	private var uptimeItem: BatteryInfoItem? {
		guard enabledOptions.contains(.uptime) else { return nil }
		return BatteryInfoItem(
			group: .battery,
			symbol: "desktopcomputer",
			label: "开机时长",
			value: formatUptime(snapshot.systemUptimeSeconds) ?? "—",
			iconTint: .gray
		)
	}
	
	// 上一觉合盖掉了多少电；没掉电或超过一天的旧记录不再展示
	private var sleepDrainItem: BatteryInfoItem? {
		guard enabledOptions.contains(.sleepDrainReport) else { return nil }
		guard let record = sleepDrain, record.droppedPercent >= 1 else { return nil }
		guard Date().timeIntervalSince(record.wakeDate) < 24 * 3600 else { return nil }
		
		// 跟提醒同一套判定：掉得偏快的把数字染橙警示
		let isHeavy = record.durationMinutes >= 60 && record.dropPerHour >= 2
		return BatteryInfoItem(
			group: .battery,
			symbol: "moon.zzz.fill",
			label: "睡眠掉电",
			value: String(format: "合盖%@ 掉了%d%%（%.1f%%/小时）", DurationFormatter.chinese(minutes: record.durationMinutes), record.droppedPercent, record.dropPerHour),
			iconTint: .indigo,
			valueTint: isHeavy ? .orange : nil
		)
	}
	
	// MARK: - 格式化辅助
	
	private func visibleWatts(_ value: Double?) -> Double? {
		guard let value, value >= IOKitBatteryReader.minimumVisibleWatts else { return nil }
		return value
	}
	
	private func formatWatts(_ value: Double) -> String {
		String(format: "%.2fW", value)
	}
	
	private func formatTierWatts(_ value: Double) -> String {
		let rounded = value.rounded()
		if abs(value - rounded) < 0.05 { return "\(Int(rounded))W" }
		return String(format: "%.1fW", value)
	}
	
	private func formatVoltage(_ millivolts: Int) -> String {
		let volts = Double(millivolts) / 1000.0
		let rounded = volts.rounded()
		if abs(volts - rounded) < 0.05 { return "\(Int(rounded))V" }
		return String(format: "%.1fV", volts)
	}
	
	private func formatCurrent(_ milliamps: Int) -> String {
		let amps = Double(milliamps) / 1000.0
		let rounded = amps.rounded()
		if abs(amps - rounded) < 0.05 { return "\(Int(rounded))A" }
		return String(format: "%.1fA", amps)
	}
	
	private func formatUptime(_ seconds: TimeInterval) -> String? {
		Self.uptimeFormatter.string(from: seconds)
	}
	
	private func appendIfPresent(_ item: BatteryInfoItem?, to items: inout [BatteryInfoItem]) {
		guard let item else { return }
		items.append(item)
	}
	
	private static let uptimeFormatter: DateComponentsFormatter = {
		let dcf = DateComponentsFormatter()
		var calendar = Calendar.current
		calendar.locale = Locale(identifier: "zh_CN")
		dcf.calendar = calendar
		dcf.allowedUnits = [.day, .hour, .minute]
		dcf.unitsStyle = .abbreviated
		dcf.zeroFormattingBehavior = .dropAll
		return dcf
	}()
}
