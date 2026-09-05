import SwiftUI

struct SignificantEnergySection: View {
	let apps: [SignificantEnergyApp]
	// 样本未攒够一轮（约 2 分钟）：空列表是"还没测出来"，不能谎报"没有耗电大户"
	let isWarmingUp: Bool
	// 本周累计 Top 应用（名称 + 秒数 + 活跃峰值时段）；空则不显示该区块
	let weeklyTop: [(name: String, seconds: Double, window: String?)]
	let onRevealInFinder: (URL?) -> Void

	var body: some View {
		PopoverCard {
			PopoverSectionHeader("高耗电应用")
				.padding(.bottom, 2)

			if apps.isEmpty {
				if isWarmingUp {
					// 诚实的等待：说清还要多久，而不是给一个过早的"没有"
					HStack(spacing: 6) {
						Image(systemName: "hourglass")
							.font(.system(size: 12))
							.foregroundStyle(.secondary)
						Text("正在积累样本（约 2 分钟）…")
							.font(.system(size: PopoverLayout.bodyFontSize, weight: .regular))
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.vertical, PopoverLayout.rowVerticalPadding)
				} else {
					// 没有耗电大户是好消息，直接用绿色对勾说清楚
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
				}
			} else {
				ForEach(apps) { app in
					PopoverActionRow(app.name, icon: app.icon, showsChevron: true) {
						onRevealInFinder(app.bundleURL)
					}
					.help("点按在访达中显示")
				}
			}

			// 本周累计：把"现在谁在耗电"延伸成"这周到底谁最费电"
			if !weeklyTop.isEmpty {
				PopoverSectionHeader("本周累计")
					.padding(.top, 4)
					.padding(.bottom, 2)

				ForEach(Array(weeklyTop.enumerated()), id: \.offset) { index, entry in
					HStack(spacing: 8) {
						Text("\(index + 1)")
							.font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
							.foregroundStyle(index == 0 ? Color.orange : Color.secondary)
							.frame(width: 12)

						VStack(alignment: .leading, spacing: 1) {
							Text(entry.name)
								.font(.system(size: PopoverLayout.bodyFontSize))
								.lineLimit(1)
							// 时段归因：把"谁最费电"细化到"一般几点在费电"
							if let window = entry.window {
								Text("集中在 \(window)")
									.font(.system(size: 9))
									.foregroundStyle(.tertiary)
							}
						}

						Spacer(minLength: 8)

						Text(DurationFormatter.chinese(minutes: Int(entry.seconds / 60)))
							.font(.system(size: 10).monospacedDigit())
							.foregroundStyle(.secondary)
					}
					.padding(.vertical, 2)
				}
			}
		}
	}
}

// 时段用电热力图：一天 24 小时按掉电强度染色，一眼看出哪个时段用电最凶
// 数据是长期累计的日均（HourlyDrainStats），比单日曲线更能反映真实作息
struct HourlyDrainSection: View {
	let stats: HourlyDrainStats
	let isCollapsed: Bool
	let onToggle: () -> Void

	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "时段用电", isCollapsed: isCollapsed, onToggle: onToggle) {
				if let peak = UsagePatternAnalyzer.peakDrainHour(stats) {
					Text("高峰 \(peak) 点")
						.font(.system(size: 10, weight: .semibold).monospacedDigit())
						.foregroundStyle(Color.orange)
				} else if isCollapsed {
					Text("统计中")
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
				}
			}
			.padding(.bottom, isCollapsed ? 0 : 2)

			if !isCollapsed {
				chart
					.padding(.top, 6)
					.accessibilityElement(children: .ignore)
					.accessibilityLabel(accessibilityText)

				HStack {
					Text("0点")
					Spacer()
					Text("6点")
					Spacer()
					Text("12点")
					Spacer()
					Text("18点")
					Spacer()
					Text("23点")
				}
				.font(.system(size: 8))
				.foregroundStyle(.tertiary)
				.monospacedDigit()
				.padding(.top, 3)
			}
		}
	}

	private var averages: [Double] {
		UsagePatternAnalyzer.hourlyAverageDrain(stats)
	}

	private var chart: some View {
		let intensity = UsagePatternAnalyzer.hourlyIntensity(stats)
		return HStack(spacing: 2) {
			ForEach(0..<24, id: \.self) { hour in
				RoundedRectangle(cornerRadius: 2, style: .continuous)
					.fill(HeatmapPalette.cellColor(intensity[hour]))
					.frame(maxWidth: .infinity)
					.frame(height: 26)
					.help("\(hour) 点 · 日均掉电 \(String(format: "%.1f", averages[hour]))%")
			}
		}
	}

	private var accessibilityText: String {
		let intensity = UsagePatternAnalyzer.hourlyIntensity(stats)
		let hotHours = intensity.enumerated().filter { $0.element >= 0.7 }.map(\.offset)
		var text = "时段用电热力图，累计 \(stats.accumulatedDays) 天"
		if let peak = UsagePatternAnalyzer.peakDrainHour(stats) {
			text += "，高峰 \(peak) 点，日均掉电 \(String(format: "%.1f", averages[peak]))%"
		}
		if !hotHours.isEmpty {
			text += "，用电集中时段：" + hotHours.map { "\($0) 点" }.joined(separator: "、")
		}
		return text
	}
}

