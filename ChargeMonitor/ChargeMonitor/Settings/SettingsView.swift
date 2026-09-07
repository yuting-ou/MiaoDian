import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 独立偏好设置窗口：把面板里 30+ 个开关从子菜单迁到系统标准设置窗口，
// 按组分区、带图标分区头，每项带一句行内说明，支持搜索；阈值用 Picker 直观调节。
// 通过 ConfigurationManager.shared 单例读写，与面板配置完全同源
struct SettingsView: View {
	@ObservedObject private var configurationManager = ConfigurationManager.shared
	@ObservedObject private var historyRecorder: BatteryHistoryRecorder
	@State private var searchText = ""

	init(historyRecorder: BatteryHistoryRecorder) {
		self.historyRecorder = historyRecorder
	}

	var body: some View {
		Form {
			let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
			if query.isEmpty {
				configSections
			} else {
				searchResults(query)
			}
		}
		.formStyle(.grouped)
		.searchable(text: $searchText, placement: .toolbar, prompt: "搜索设置项")
		.frame(minWidth: 520, minHeight: 680)
	}

	// MARK: - 常规分区（未搜索时）

	@ViewBuilder
	private var configSections: some View {
		ForEach(DisplayOption.Group.allCases, id: \.title) { group in
			Section {
				ForEach(DisplayOption.allCases.filter { $0.group == group }) { option in
					toggleRow(option)
				}

				if group == .alerts {
					thresholdControls
				}
			} header: {
				Label(group.title, systemImage: group.symbol)
			}
		}

		Section("菜单栏显示") {
			Picker("菜单栏内容", selection: menuBarContentBinding) {
				ForEach(MenuBarContent.allCases) { content in
					Text(content.title).tag(content)
				}
			}
		}

		cardManagementSection

		Section {
			Button("导出历史存档…") { exportArchive() }
			Button("导入历史存档…") { importArchive() }
			Text("包含充电记录、健康趋势、用电历史等全部本地数据，换机或重装 macOS 前先导出一份。")
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		} header: {
			Label("数据存档", systemImage: "externaldrive")
		}

		chargerSection

		Section {
			aboutRow
		} header: {
			Label("关于妙电", systemImage: "battery.100percent")
		}

		Section {
			Text("所有数据只保存在本机，不会上传到任何服务器，也不访问任何网络接口。")
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		} header: {
			Label("隐私", systemImage: "hand.raised")
		}
	}

	// MARK: - 搜索结果（标题或说明命中即列出）

	@ViewBuilder
	private func searchResults(_ query: String) -> some View {
		let matches = DisplayOption.allCases.filter {
			$0.title.localizedStandardContains(query) || $0.detail.localizedStandardContains(query)
		}
		Section(matches.isEmpty ? "没有匹配的设置项" : "搜索结果（\(matches.count)）") {
			ForEach(matches) { option in
				toggleRow(option)
			}
		}
	}

	// 每行开关带一句说明，不用悬停就知道每个选项是干嘛的
	private func toggleRow(_ option: DisplayOption) -> some View {
		Toggle(isOn: optionBinding(option)) {
			VStack(alignment: .leading, spacing: 2) {
				Text(option.title)
				Text(option.detail)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			}
		}
	}

	// MARK: - 卡片管理（自定义布局编辑器：与面板编辑模式写同一份 PanelLayout 契约）

