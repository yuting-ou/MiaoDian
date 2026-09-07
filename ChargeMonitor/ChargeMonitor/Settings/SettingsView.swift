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
	// 三层可见性在此落地：资格集（有数据）∩ 用户可见（hidden 之外）→ 列表；
	// 排序读行表阅读序。拖拽微调仍在面板「隐藏卡片」编辑模式，两边同一模型。
	@ViewBuilder
	private var cardManagementSection: some View {
		let configuration = configurationManager.configuration
		let eligible = CardEligibility.eligibleCards(configuration: configuration, facts: eligibilityFacts(configuration: configuration))
		let eligibleIDs = Set(eligible.map(\.rawValue))
		// 自定义布局归一到面板渲染同款（normalize 保证隐藏卡不残留行表）；自动模式按资格序
		let effective = configuration.panelLayout.map { PanelFlow.normalize($0, known: Set(LayoutCard.allCases.map(\.rawValue))) }
		let visibleOrder: [String] = effective.map { layout in
			layout.effectiveRows.flatMap { $0 }.filter { eligibleIDs.contains($0) }
		} ?? eligible.map(\.rawValue)
		let hiddenOrder = (effective?.hidden ?? []).filter { eligibleIDs.contains($0) }

		Section {
			HStack {
				Text("显示/隐藏、排序与默认折叠面板卡片；拖拽微调在面板的「隐藏卡片」编辑模式。")
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
					Button("恢复默认排序") { configurationManager.clearPanelLayout() }
				}
			}
			ForEach(Array(visibleOrder.enumerated()), id: \.element) { index, id in
				if let card = LayoutCard(rawValue: id) {
					cardRow(card, index: index, count: visibleOrder.count, eligible: eligible)
				}
			}
			if !hiddenOrder.isEmpty {
				Divider()
				Text("已隐藏（当前有数据）")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
				ForEach(hiddenOrder, id: \.self) { id in
					if let card = LayoutCard(rawValue: id) {
						hiddenCardRow(card, eligible: eligible)
					}
				}
			}
		} header: {
			Label("卡片管理", systemImage: "rectangle.3.group")
		}
	}

	private func cardRow(_ card: LayoutCard, index: Int, count: Int, eligible: [LayoutCard]) -> some View {
		HStack(spacing: 10) {
			VStack(alignment: .leading, spacing: 2) {
				Text(card.title)
				Text(card.detail)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			}
			Spacer()
			if let option = card.collapseOption {
				Toggle("默认折叠", isOn: collapseBinding(option))
					.toggleStyle(.checkbox)
					.font(.system(size: 11))
			}
			Button { moveCard(card, up: true, eligible: eligible) } label: {
				Image(systemName: "arrow.up")
			}
			.accessibilityLabel("上移「\(card.title)」")
			.disabled(index == 0)
			Button { moveCard(card, up: false, eligible: eligible) } label: {
				Image(systemName: "arrow.down")
			}
			.accessibilityLabel("下移「\(card.title)」")
			.disabled(index >= count - 1)
			Toggle(isOn: visibleBinding(card, eligible: eligible)) {
				Text("显示")
			}
			.labelsHidden()
		}
		.padding(.vertical, 2)
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

	/// 预设覆盖当前自定义布局前确认一次；默认预设 = 清回自动
	private func applyPreset(_ preset: LayoutPreset, eligible: [LayoutCard]) {
		if configurationManager.configuration.panelLayout != nil {
			let alert = NSAlert()
			alert.messageText = "应用「\(preset.title)」预设？"
			alert.informativeText = "将覆盖当前的自定义卡片布局（之后可用「恢复默认排序」回到自动配平）。"
			alert.addButton(withTitle: "应用")
			alert.addButton(withTitle: "取消")
			guard alert.runModal() == .alertFirstButtonReturn else { return }
		}
		let next = PanelPresets.apply(preset, eligible: eligible, base: configurationManager.configuration.panelLayout)
		if let next {
			persistLayout(next)
		} else {
			configurationManager.clearPanelLayout()
		}
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
