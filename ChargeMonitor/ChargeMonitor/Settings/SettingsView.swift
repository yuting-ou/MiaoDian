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
			DiagnosticLog.failureOnce("archive-encode-failed", category: "SettingsView", "历史存档编码失败")
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
		}
	}

	// 全量导入：解析成功后必须二次确认——覆盖历史无法撤销
	private func importArchive() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.json]
		panel.canChooseDirectories = false
		guard
			panel.runModal() == .OK,
			let url = panel.url,
			let data = try? Data(contentsOf: url),
			let archive = BatteryHistoryArchive.decode(data)
		else { return }

		let alert = NSAlert()
		alert.messageText = "导入历史存档？"
		alert.informativeText = "将用存档覆盖当前的充电记录、健康趋势、用电历史等数据，操作无法撤销。"
		alert.addButton(withTitle: "导入")
		alert.addButton(withTitle: "取消")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		historyRecorder.restore(from: archive)
	}
}