	// 主干编辑器放稳定窗口：原生无障碍、只在窗口打开时算资格（body 即打开）。
	// v1.16.0 人性化返工：列表是面板的文字影子——复用 renderSegments 镜像面板行结构
	// （并排两张卡同行呈现），排卡片的空间任务只属于面板拖拽把手，这里管总览+批量开关+预设+后悔药。
	// v1.17.0 稳定清单：镜像行之下恒列已隐藏与暂不可用的卡（库存不随数据搬家），缺席也给原因。
	@ViewBuilder
	private var cardManagementSection: some View {
		let configuration = configurationManager.configuration
		let facts = eligibilityFacts(configuration: configuration)
		let eligible = CardEligibility.eligibleCards(configuration: configuration, facts: facts)
		let eligibleIDs = Set(eligible.map(\.rawValue))
		// 自定义布局归一到面板渲染同款（normalize 保证隐藏卡不残留行表）；自动模式按资格序
		let effective = configuration.panelLayout.map { PanelFlow.normalize($0, known: Set(LayoutCard.allCases.map(\.rawValue))) }
		// 面板同款渲染预备：行表 → 段落（条件不可见的卡跳过、双行剩一卡自动拉通），渲染顺序=行序=阅读序
		let segments = PanelFlow.renderSegments(effective?.effectiveRows ?? PanelPresets.paired(eligible), available: eligibleIDs)
		// 稳定清单（v1.17.0）：库存恒列——已隐藏/暂不可用的卡不因缺数据从设置里消失，各占一行并说明原因
		let stable = CardList.stableList(configuration: configuration, facts: facts)
		let hiddenCards = stable.compactMap { $0.status == .hidden ? $0.card : nil }
		let unavailableEntries = stable.filter { entry in
			if case .unavailable = entry.status { return true }
			return false
		}

		Section {
			HStack {
				Text("调位置在面板拖卡片把手，这里管批量开关与预设。下面的行就是面板里的行，并排的两张卡显示在同一行。")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack(spacing: 10) {
				Menu {
					ForEach(LayoutPreset.allCases) { preset in
						Button { applyPreset(preset, eligible: eligible) } label: {
							VStack(alignment: .leading, spacing: 1) {
								Text(preset.title)
								Text(preset.detail)
									.font(.system(size: 11))
									.foregroundStyle(.secondary)
							}
						}
					}
				} label: {
					Text("应用预设")
				}
				Spacer()
				if configuration.panelLayout != nil {
					Button("恢复默认布局") { confirmResetLayout() }
						.help("行序回出厂，隐藏的卡全部回来")
				}
				if configuration.canUndoLayout {
					Button {
						configurationManager.undoLastLayoutChange()
					} label: {
						Label("撤销上次布局改动", systemImage: "arrow.uturn.backward")
					}
					.help(configuration.undoWasAuto ? "回到本次预设/恢复默认之前的自动模式" : "回到本次预设/恢复默认之前你自己的布局")
				}
			}
			// Segment 全板唯一（卡不重复），以内容为身份：行形态变化时 SwiftUI 逐行 diff 而非整体错位
			ForEach(segments, id: \.self) { segment in
				switch segment {
				case .full(let id):
					if let card = LayoutCard(rawValue: id) {
						cardRow(card, eligible: eligible)
					}
				case .pair(let leftID, let rightID):
					if let left = LayoutCard(rawValue: leftID), let right = LayoutCard(rawValue: rightID) {
						HStack(alignment: .top, spacing: 12) {
							cardRow(left, eligible: eligible)
								.frame(maxWidth: .infinity, alignment: .leading)
							Divider()
							cardRow(right, eligible: eligible)
								.frame(maxWidth: .infinity, alignment: .leading)
						}
					}
				}
			}
			if !hiddenCards.isEmpty {
				Divider()
				Text("已隐藏")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
				ForEach(hiddenCards, id: \.id) { card in
					hiddenCardRow(card, eligible: eligible)
				}
			}
			if !unavailableEntries.isEmpty {
				Divider()
				Text("暂不可用（数据够了会自动出现）")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
				ForEach(unavailableEntries.indices, id: \.self) { index in
					unavailableCardRow(unavailableEntries[index].card, status: unavailableEntries[index].status)
				}
			}
		} header: {
			Label("卡片管理", systemImage: "rectangle.3.group")
		}
	}

	// 一行 = 面板里的一张卡。宽卡独占整行；并排两卡各占半行（中间分隔线对应面板的半宽分界）。
	// 每张卡的控件跟着自己的卡走：默认折叠勾选 / 阅读序菜单（键盘·VoiceOver 兜底）/ 面板显示开关。
	// 排位置仍以面板拖拽把手为准，这里只做总览与批量开关。
	private func cardRow(_ card: LayoutCard, eligible: [LayoutCard]) -> some View {
		HStack(spacing: 6) {
			VStack(alignment: .leading, spacing: 2) {
				Text(card.title)
				Text(card.detail)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}
			Spacer(minLength: 4)
			if let option = card.collapseOption {
				Toggle("默认折叠", isOn: collapseBinding(option))
					.toggleStyle(.checkbox)
					.font(.system(size: 11))
					.labelsHidden()
					.help("默认折叠「\(card.title)」")
			}
			Menu {
				Button("上移一位") { moveCard(card, up: true, eligible: eligible) }
					.disabled(readingOrderPosition(card, in: eligible)?.index == 0)
				Button("下移一位") { moveCard(card, up: false, eligible: eligible) }
					.disabled(readingOrderPosition(card, in: eligible).map { $0.index == $0.count - 1 } ?? true)
			} label: {
				Image(systemName: "arrow.up.arrow.down")
					.font(.system(size: 11))
			}
			.menuIndicator(.hidden)
			.fixedSize()
			.accessibilityLabel("调整「\(card.title)」阅读序")
			.help("阅读序兜底微调（排位置在面板拖卡片把手）")
			Toggle(isOn: visibleBinding(card, eligible: eligible)) {
				Text("面板显示")
					.font(.system(size: 11))
			}
		}
		.padding(.vertical, 2)
	}

	// 阅读序位置（no-op 判定用）：index/count 同源——自定义布局的行表可能含数据暂时
	// 消失的卡（面板同样保留其位置），禁用判定必须与 move 纯函数走同一份全序。
	private func readingOrderPosition(_ card: LayoutCard, in eligible: [LayoutCard]) -> (index: Int, count: Int)? {
		let layout = configurationManager.configuration.panelLayout
		let order = layout.map { PanelFlow.normalize($0, known: Set(LayoutCard.allCases.map(\.rawValue))).effectiveRows.flatMap { $0 } }
			?? eligible.map(\.rawValue)
		guard let index = order.firstIndex(of: card.rawValue) else { return nil }
		return (index, order.count)
	}

	private func hiddenCardRow(_ card: LayoutCard, eligible: [LayoutCard]) -> some View {
		HStack(spacing: 10) {
			VStack(alignment: .leading, spacing: 2) {
				Text(card.title)
					.foregroundStyle(.secondary)
				Text(card.detail)
					.font(.system(size: 11))
					.foregroundStyle(.tertiary)
			}
			Spacer()
			Button("显示") {
				persistLayout(PanelFlow.unhide(layoutForEditing(eligible: eligible), card: card.rawValue))
			}
			.accessibilityLabel("显示「\(card.title)」")
		}
		.padding(.vertical, 2)
	}

	// 暂不可用行（v1.17.0 稳定清单的缺位库存）：缺席的原因说给用户听——开关关→说开关，
	// 缺数据→说还差什么。面板显示开关按 isToggleEnabled 禁用（暂不可用=唯一禁用态），
	// 开关本身通常已开（未隐藏），卡不在场是数据/功能门的事，开关此刻无操作语义。
	private func unavailableCardRow(_ card: LayoutCard, status: CardListStatus) -> some View {
		// v1.17.2：去掉恒灰的假开关——「面板显示」在暂不可用态恒为开+禁用，用户去点
		// 没反应（假可供性），VoiceOver 还读"面板显示，1"；缺席原因本身已说明一切，
		// 行里只留卡名 + 缺什么。恢复开关是 isToggleEnabled 唯一 UI 用途，随之删除（防死代码）。
		HStack(spacing: 10) {
			VStack(alignment: .leading, spacing: 2) {
				Text(card.title)
					.foregroundStyle(.tertiary)
				if case .unavailable(let reason) = status {
					Text(reason)
						.font(.system(size: 11))
						.foregroundStyle(.tertiary)
						.lineLimit(2)
				}
			}
			Spacer()
		}
		.padding(.vertical, 2)
		.accessibilityElement(children: .combine)
		.accessibilityLabel("\(card.title)，暂不可用：\(status.reasonText)")
	}

	// MARK: - 卡片管理写路径（全部走 CardEligibility/PanelFlow 纯函数，与面板同源）

	/// 自动模式下第一次改动先按资格阅读序播种行存储（语义对齐面板编辑入口的播种）
	private func layoutForEditing(eligible: [LayoutCard]) -> PanelLayout {
		configurationManager.configuration.panelLayout ?? PanelPresets.seed(eligible: eligible)
	}

	private func persistLayout(_ layout: PanelLayout) {
		configurationManager.setPanelLayout(PanelFlow.normalize(layout, known: Set(LayoutCard.allCases.map(\.rawValue))))
	}

	private func moveCard(_ card: LayoutCard, up: Bool, eligible: [LayoutCard]) {
		persistLayout(PanelFlow.move(layoutForEditing(eligible: eligible), card: card.rawValue, up: up))
	}

	private func visibleBinding(_ card: LayoutCard, eligible: [LayoutCard]) -> Binding<Bool> {
		Binding(
			get: { !(configurationManager.configuration.panelLayout?.hidden.contains(card.rawValue) ?? false) },
			set: { visible in
				let base = layoutForEditing(eligible: eligible)
				persistLayout(visible
					? PanelFlow.unhide(base, card: card.rawValue)
					: PanelFlow.hide(base, card: card.rawValue))
			}
		)
	}

	private func collapseBinding(_ option: DisplayOption) -> Binding<Bool> {
		Binding(
			get: { configurationManager.configuration.collapsedCards.contains(option.rawValue) },
			set: { desired in
				guard configurationManager.configuration.collapsedCards.contains(option.rawValue) != desired else { return }
				configurationManager.toggleCardCollapsed(option)
			}
		)
	}

	/// 预设覆盖当前自定义布局前确认一次；默认预设 = 清回自动。
	/// 覆盖前自动快照当前布局进 lastCustomLayout/undoWasAuto（后悔药），确认弹窗与「恢复默认布局」对称。
	private func applyPreset(_ preset: LayoutPreset, eligible: [LayoutCard]) {
		if configurationManager.configuration.panelLayout != nil {
			let alert = NSAlert()
			alert.messageText = "应用「\(preset.title)」预设？"
			alert.informativeText = "将覆盖当前的自定义卡片布局（当前显示 \(CardList.shownCount(eligible: eligible, hidden: configurationManager.configuration.panelLayout?.hidden ?? [])) 张卡；之前的布局已自动留存，可点「撤销上次布局改动」找回）。"
			alert.addButton(withTitle: "应用")
			alert.addButton(withTitle: "取消")
			guard alert.runModal() == .alertFirstButtonReturn else { return }
		}
		configurationManager.snapshotLayoutForUndo()
		let next = PanelPresets.apply(preset, eligible: eligible, base: configurationManager.configuration.panelLayout)
		if let next {
			persistLayout(next)
		} else {
			configurationManager.clearPanelLayout()
		}
	}

	/// 恢复默认布局（v1.17.0 名副其实化）：行序回出厂，且已隐藏的卡全部回来。
	/// 覆盖前确认一次；快照+清空走 restoreDefaultLayout 原子组合子（先留后悔药再破坏），与预设弹窗对称。
	private func confirmResetLayout() {
		let alert = NSAlert()
		alert.messageText = "恢复默认布局？"
		alert.informativeText = "卡片将回到自动配平的阅读序，已隐藏的卡也会全部回来（之前的布局已自动留存，可点「撤销上次布局改动」找回）。"
		alert.addButton(withTitle: "恢复默认")
		alert.addButton(withTitle: "取消")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		configurationManager.restoreDefaultLayout()
	}

	/// 资格事实快照：与面板 visibleCards 同源的数据在场判定（设置窗口打开时才计算）
	private func eligibilityFacts(configuration: AppConfiguration) -> CardEligibilityFacts {
		let services = AppServices.shared
		let monitor = services.monitor
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
		var facts = CardEligibilityFacts()
		facts.hasPowerItems = !formatter.makeItems(in: .power).isEmpty
		facts.hasBatteryItems = !formatter.makeItems(in: .battery).isEmpty
		facts.hasChargeHistory = !historyRecorder.recentSessions.isEmpty
		facts.hasCheckup = monitor.snapshot.healthPercent != nil
		facts.hasBatteryIdentity = monitor.batteryIdentity?.isMeaningful ?? false
		facts.hasHabitInsight = CardEligibility.hasHabitInsight(
			events: historyRecorder.powerEvents,
			dailyHistory: historyRecorder.dailyHistory,
			snapshot: monitor.snapshot,
			careHolding: configuration.enabledOptions.contains(.chargeCareReminder)
				&& services.alertController.isOptimizedChargingHolding,
			careThresholdPercent: configuration.chargeCareThresholdPercent,
			drain: historyRecorder.hourlyDrainStats,
			temp: historyRecorder.hourlyTempStats,
			currentCharger: historyRecorder.currentChargerProfile,
			knownChargers: historyRecorder.chargerProfiles
		)
		facts.hasTemperatureSamples = monitor.temperatureSamples.count >= 2
		facts.showsHealthCurve = showsHealthCurve
		facts.hasDailySummary = historyRecorder.todayUsage.map { $0.drainedPercent > 0 || $0.chargedPercent > 0 } ?? false
		facts.hasUsageCalendar = historyRecorder.dailyHistory.count >= 3
		facts.hasHourlyDrain = historyRecorder.hourlyDrainStats.accumulatedDays >= 3
		facts.hasSOCSamples = historyRecorder.socSamples.count >= 2
		facts.hasPowerSamples = monitor.powerSamples.count >= 2
		facts.hasRuntimeScenarios = monitor.snapshot.powerSource == .battery
			&& (monitor.drainEstimate?.percentPerHour ?? 0) > 0
			&& monitor.snapshot.stateOfChargePercent != nil
		facts.hasPowerEvents = !historyRecorder.powerEvents.isEmpty
		facts.hasBluetoothDevices = !monitor.bluetoothDevices.isEmpty
		return facts
	}

	// 关于区：图标 + 名称 + 版本，比单行 LabeledContent 更有质感
	private var aboutRow: some View {
		HStack(spacing: 12) {
			Image(systemName: "battery.100percent")
				.font(.system(size: 30, weight: .medium))
				.symbolRenderingMode(.hierarchical)
				.foregroundStyle(.tint)

			VStack(alignment: .leading, spacing: 2) {
				Text("妙电")
					.font(.system(size: 15, weight: .semibold))
				Text("版本 \(appVersion)")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			}
		}
		.padding(.vertical, 4)
	}

	private var appVersion: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
	}