// 续航换算：把"当前掉电速度"换算成轻度/看视频/开会还能撑多久——
// 比"预计还能用 X 小时"更贴近用户接下来要做的事
struct RuntimeScenarioSection: View {
	let estimate: DrainRateEstimate
	let socPercent: Int
	let isCollapsed: Bool
	let onToggle: () -> Void

	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "续航换算", isCollapsed: isCollapsed, onToggle: onToggle) {
				if isCollapsed, let first = scenarioRows.first {
					Text("轻度可用 \(DurationFormatter.chinese(minutes: first.minutes))")
						.font(.system(size: 10).monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			.padding(.bottom, isCollapsed ? 0 : 2)

			if !isCollapsed {
				Text(String(format: "按当前掉电速度 %.1f%%/小时换算", estimate.percentPerHour))
					.font(.system(size: 9))
					.foregroundStyle(.tertiary)
					.padding(.top, 2)

				ForEach(scenarioRows, id: \.scenario) { row in
					HStack(spacing: 6) {
						Image(systemName: row.scenario.symbolName)
							.font(.system(size: 10, weight: .medium))
							.foregroundStyle(tint(for: row.scenario))
							.frame(width: 14)
						Text(row.scenario.title)
							.font(.system(size: 10.5))
							.foregroundStyle(.secondary)
						Spacer()
						Text("约 \(DurationFormatter.chinese(minutes: row.minutes))")
							.font(.system(size: 10.5, weight: .medium).monospacedDigit())
					}
					.padding(.top, 6)
				}
			}
		}
	}

	private var scenarioRows: [(scenario: RuntimeScenario, minutes: Int)] {
		RuntimeScenarioEstimator.estimates(socPercent: socPercent, percentPerHour: estimate.percentPerHour)
	}

	private func tint(for scenario: RuntimeScenario) -> Color {
		switch scenario {
		case .lightUse: return .green
		case .videoPlayback: return .orange
		case .videoCall: return .blue
		}
	}
}

// 电池身份证：出厂写入硬件的静态信息——序列号、电芯厂商、生产日期、容量、电芯均衡，
// 外加电量计跳变状态（动态）；信息读不到的行自动隐藏
struct BatteryIdentitySection: View {
	let identity: BatteryIdentity
	let maxCapacityMAh: Int?
	let jumpCount30d: Int
	let needsCalibration: Bool
	let isCollapsed: Bool
	let onToggle: () -> Void

	var body: some View {
		PopoverCard {
			CollapsibleSectionHeader(title: "电池身份证", isCollapsed: isCollapsed, onToggle: onToggle) {
				if isCollapsed, let vendor = identity.cellVendorName {
					Text(vendor)
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
				}
			}
			.padding(.bottom, isCollapsed ? 0 : 2)

			if !isCollapsed {
				VStack(alignment: .leading, spacing: 7) {
					if let serial = identity.serialNumber {
						row(label: "序列号", value: serial, monospaced: true, help: serial)
					}
					if let vendor = identity.cellVendorName {
						row(label: "电芯", value: vendor)
					}
					if let dateText = identity.manufactureDateText {
						row(label: "生产日期", value: dateText)
					}
					if let capacityText {
						row(label: "容量", value: capacityText, monospaced: true)
					}
					if let balance = BatteryIdentityDecoder.cellBalanceText(identity.cellVoltagesMV) {
						// 电芯电压是开机时读的一次性快照——不标注会被当成实时值
						row(label: "均衡", value: balance, monospaced: true, tint: balanceTint,
							help: "开机时快照（电芯均衡以周为单位缓慢变化），非实时读数")
					}
					if jumpCount30d > 0 {
						jumpStatus
					}
				}
				.padding(.top, 4)
			}
		}
	}

	// 容量行文本："设计 8694 mAh · 满充 8032 mAh"
	private var capacityText: String? {
		guard let design = identity.designCapacityMAh else { return nil }
		var text = "设计 \(design) mAh"
		if let max = maxCapacityMAh, max > 0 {
			text += " · 满充 \(max) mAh"
		}
		return text
	}

	// 电量计状态：跳变攒够阈值给橙色建议，零星跳变只报数
	private var jumpStatus: some View {
		HStack(alignment: .top, spacing: 5) {
			Image(systemName: needsCalibration ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
				.font(.system(size: 9, weight: .semibold))
				.foregroundStyle(needsCalibration ? Color.orange : Color.secondary)
				.padding(.top, 1)
			Text(jumpText)
				.font(.system(size: 9.5))
				.foregroundStyle(needsCalibration ? Color.orange : Color.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var jumpText: String {
		if needsCalibration {
			return "电量计可能失准：最近 30 天 \(jumpCount30d) 次电量跳变，建议做一次完整充放循环校准"
		}
		return "最近 30 天电量跳变 \(jumpCount30d) 次"
	}

	private var balanceTint: Color? {
		guard let balance = BatteryIdentityDecoder.cellBalance(identity.cellVoltagesMV) else { return nil }
		// 串联电芯压差：≤30mV 健康（绿），>80mV 失衡明显（橙）
		if balance.deltaMV > 80 { return .orange }
		if balance.deltaMV <= 30 { return .green }
		return nil
	}

	private func row(label: String, value: String, monospaced: Bool = false, tint: Color? = nil, help: String? = nil) -> some View {
		HStack(alignment: .firstTextBaseline) {
			Text(label)
				.font(.system(size: 10))
				.foregroundStyle(.secondary)
				.frame(width: 50, alignment: .leading)
			Text(value)
				.font(monospaced ? .system(size: 10, weight: .medium).monospaced() : .system(size: 10.5))
				.foregroundStyle(tint ?? .primary)
				.lineLimit(1)
				.truncationMode(.middle)
				.textSelection(.enabled)
			Spacer(minLength: 0)
		}
		.help(help ?? value)
	}
}