	// MARK: - 充电器命名

	// 系统只认得苹果原厂头，第三方氮化镓大多只报额定瓦数——
	// 让用户给认不出的头认领名字，面板/报告/慢充洞察立刻说人话
	@ViewBuilder
	private var chargerSection: some View {
		Section {
			if historyRecorder.chargerProfiles.isEmpty {
				Text("还没有见过充电器。插上电源后，这里会列出每只充电器，给认不出的起个名字。")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			} else {
				ForEach(historyRecorder.chargerProfiles.sorted { $0.lastSeen > $1.lastSeen }, id: \.key) { profile in
					chargerRow(profile)
				}
			}
		} header: {
			Label("充电器", systemImage: "powerplug")
		}
	}

	private func chargerRow(_ profile: ChargerProfile) -> some View {
		VStack(alignment: .leading, spacing: 5) {
			HStack {
				Text(profile.displayName)
					.font(.system(size: 13, weight: .medium))
				Spacer()
				Text("见过 \(profile.connectCount) 次")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			}
			TextField("起个名字，如「Anker 65W · 桌面」", text: customNameBinding(profile.key))
			.font(.system(size: 12))
			// 两只同瓦数的头靠档位表辨认（不同品牌/型号广播的 PDO 组合不同）
			if let signature = profile.tierSignature, !signature.isEmpty {
				Text("PD 档位：\(signature)")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
			}
			if profile.name.isEmpty {
				Text("系统未识别出名称（额定 \(profile.ratedWatts.map(String.init) ?? "未知")W），命名后面板与报告都会用这个名字")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
			} else if profile.customName?.isEmpty ?? true {
				Text("系统识别：\(profile.name)")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
			}
		}
		.padding(.vertical, 3)
	}

	private func customNameBinding(_ key: String) -> Binding<String> {
		Binding(
			get: { historyRecorder.chargerProfiles.first { $0.key == key }?.customName ?? "" },
			set: { historyRecorder.setChargerCustomName(key: key, customName: $0) }
		)
	}

	// MARK: - 数值阈值（数据驱动：标题/候选值/单位/键路径一处一张表）

	private struct ThresholdConfig {
		let title: String
		let values: [Int]
		let unit: String
		let keyPath: WritableKeyPath<AppConfiguration, Int>
	}

	private var thresholdConfigs: [ThresholdConfig] {
		[
			ThresholdConfig(title: "低电量警示线", values: [10, 15, 20, 25, 30], unit: "%", keyPath: \.lowBatteryThresholdPercent),
			ThresholdConfig(title: "高温警示线", values: [35, 38, 40, 42, 45], unit: "°C", keyPath: \.highTemperatureThresholdC),
			ThresholdConfig(title: "保养提醒线", values: [70, 75, 80, 85, 90], unit: "%", keyPath: \.chargeCareThresholdPercent),
			ThresholdConfig(title: "外设低电线", values: [10, 15, 20, 25, 30], unit: "%", keyPath: \.deviceLowThresholdPercent),
			ThresholdConfig(title: "耗电异常线", values: [15, 20, 25, 30], unit: "%/小时", keyPath: \.highDrainThresholdPerHour),
			ThresholdConfig(title: "免打扰开始", values: [21, 22, 23, 0, 1], unit: "点", keyPath: \.quietHoursStartHour),
			ThresholdConfig(title: "免打扰结束", values: [5, 6, 7, 8, 9, 10], unit: "点", keyPath: \.quietHoursEndHour)
		]
	}

	@ViewBuilder
	private var thresholdControls: some View {
		Divider()
		ForEach(thresholdConfigs, id: \.title) { config in
			Picker(config.title, selection: intBinding(config.keyPath)) {
				ForEach(config.values, id: \.self) { value in
					Text("\(value)\(config.unit)").tag(value)
				}
			}
		}
	}

	private func intBinding(_ keyPath: WritableKeyPath<AppConfiguration, Int>) -> Binding<Int> {
		Binding(
			get: { configurationManager.configuration[keyPath: keyPath] },
			set: { configurationManager.setValue($0, at: keyPath) }
		)
	}

	private func optionBinding(_ option: DisplayOption) -> Binding<Bool> {
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

	// MARK: - 数据存档（换机/重装的数据逃生舱）

	private static let archiveDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		return formatter
	}()

	// 全量导出：JSON 人可读，写入用户选的位置后在访达中亮出
	private func exportArchive() {
		guard let data = BatteryHistoryArchive.encode(historyRecorder.makeArchive()) else {
			showArchiveAlert(title: "导出失败", body: "历史存档编码失败，请查看诊断日志。")
			return
		}
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.json]
		panel.nameFieldStringValue = "妙电历史存档-\(Self.archiveDateFormatter.string(from: Date())).json"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			try data.write(to: url, options: .atomic)
			NSWorkspace.shared.activateFileViewerSelecting([url])
		} catch {
			DiagnosticLog.failureOnce("archive-export-failed", category: "SettingsView", "历史存档写入失败：\(error.localizedDescription)")
			showArchiveAlert(title: "导出失败", body: "无法写入所选位置：\(error.localizedDescription)")
		}
	}

	// 全量导入：解析成功后必须二次确认——覆盖历史无法撤销
	private func importArchive() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.json]
		panel.canChooseDirectories = false
		guard panel.runModal() == .OK, let url = panel.url else { return }
		guard
			let data = try? Data(contentsOf: url),
			let archive = BatteryHistoryArchive.decode(data)
		else {
			// 选了文件却解析失败必须说清楚——静默返回会让人以为按钮坏了
			showArchiveAlert(title: "无法解析该存档", body: "文件可能已损坏，或来自更高版本的妙电。")
			return
		}

		let alert = NSAlert()
		alert.messageText = "导入历史存档？"
		alert.informativeText = "将用存档覆盖当前的充电记录、健康趋势、用电历史等数据，操作无法撤销。"
		alert.addButton(withTitle: "导入")
		alert.addButton(withTitle: "取消")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		historyRecorder.restore(from: archive)
		// 恢复后面板数字会突变——主动回执说清是导入生效，不是应用出 bug
		showArchiveAlert(title: "导入完成", body: archive.importSummary, style: .informational)
	}

	private func showArchiveAlert(title: String, body: String, style: NSAlert.Style = .warning) {
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = body
		alert.alertStyle = style
		alert.addButton(withTitle: "好")
		alert.runModal()
	}
}
