import AppKit
import Foundation
import SwiftUI

// 妙电 纯逻辑单元测试
// 用法：bash 测试/run_tests.sh（与主程序共用同一批源文件编译，测的是真代码）

var passed = 0
var failedNames: [String] = []

func expect(_ condition: Bool, _ name: String) {
	if condition {
		passed += 1
	} else {
		failedNames.append(name)
		print("❌ \(name)")
	}
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
	if actual == expected {
		passed += 1
	} else {
		failedNames.append(name)
		print("❌ \(name)：得到 \(actual)，期望 \(expected)")
	}
}

func batterySnap(percent: Int?, charging: Bool = false, onBattery: Bool = true) -> BatterySnapshot {
	var s = BatterySnapshot()
	s.powerSource = onBattery ? .battery : .powerAdapter
	s.isCharging = charging
	s.stateOfChargePercent = percent
	return s
}

let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

// MARK: - DrainRateEstimator

// 每 2 分钟采一次，30 分钟内 100% → 95%，标准掉电场景
func fillDischargeSeries(_ estimator: inout DrainRateEstimator) {
	for i in 0...15 {
		estimator.record(
			snapshot: batterySnap(percent: 100 - i / 3),
			at: t0.addingTimeInterval(Double(i) * 120)
		)
	}
}

do {
	var estimator = DrainRateEstimator()
	fillDischargeSeries(&estimator)
	let estimate = estimator.estimate()
	expect(estimate != nil, "掉电估算：正常放电 30 分钟应给出估算")
	if let estimate {
		expect(abs(estimate.percentPerHour - 10.0) < 0.01, "掉电估算：5%/30分钟 = 10%/小时")
		expectEqual(estimate.estimatedMinutesRemaining, 570, "掉电估算：95% 按 10%/小时 = 570 分钟")
	}
	
	// 睡眠断档：距上次采样 10 分钟（远超 3 分钟阈值）应清空重来
	estimator.record(snapshot: batterySnap(percent: 94), at: t0.addingTimeInterval(2400))
	expect(estimator.estimate() == nil, "掉电估算：跨睡眠断档后应重置（不给失真估算）")
}

do {
	var estimator = DrainRateEstimator()
	fillDischargeSeries(&estimator)
	estimator.record(snapshot: batterySnap(percent: 95, charging: true, onBattery: false), at: t0.addingTimeInterval(1920))
	expect(estimator.estimate() == nil, "掉电估算：开始充电后应清空")
}

do {
	var estimator = DrainRateEstimator()
	estimator.record(snapshot: batterySnap(percent: 100), at: t0)
	estimator.record(snapshot: batterySnap(percent: 99), at: t0.addingTimeInterval(120))
	estimator.record(snapshot: batterySnap(percent: 100), at: t0.addingTimeInterval(240))
	expect(estimator.estimate() == nil, "掉电估算：电量回升应重置")
}

do {
	var estimator = DrainRateEstimator()
	estimator.record(snapshot: batterySnap(percent: 100), at: t0)
	estimator.record(snapshot: batterySnap(percent: 99), at: t0.addingTimeInterval(120))
	expect(estimator.estimate() == nil, "掉电估算：数据不足 10 分钟不给估算")
}

do {
	var estimator = DrainRateEstimator()
	for i in 0...6 {
		estimator.record(snapshot: batterySnap(percent: 100), at: t0.addingTimeInterval(Double(i) * 120))
	}
	expect(estimator.estimate() == nil, "掉电估算：电量没掉不给估算")
}

// 滑动窗口：先快掉后慢掉共 90 分钟，估算应只反映最近一小时（旧数据要被淘汰）
do {
	var estimator = DrainRateEstimator()
	// 每 2 分钟采样：前 30 分钟 100%→90%（20%/小时），后 60 分钟 90%→85%（5%/小时）
	for i in 0...45 {
		let minute = i * 2
		let percent = minute <= 30 ? 100 - minute / 3 : 90 - (minute - 30) / 12
		estimator.record(snapshot: batterySnap(percent: percent), at: t0.addingTimeInterval(Double(minute) * 60))
	}
	let estimate = estimator.estimate()
	expect(estimate != nil, "掉电估算：90 分钟连续放电应给出估算")
	if let estimate {
		expect(abs(estimate.percentPerHour - 5.0) < 0.01, "掉电估算：滑动窗口应只按最近一小时算（5%/小时，不是全程的 10%）")
		expectEqual(estimate.estimatedMinutesRemaining, 1020, "掉电估算：85% 按 5%/小时 = 1020 分钟")
	}
}

// MARK: - BatterySnapshot.healthPercent

do {
	var s = BatterySnapshot()
	s.designCapacityMAh = 4720
	s.maxCapacityMAh = 4500
	expectEqual(s.healthPercent, 95, "健康度：4500/4720 应为 95%")
	
	s.designCapacityMAh = 0
	expect(s.healthPercent == nil, "健康度：设计容量为 0 不应除零")
	
	s.designCapacityMAh = nil
	expect(s.healthPercent == nil, "健康度：缺数据应为 nil")
}

// MARK: - ChargeSession

do {
	let session = ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(300), startPercent: 40, endPercent: 45, peakInputW: 60)
	expectEqual(session.durationMinutes, 5, "充电会话：5 分钟时长计算")
	
	let instant = ChargeSession(startDate: t0, endDate: t0, startPercent: 40, endPercent: 40, peakInputW: 0)
	expectEqual(instant.durationMinutes, 1, "充电会话：零时长兜底为 1 分钟")
}

// 旧版存档没有 curve 字段，解码不应炸，曲线为空
do {
	let legacyJSON = #"[{"startDate":0,"endDate":300,"startPercent":40,"endPercent":45,"peakInputW":60}]"#.data(using: .utf8)!
	let decoder = JSONDecoder()
	decoder.dateDecodingStrategy = .secondsSince1970
	let sessions = try decoder.decode([ChargeSession].self, from: legacyJSON)
	expectEqual(sessions.count, 1, "充电曲线：旧存档解码成功")
	expect(sessions.first?.curve == nil, "充电曲线：旧存档没曲线字段应为 nil")
} catch {
	expect(false, "充电曲线：旧存档解码不应失败（\(error)）")
}

// MARK: - AppConfiguration 旧版迁移

do {
	let legacyJSON = #"{"enabledOptions":["cycleCount"],"menuBarContent":"icon"}"#.data(using: .utf8)!
	let legacy = try JSONDecoder().decode(AppConfiguration.self, from: legacyJSON)
	let migrated = legacy.normalized()
	expect(migrated.enabledOptions.contains(.powerChart), "配置迁移：新增选项应按默认开启")
	expect(migrated.enabledOptions.contains(.cycleCount), "配置迁移：用户已开的选项应保留")
	expect(!migrated.enabledOptions.contains(.adapterName), "配置迁移：旧版已知但未开的选项不应被强行开启")
	expect(!migrated.enabledOptions.contains(.startAtLogin), "配置迁移：不应私自开启登录时启动")
	expect(!migrated.enabledOptions.contains(.chargeCareReminder), "配置迁移：保养提醒默认不开")
	expect(migrated.enabledOptions.contains(.dailySummary), "配置迁移：今日小结应按默认开启")
	expect(migrated.enabledOptions.contains(.temperatureChart), "配置迁移：温度曲线应按默认开启")
	expectEqual(migrated.lowBatteryThresholdPercent, 20, "配置迁移：旧版无低电阈值字段应给默认 20")
	expectEqual(migrated.highTemperatureThresholdC, 40, "配置迁移：旧版无高温阈值字段应给默认 40")
	expectEqual(migrated.knownOptions, Set(DisplayOption.allCases), "配置迁移：knownOptions 应补全")
} catch {
	expect(false, "配置迁移：旧版 JSON 解码不应失败（\(error)）")
}

// 阈值夹紧：手改存档或异常值不能把警示线带到离谱区间
do {
	var config = AppConfiguration()
	config.lowBatteryThresholdPercent = 3
	config.highTemperatureThresholdC = 90
	let fixed = config.normalized()
	expectEqual(fixed.lowBatteryThresholdPercent, 5, "阈值夹紧：低电阈值下限 5")
	expectEqual(fixed.highTemperatureThresholdC, 50, "阈值夹紧：高温阈值上限 50")
	
	config.lowBatteryThresholdPercent = 99
	config.highTemperatureThresholdC = 10
	let fixed2 = config.normalized()
	expectEqual(fixed2.lowBatteryThresholdPercent, 50, "阈值夹紧：低电阈值上限 50")
	expectEqual(fixed2.highTemperatureThresholdC, 35, "阈值夹紧：高温阈值下限 35")
}

// MARK: - BatteryInfoFormatter

let fullConfig = AppConfiguration()

do {
	var s = BatterySnapshot()
	s.powerSource = .powerAdapter
	s.isCharging = true
	s.stateOfChargePercent = 50
	s.timeToFullChargeMinutes = 90
	s.cycleCount = 163
	s.designCapacityMAh = 4720
	s.maxCapacityMAh = 4500
	s.temperatureC = 40.0
	s.negotiatedVoltageMV = 20000
	s.negotiatedCurrentMA = 3000
	s.adapterRatedWatts = 100
	s.adapterInputPowerW = 12.5
	
	let items = BatteryInfoFormatter(snapshot: s, configuration: fullConfig).makeItems()
	func value(_ label: String) -> String? { items.first { $0.label == label }?.value }
	
	expectEqual(value("充满还需"), "1小时30分钟", "信息行：充满还需 90 分钟格式化")
	expectEqual(value("循环次数"), "163 / 1000", "信息行：循环次数带 1000 参照系")
	expectEqual(value("电池健康"), "95%（4500/4720 mAh）", "信息行：健康度带容量明细")
	expectEqual(value("当前档位"), "20V 3A（60W） · 额定100W", "信息行：协商档位格式化")
	expectEqual(value("输入功率"), "12.50W", "信息行：功率数字与单位之间不加空格")
	expect(items.first { $0.label == "电池温度" }?.valueTint == Color.orange, "信息行：40°C 应染橙色")
	
	let omitted = BatteryInfoFormatter(snapshot: s, configuration: fullConfig, omitsTimeEstimates: true).makeItems()
	expect(!omitted.contains { $0.label == "充满还需" }, "信息行：面板模式不重复展示充满还需")
	
	var cool = s
	cool.temperatureC = 39.9
	let coolItems = BatteryInfoFormatter(snapshot: cool, configuration: fullConfig).makeItems()
	expect(coolItems.first { $0.label == "电池温度" }?.valueTint == nil, "信息行：39.9°C 不应染色")
}

do {
	var s = batterySnap(percent: 80)
	s.timeToEmptyMinutes = 125
	let estimate = DrainRateEstimate(percentPerHour: 5.0, estimatedMinutesRemaining: 120)
	let items = BatteryInfoFormatter(snapshot: s, configuration: fullConfig, drainEstimate: estimate).makeItems()
	
	expectEqual(items.first { $0.label == "剩余可用时间" }?.value, "2小时5分钟", "信息行：剩余时间 125 分钟格式化")
	expectEqual(items.first { $0.label == "掉电速度" }?.value, "5.0%/小时 · 约可用2小时", "信息行：掉电速度格式化")
}

// 时长格式化边界：整小时不带分钟，不满一小时不带小时
do {
	var s = batterySnap(percent: 80)
	s.timeToEmptyMinutes = 59
	let items = BatteryInfoFormatter(snapshot: s, configuration: fullConfig).makeItems()
	expectEqual(items.first { $0.label == "剩余可用时间" }?.value, "59分钟", "信息行：59 分钟不带小时")
	
	var full = BatterySnapshot()
	full.powerSource = .powerAdapter
	full.isCharging = true
	full.stateOfChargePercent = 50
	full.timeToFullChargeMinutes = 60
	let items2 = BatteryInfoFormatter(snapshot: full, configuration: fullConfig).makeItems()
	expectEqual(items2.first { $0.label == "充满还需" }?.value, "1小时", "信息行：整 60 分钟只显示小时")
	
	// 已充满时不应再显示充满还需（哪怕系统还残留一个分钟数）
	full.isFull = true
	let items3 = BatteryInfoFormatter(snapshot: full, configuration: fullConfig).makeItems()
	expect(!items3.contains { $0.label == "充满还需" }, "信息行：已充满不显示充满还需")
}

do {
	var s = batterySnap(percent: 80)
	s.isLowPowerModeEnabled = true
	let lines = BatteryInfoFormatter(snapshot: s, configuration: fullConfig).makeLines()
	expect(lines.contains("低电量模式：已开启"), "报告：低电量模式行")
	expect(lines.contains("电源来源：电池"), "报告：电源来源行")
	
	var adapter = batterySnap(percent: 80, onBattery: false)
	adapter.isCharging = false
	let lines2 = BatteryInfoFormatter(snapshot: adapter, configuration: fullConfig).makeLines()
	expect(lines2.contains("电池未在充电"), "报告：插电未充电警示行")
	
	var charging = batterySnap(percent: 50, charging: true, onBattery: false)
	charging.isFastCharging = false
	let lines3 = BatteryInfoFormatter(snapshot: charging, configuration: fullConfig).makeLines()
	expect(lines3.contains("充电：50%"), "报告：充电状态行")
}

// MARK: - BatteryReportBuilder

do {
	let report = BatteryReportBuilder(
		snapshot: batterySnap(percent: 80),
		configuration: fullConfig,
		drainEstimate: nil,
		healthSamples: [],
		sessions: [],
		bluetoothDevices: []
	).build()
	expect(report.contains("电源来源"), "报告生成：包含电源来源")
	expect(!report.isEmpty, "报告生成：空数据不崩且非空")
}

// 报告补全：新数据源都能进报告
do {
	var s = batterySnap(percent: 74, onBattery: false)
	s.designCapacityMAh = 4720
	s.maxCapacityMAh = 4500
	s.cycleCount = 100
	s.temperatureC = 30
	s.adapterName = "61W USB-C Power Adapter"
	s.adapterManufacturer = "Apple Inc."
	s.adapterRatedWatts = 61
	
	let history = [
		DailyUsage(dayKey: "2026-07-30", drainedPercent: 40, chargedPercent: 35, acSeconds: 3 * 3600, batterySeconds: 3600)
	]
	let charger = ChargerProfile(key: "61W USB-C Power Adapter|Apple Inc.|61", name: "61W USB-C Power Adapter", ratedWatts: 61, firstSeen: t0, lastSeen: t0, connectCount: 5)
	let sleep = SleepDrainRecord(sleepDate: t0, wakeDate: t0.addingTimeInterval(8 * 3600), startPercent: 80, endPercent: 74)
	let events = [PowerEvent(date: t0, kind: .pluggedIn), PowerEvent(date: t0.addingTimeInterval(60), kind: .chargedFull)]
	
	let report = BatteryReportBuilder(
		snapshot: s,
		configuration: fullConfig,
		drainEstimate: nil,
		healthSamples: [],
		sessions: [],
		bluetoothDevices: [],
		dailyHistory: history,
		chargerProfiles: [charger],
		lastSleepDrain: sleep,
		powerEvents: events
	).build()
	
	expect(report.contains("【电池体检】"), "报告补全：含电池体检区块")
	expect(report.contains("【当前充电器】"), "报告补全：含当前充电器区块")
	expect(report.contains("已见 5 次"), "报告补全：充电器见过次数入报")
	expect(report.contains("【上次睡眠掉电】"), "报告补全：含睡眠掉电区块")
	expect(report.contains("【最近用电】"), "报告补全：含最近用电区块")
	expect(report.contains("插电占比 75%"), "报告补全：插电占比入报")
	expect(report.contains("【电源事件】"), "报告补全：含电源事件区块")
	expect(report.contains("充满电"), "报告补全：电源事件中文化")
}

// MARK: - MenuBarIconRenderer 缓存

do {
	let a = MenuBarIconRenderer.batteryImage(percent: 50, isCharging: false, isLowBattery: false)
	let b = MenuBarIconRenderer.batteryImage(percent: 50, isCharging: false, isLowBattery: false)
	expect(a === b, "图标缓存：同参数应命中缓存")
	
	let low = MenuBarIconRenderer.batteryImage(percent: 50, isCharging: false, isLowBattery: true)
	expect(a !== low, "图标缓存：低电量标志应参与缓存 key")
	
	let over = MenuBarIconRenderer.batteryImage(percent: 150, isCharging: false, isLowBattery: false)
	let hundred = MenuBarIconRenderer.batteryImage(percent: 100, isCharging: false, isLowBattery: false)
	expect(over === hundred, "图标缓存：越界百分比应被夹紧到 100")
	
	let negative = MenuBarIconRenderer.batteryImage(percent: -5, isCharging: false, isLowBattery: false)
	expect(negative.size.width > 0, "图标渲染：负百分比不崩")
}

// MARK: - DictionaryValueAccess

do {
	let dict: [String: Any] = ["a": 5, "b": NSNumber(value: 7), "c": "hi", "d": true, "e": ["k": "v"]]
	expectEqual(dict.int("a"), 5, "字典取值：原生 Int")
	expectEqual(dict.int("b"), 7, "字典取值：NSNumber 转 Int")
	expectEqual(dict.string("c"), "hi", "字典取值：字符串")
	expectEqual(dict.bool("d"), true, "字典取值：布尔")
	expect(dict.dictionary("e")?.string("k") == "v", "字典取值：嵌套字典")
	expect(dict.int("missing") == nil, "字典取值：缺失键为 nil")
}

// MARK: - SleepDrainRecord

do {
	let record = SleepDrainRecord(
		sleepDate: t0,
		wakeDate: t0.addingTimeInterval(8 * 3600),
		startPercent: 80,
		endPercent: 74
	)
	expectEqual(record.durationMinutes, 480, "睡眠掉电：8 小时时长计算")
	expectEqual(record.droppedPercent, 6, "睡眠掉电：掉电百分比")
	expect(abs(record.dropPerHour - 0.75) < 0.01, "睡眠掉电：折算 0.75%/小时")
	
	// 睡眠期间接着电源充了电：掉电为负，面板不展示（靠 droppedPercent >= 1 过滤）
	let charged = SleepDrainRecord(sleepDate: t0, wakeDate: t0.addingTimeInterval(3600), startPercent: 50, endPercent: 80)
	expect(charged.droppedPercent < 0, "睡眠掉电：睡眠中充电时掉电为负")
}

// 面板信息行：睡眠掉电展示/隐藏条件
do {
	let s = batterySnap(percent: 74)
	let fresh = SleepDrainRecord(sleepDate: Date().addingTimeInterval(-9 * 3600), wakeDate: Date().addingTimeInterval(-600), startPercent: 80, endPercent: 74)
	let items = BatteryInfoFormatter(snapshot: s, configuration: fullConfig, sleepDrain: fresh).makeItems()
	expect(items.contains { $0.label == "睡眠掉电" }, "睡眠掉电行：刚醒来的记录应展示")
	
	let stale = SleepDrainRecord(sleepDate: Date().addingTimeInterval(-30 * 3600), wakeDate: Date().addingTimeInterval(-25 * 3600), startPercent: 80, endPercent: 74)
	let items2 = BatteryInfoFormatter(snapshot: s, configuration: fullConfig, sleepDrain: stale).makeItems()
	expect(!items2.contains { $0.label == "睡眠掉电" }, "睡眠掉电行：超过一天的旧记录不展示")
	
	let noDrop = SleepDrainRecord(sleepDate: Date().addingTimeInterval(-9 * 3600), wakeDate: Date().addingTimeInterval(-600), startPercent: 80, endPercent: 80)
	let items3 = BatteryInfoFormatter(snapshot: s, configuration: fullConfig, sleepDrain: noDrop).makeItems()
	expect(!items3.contains { $0.label == "睡眠掉电" }, "睡眠掉电行：没掉电不展示")
}

// MARK: - 充电器档案信息行

do {
	var s = batterySnap(percent: 60, onBattery: false)
	s.isCharging = true
	let newcomer = ChargerProfile(key: "a|b|65", name: "65W 氮化镓", ratedWatts: 65, firstSeen: t0, lastSeen: t0, connectCount: 1)
	let items = BatteryInfoFormatter(snapshot: s, configuration: fullConfig, chargerProfile: newcomer).makeItems()
	expectEqual(items.first { $0.label == "充电器" }?.value, "65W 氮化镓 · 第一次见", "充电器档案：第一次见亮名字标新")

	let regular = ChargerProfile(key: "a|b|65", name: "65W 氮化镓", ratedWatts: 65, firstSeen: t0, lastSeen: t0, connectCount: 12)
	let items2 = BatteryInfoFormatter(snapshot: s, configuration: fullConfig, chargerProfile: regular).makeItems()
	expectEqual(items2.first { $0.label == "充电器" }?.value, "65W 氮化镓 · 见过 12 次", "充电器档案：见过多次亮名字")

	// 系统认不出的头（name 空）：标"未命名"并给命名引导
	let anonymous = ChargerProfile(key: "||65", name: "", ratedWatts: 65, firstSeen: t0, lastSeen: t0, connectCount: 3)
	let items3 = BatteryInfoFormatter(snapshot: s, configuration: fullConfig, chargerProfile: anonymous).makeItems()
	let anonRow = items3.first { $0.label == "充电器" }
	expectEqual(anonRow?.value, "未命名 · 见过 3 次", "充电器档案：认不出标未命名")
	expect(anonRow?.helpText?.contains("设置") == true, "充电器档案：未命名带引导提示")

	// 用户认领后：面板直接说人话
	var claimed = anonymous
	claimed.customName = "Anker · 桌面"
	let items4 = BatteryInfoFormatter(snapshot: s, configuration: fullConfig, chargerProfile: claimed).makeItems()
	expectEqual(items4.first { $0.label == "充电器" }?.value, "Anker · 桌面 · 见过 3 次", "充电器档案：用户命名优先展示")
	
	let onBattery = BatteryInfoFormatter(snapshot: batterySnap(percent: 60), configuration: fullConfig, chargerProfile: regular).makeItems()
	expect(!onBattery.contains { $0.label == "充电器" }, "充电器档案：电池供电时不展示")
}

// MARK: - 每周电池周报

do {
	let cal = Calendar.current
	// 2026-07-26 是周日
	let sundayEvening = cal.date(from: DateComponents(year: 2026, month: 7, day: 26, hour: 21))!
	let sundayDue = cal.date(from: DateComponents(year: 2026, month: 7, day: 26, hour: 20))!
	expectEqual(BatteryAlertController.mostRecentDigestDue(before: sundayEvening), sundayDue, "周报：周日晚上到点（当天 20:00）")
	
	let sundayAfternoon = cal.date(from: DateComponents(year: 2026, month: 7, day: 26, hour: 19))!
	let lastSundayDue = cal.date(from: DateComponents(year: 2026, month: 7, day: 19, hour: 20))!
	expectEqual(BatteryAlertController.mostRecentDigestDue(before: sundayAfternoon), lastSundayDue, "周报：周日 20 点前还没到点，算上周的")
	
	let wednesday = cal.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 10))!
	expectEqual(BatteryAlertController.mostRecentDigestDue(before: wednesday), sundayDue, "周报：周中补发用刚过去的周日")
	
	let history = [
		DailyUsage(dayKey: "2026-07-24", drainedPercent: 40, chargedPercent: 35),
		DailyUsage(dayKey: "2026-07-25", drainedPercent: 30, chargedPercent: 45)
	]
	let body = BatteryAlertController.weeklyDigestBody(history: history, sessionCount: 3, healthPercent: 92)
	expectEqual(body, "本周用电 70%、充入 80%、充电 3 次；健康度 92%", "周报：正文汇总格式")
	
	let emptyBody = BatteryAlertController.weeklyDigestBody(history: [], sessionCount: 0, healthPercent: 92)
	expect(emptyBody.isEmpty, "周报：没数据返回空串不发")
	
	let noHealth = BatteryAlertController.weeklyDigestBody(history: history, sessionCount: 0, healthPercent: nil)
	expectEqual(noHealth, "本周用电 70%、充入 80%、充电 0 次", "周报：没健康度时不带尾巴")
}

// MARK: - 新选项迁移

do {
	let legacyJSON = #"{"enabledOptions":["cycleCount"],"menuBarContent":"icon"}"#.data(using: .utf8)!
	let migrated = try JSONDecoder().decode(AppConfiguration.self, from: legacyJSON).normalized()
	expect(migrated.enabledOptions.contains(.sleepDrainReport), "配置迁移：睡眠掉电应按默认开启")
	expect(migrated.enabledOptions.contains(.weeklyDigest), "配置迁移：每周周报应按默认开启")
	expect(migrated.enabledOptions.contains(.chargerProfile), "配置迁移：充电器档案应按默认开启")
} catch {
	expect(false, "配置迁移：新选项迁移解码不应失败（\(error)）")
}

// MARK: - 电池体检评分

do {
	let good = BatteryCheckup.evaluate(healthPercent: 100, cycleCount: 0, temperatureC: 30, highSocDwellShare: 0.0)
	expectEqual(good?.score, 100, "体检：全新电池满分")
	expectEqual(good?.verdict, "状态优秀，继续保持", "体检：满分评语")

	let worn = BatteryCheckup.evaluate(healthPercent: 80, cycleCount: 1000, temperatureC: 45, highSocDwellShare: 0.95)
	expectEqual(worn?.score, 5, "体检：老化电池只剩驻留习惯分")
	expectEqual(worn?.verdict, "老化明显，建议检测电池", "体检：低分评语")

	expect(BatteryCheckup.evaluate(healthPercent: nil, cycleCount: 100, temperatureC: 30, highSocDwellShare: nil) == nil, "体检：没健康度不硬给分")

	// 健康 90（27.5）+ 循环 200（20）+ 32°C（10）+ 驻留良好（10）≈ 68
	let mid = BatteryCheckup.evaluate(healthPercent: 90, cycleCount: 200, temperatureC: 32, highSocDwellShare: 0.1)
	expectEqual(mid?.score, 68, "体检：中段加权计算")
	expectEqual(mid?.verdict, "开始老化，注意保养", "体检：中段评语")

	// 驻留分档：20%~50% 扣到 8 分，>50% 扣到 5 分
	expectEqual(BatteryCheckup.evaluate(healthPercent: 90, cycleCount: 200, temperatureC: 32, highSocDwellShare: 0.3)?.score, 66, "体检：驻留 30% 落 8 分档")
	expectEqual(BatteryCheckup.evaluate(healthPercent: 90, cycleCount: 200, temperatureC: 32, highSocDwellShare: 0.6)?.score, 63, "体检：驻留 60% 落 5 分档")
}

// MARK: - 插电占比与 DailyUsage 兼容解码

do {
	var usage = DailyUsage(dayKey: "2026-07-30")
	expect(usage.acShare == nil, "插电占比：样本不足半小时不给结论")
	
	usage.acSeconds = 3 * 3600
	usage.batterySeconds = 1 * 3600
	expect(abs((usage.acShare ?? 0) - 0.75) < 0.001, "插电占比：3小时插电/1小时电池 = 75%")
	
	// 旧存档没有时长字段，解码不应炸且缺省 0
	let legacyJSON = #"[{"dayKey":"2026-07-29","drainedPercent":30,"chargedPercent":40}]"#.data(using: .utf8)!
	let decoded = try JSONDecoder().decode([DailyUsage].self, from: legacyJSON)
	expectEqual(decoded.first?.drainedPercent, 30, "DailyUsage 迁移：旧字段保留")
	expectEqual(decoded.first?.acSeconds, 0, "DailyUsage 迁移：新字段缺省 0")
	expect(decoded.first?.acShare == nil, "DailyUsage 迁移：无时长数据不给占比")
} catch {
	expect(false, "DailyUsage 迁移：旧存档解码不应失败（\(error)）")
}

// MARK: - 电流电压信息行

do {
	var s = batterySnap(percent: 60, onBattery: false)
	s.isCharging = true
	s.batteryVoltageMV = 12600
	s.batteryAmperageMA = 1230
	let items = BatteryInfoFormatter(snapshot: s, configuration: fullConfig).makeItems()
	expectEqual(items.first { $0.label == "电流电压" }?.value, "12.60V · +1.23A", "电流电压：充电时带正号")
	
	var draining = batterySnap(percent: 60)
	draining.batteryVoltageMV = 12100
	draining.batteryAmperageMA = -850
	let items2 = BatteryInfoFormatter(snapshot: draining, configuration: fullConfig).makeItems()
	expectEqual(items2.first { $0.label == "电流电压" }?.value, "12.10V · -0.85A", "电流电压：放电时带负号")
	
	let missing = BatteryInfoFormatter(snapshot: batterySnap(percent: 60), configuration: fullConfig).makeItems()
	expect(!missing.contains { $0.label == "电流电压" }, "电流电压：缺数据不展示")

	// 插电未充电的微小噪声读数：四舍五入到 0.00 时不带符号，不显示 "-0.00A"
	var trickle = batterySnap(percent: 80, onBattery: false)
	trickle.batteryVoltageMV = 12190
	trickle.batteryAmperageMA = -4
	let trickleItems = BatteryInfoFormatter(snapshot: trickle, configuration: fullConfig).makeItems()
	expectEqual(trickleItems.first { $0.label == "电流电压" }?.value, "12.19V · 0.00A", "电流电压：近零读数不带符号")
}

// MARK: - 新一批选项迁移与阈值夹紧

do {
	let legacyJSON = #"{"enabledOptions":["cycleCount"],"menuBarContent":"icon"}"#.data(using: .utf8)!
	let migrated = try JSONDecoder().decode(AppConfiguration.self, from: legacyJSON).normalized()
	expect(migrated.enabledOptions.contains(.batteryCheckup), "配置迁移：体检评分默认开")
	expect(migrated.enabledOptions.contains(.socChart), "配置迁移：24小时电量曲线默认开")
	expect(migrated.enabledOptions.contains(.alertLowBattery), "配置迁移：低电提醒细分开关默认开")
	expect(!migrated.enabledOptions.contains(.quietHours), "配置迁移：免打扰默认关，用户自己选")
	expectEqual(migrated.chargeCareThresholdPercent, 80, "配置迁移：保养阈值默认 80")
	expectEqual(migrated.deviceLowThresholdPercent, 20, "配置迁移：外设低电阈值默认 20")
	expectEqual(migrated.highDrainThresholdPerHour, 20, "配置迁移：耗电异常阈值默认 20")
	expect(migrated.collapsedCards.isEmpty, "配置迁移：折叠状态默认空")
} catch {
	expect(false, "配置迁移：新一批选项解码不应失败（\(error)）")
}

do {
	var config = AppConfiguration()
	config.chargeCareThresholdPercent = 99
	config.deviceLowThresholdPercent = 2
	config.highDrainThresholdPerHour = 99
	config.collapsedCards = ["powerChart", "不存在的卡片"]
	let fixed = config.normalized()
	expectEqual(fixed.chargeCareThresholdPercent, 95, "阈值夹紧：保养上限 95")
	expectEqual(fixed.deviceLowThresholdPercent, 5, "阈值夹紧：外设下限 5")
	expectEqual(fixed.highDrainThresholdPerHour, 40, "阈值夹紧：耗电异常上限 40")
	expectEqual(fixed.collapsedCards, ["powerChart"], "折叠状态：无效卡片 ID 被清洗")
}

// MARK: - 充电习惯洞察

do {
	// 长期插电：连续多天插电占比都很高 → 提示“用一用”
	var heavyAC: [DailyUsage] = []
	for i in 0..<4 {
		heavyAC.append(DailyUsage(dayKey: "2026-07-2\(i)", drainedPercent: 5, chargedPercent: 5, acSeconds: 23 * 3600, batterySeconds: 3600))
	}
	let insight = ChargingHabitAnalyzer.analyze(events: [], dailyHistory: heavyAC, snapshot: batterySnap(percent: 90, onBattery: false))
	expect(insight?.message.contains("全程插着电") == true, "习惯洞察：长期插电给出用一用建议")
	
	// 正常使用（插电占比不高）不应报长期插电
	var normal: [DailyUsage] = []
	for i in 0..<4 {
		normal.append(DailyUsage(dayKey: "2026-07-1\(i)", drainedPercent: 40, chargedPercent: 40, acSeconds: 4 * 3600, batterySeconds: 8 * 3600))
	}
	let none = ChargingHabitAnalyzer.analyze(events: [], dailyHistory: normal, snapshot: batterySnap(percent: 60))
	expect(none == nil, "习惯洞察：正常使用不乱给建议")
	
	// 样本不足（不足 3 天有占比）不下结论
	let tooFew = ChargingHabitAnalyzer.analyze(events: [], dailyHistory: [DailyUsage(dayKey: "2026-07-30", drainedPercent: 5, chargedPercent: 5, acSeconds: 23*3600, batterySeconds: 3600)], snapshot: batterySnap(percent: 90, onBattery: false))
	expect(tooFew == nil, "习惯洞察：样本不足不下结论")
}

// 夜间充电习惯：多次夜间插电 + 当前在夜间充电 → 提示充到 80%
do {
	var cal = Calendar(identifier: .gregorian)
	cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
	// 造 5 个“晚上 23 点插电”事件
	var events: [PowerEvent] = []
	for day in 20...24 {
		let date = cal.date(from: DateComponents(year: 2026, month: 7, day: day, hour: 23))!
		events.append(PowerEvent(date: date, kind: .pluggedIn))
	}
	var charging = batterySnap(percent: 70, charging: true, onBattery: false)
	charging.isCharging = true
	let nightNow = cal.date(from: DateComponents(year: 2026, month: 7, day: 25, hour: 23, minute: 10))!
	let insight = ChargingHabitAnalyzer.analyze(events: events, dailyHistory: [], snapshot: charging, now: nightNow, calendar: cal)
	expect(insight?.message.contains("充到 80%") == true, "习惯洞察：夜间充电规律提示充到 80%")
}

// MARK: - 体检分享卡片

do {
	let card = BatteryShareCardRenderer.render(BatteryShareCardRenderer.CardData(
		score: 84, verdict: "状态良好，正常使用",
		healthPercent: 95, cycleCount: 78, temperatureC: 30.5, generatedAt: t0
	))
	expect(card.size.width == 600 && card.size.height == 380, "分享卡：尺寸为 600x380")
	expect(card.tiffRepresentation != nil, "分享卡：能渲染出位图")
}

// 体检分档：分档阈值单一数据源，锁死边界（评语与各处配色都基于它）
do {
	expect(BatteryCheckup.tier(for: 85) == .excellent, "体检分档：85 为优秀下界")
	expect(BatteryCheckup.tier(for: 84) == .good, "体检分档：84 落良好")
	expect(BatteryCheckup.tier(for: 70) == .good, "体检分档：70 为良好下界")
	expect(BatteryCheckup.tier(for: 69) == .aging, "体检分档：69 落老化")
	expect(BatteryCheckup.tier(for: 55) == .aging, "体检分档：55 为老化下界")
	expect(BatteryCheckup.tier(for: 54) == .poor, "体检分档：54 落较差")
	// 评语与分档同源：边界分数的评语应与 tier 一致
	expectEqual(BatteryCheckup.verdict(for: 85), "状态优秀，继续保持", "体检分档：85 分评语与优秀档一致")
}

// MARK: - 用电日历周历排布

do {
	var cal = Calendar(identifier: .gregorian)
	cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
	// 2026-07-31 是周五（weekday=6，0-based=5）
	let today = cal.date(from: DateComponents(year: 2026, month: 7, day: 31, hour: 15))!
	// 关键：历史末尾是昨天 30 日（今天还没产生数据），验证仍以真实今天为锚点
	let history = [
		DailyUsage(dayKey: "2026-07-29", drainedPercent: 30, chargedPercent: 20),
		DailyUsage(dayKey: "2026-07-30", drainedPercent: 40, chargedPercent: 35)
	]
	let columns = UsageCalendarLayout.buildColumns(history, weeks: 10, today: today, calendar: cal)
	expectEqual(columns.count, 10, "用电日历：按 weeks 数量排列")
	expect(columns.allSatisfy { $0.count == 7 }, "用电日历：每列 7 格")
	
	// 今天（07-31 周五）应落在最后一列的周五位（下标 5），且之后的周六为 nil
	let lastWeek = columns[9]
	expect(lastWeek[6] == nil, "用电日历：今天之后的未来格为 nil")
	
	// 昨天 07-30 的用电应能在网格里找到（锁死“锚点不因末尾数据日期而偏”）
	let found = columns.flatMap { $0 }.compactMap { $0 }.first { $0.dayKey == "2026-07-30" }
	expect(found?.drainedPercent == 40, "用电日历：历史数据正确定位（今日无数据也不错位）")
}

// 非公历系统区域（佛历）下，dayKey 日期键仍应正常匹配（锁死 POSIX locale 修复）
do {
	var cal = Calendar(identifier: .buddhist)
	cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
	cal.locale = Locale(identifier: "th_TH_u_ca_buddhist")
	// 即使传入佛历 calendar，buildColumns 内部用 startOfDay + 公历键，历史仍应命中
	let today = Date(timeIntervalSince1970: 1_800_000_000)
	let todayKey = UsageCalendarLayout.dayKey(today, calendar: cal)
	expect(todayKey.hasPrefix("2027-"), "日期键：POSIX 公历下输出公历年份而非佛历 2570")
	let history = [DailyUsage(dayKey: todayKey, drainedPercent: 25, chargedPercent: 20)]
	let columns = UsageCalendarLayout.buildColumns(history, weeks: 10, today: today, calendar: cal)
	let found = columns.flatMap { $0 }.compactMap { $0 }.first { $0.dayKey == todayKey }
	expect(found?.drainedPercent == 25, "用电日历：佛历系统区域下仍能定位历史数据")
}

// 跨时区回归：日期/月份键必须跟随注入 calendar 的时区，而不是系统时区。
// 取 2026-08-01 01:00 上海 = 2026-07-31 17:00 UTC 的边界点：
// CI（UTC）上若退回系统时区，键会偏成 07-31/2026-07，断言即失败。
do {
	var sh = Calendar(identifier: .gregorian)
	sh.timeZone = TimeZone(identifier: "Asia/Shanghai")!
	// 上海 8/1 01:00，即 UTC 7/31 17:00，跨了月/日两条边界
	let boundary = sh.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 1))!

	expectEqual(UsagePatternAnalyzer.monthKeyString(boundary, calendar: sh), "2026-08", "月份键：跟随注入时区跨月不偏")
	expectEqual(UsageCalendarLayout.dayKey(boundary, calendar: sh), "2026-08-01", "日期键：跟随注入时区跨日不偏")

	// 与系统时区比对：当系统时区≠注入时区时，结果应不同（否则说明又在用系统时区）
	if TimeZone.current != sh.timeZone {
		expect(UsagePatternAnalyzer.monthKeyString(boundary, calendar: sh) != UsagePatternAnalyzer.monthKeyString(boundary, calendar: .current), "月份键：系统时区不同时应产生不同键")
	}
}

// 时长格式化：三处重复已收敛为 DurationFormatter 单一工具，锁死边界
do {
	expectEqual(DurationFormatter.chinese(minutes: 0), "0分钟", "时长：0 分钟")
	expectEqual(DurationFormatter.chinese(minutes: 59), "59分钟", "时长：不满一小时不带小时")
	expectEqual(DurationFormatter.chinese(minutes: 60), "1小时", "时长：整小时不带分钟")
	expectEqual(DurationFormatter.chinese(minutes: 125), "2小时5分钟", "时长：小时+分钟")
	expectEqual(DurationFormatter.chinese(minutes: -5), "0分钟", "时长：负值夹到 0")
}

// MARK: - 时刻格式化

// clockText 原先在面板头部与提醒控制器各写一份，已收敛到 DurationFormatter
do {
	var cal = Calendar(identifier: .gregorian)
	let tz = TimeZone(identifier: "Asia/Shanghai")!
	cal.timeZone = tz
	let night = cal.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 23, minute: 30))!
	expectEqual(DurationFormatter.clockText(afterMinutes: 90, from: night, calendar: cal, timeZone: tz), "明天 01:00", "时刻：跨天加“明天”前缀")
	
	let morning = cal.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 10))!
	expectEqual(DurationFormatter.clockText(afterMinutes: 45, from: morning, calendar: cal, timeZone: tz), "10:45", "时刻：当天不加前缀")
	expectEqual(DurationFormatter.clockText(afterMinutes: 0, from: morning, calendar: cal, timeZone: tz), "10:00", "时刻：0 分钟即当前时刻")
}

// MARK: - 蓝牙外设电量解析

// pmset -g accps 的输出解析：内部电池不算外设，残缺行全部跳过
do {
	let output = """
	Now drawing from 'AC Power'
	 -InternalBattery-0 (id=3146851)\t96%; AC attached;
	 -A950Air (id=24384395)\t80%; charging;
	 -MX Master 3 (id=998877)\t33%;
	"""
	let devices = BluetoothBatteryReader.parseAccessoryOutput(output)
	expectEqual(devices.count, 2, "外设解析：内部电池不算外设")
	expectEqual(devices.first?.name, "A950Air", "外设解析：设备名")
	expectEqual(devices.first?.percent, 80, "外设解析：电量")
	expectEqual(devices.last?.name, "MX Master 3", "外设解析：名字带空格保留")
	expectEqual(devices.last?.percent, 33, "外设解析：第二台设备")
}

do {
	// 残缺行：没 id、没百分比、电量越界、空名字
	let malformed = """
	 -NoIdDevice 55%;
	 -NoPercent (id=1)\tcharging;
	 -OverHundred (id=2)\t120%;
	 - (id=3)\t50%;
	"""
	let devices = BluetoothBatteryReader.parseAccessoryOutput(malformed)
	expect(devices.isEmpty, "外设解析：残缺行全部跳过")
}

// MARK: - 蓝牙外设类型识别

do {
	// 系统蓝牙报告的 minorType 优先
	expectEqual(BluetoothBatteryReader.kind(fromMinorType: "Mouse"), .mouse, "类型识别：minorType 大小写不敏感")
	expectEqual(BluetoothBatteryReader.kind(fromMinorType: "headset"), .headphones, "类型识别：headset 归耳机")
	expectEqual(BluetoothBatteryReader.kind(fromMinorType: "Joystick"), .gamepad, "类型识别：摇杆归手柄")
	expectEqual(BluetoothBatteryReader.kind(fromMinorType: "something-new"), .other, "类型识别：未知类型兜底 other")
	
	// 报告查不到时按名字关键词猜
	expectEqual(BluetoothBatteryReader.kindFromName("AirPods Pro"), .headphones, "类型识别：名字含 AirPods 归耳机")
	expectEqual(BluetoothBatteryReader.kindFromName("妙控鼠标"), .mouse, "类型识别：名字含“鼠标”")
	expectEqual(BluetoothBatteryReader.kindFromName("Magic Keyboard"), .keyboard, "类型识别：名字含 keyboard")
	expectEqual(BluetoothBatteryReader.kindFromName("神秘设备"), .other, "类型识别：无关键词兜底 other")
}

// MARK: - 睡眠掉电提醒判定

// 锁死“醒来 10 分钟内重启不重发”：同一 wakeDate 已报过就拦住
do {
	let sleepStart = t0
	let wake = t0.addingTimeInterval(2 * 3600)
	let heavy = SleepDrainRecord(sleepDate: sleepStart, wakeDate: wake, startPercent: 80, endPercent: 72)
	let now = wake.addingTimeInterval(60)
	
	expect(BatteryAlertController.shouldAlertSleepDrain(record: heavy, now: now, lastAlertedWakeDate: nil), "睡眠掉电：刚醒来的异常记录应提醒")
	expect(!BatteryAlertController.shouldAlertSleepDrain(record: heavy, now: now, lastAlertedWakeDate: wake), "睡眠掉电：同一觉已报过，重启不重发")
	
	let otherWake = wake.addingTimeInterval(86400)
	expect(BatteryAlertController.shouldAlertSleepDrain(record: heavy, now: now, lastAlertedWakeDate: otherWake), "睡眠掉电：别的觉的旧标记不误伤新记录")
	
	let staleNow = wake.addingTimeInterval(30 * 60)
	expect(!BatteryAlertController.shouldAlertSleepDrain(record: heavy, now: staleNow, lastAlertedWakeDate: nil), "睡眠掉电：醒来超 10 分钟的旧记录不提醒")
	
	let mild = SleepDrainRecord(sleepDate: sleepStart, wakeDate: wake, startPercent: 80, endPercent: 78)
	expect(!BatteryAlertController.shouldAlertSleepDrain(record: mild, now: now, lastAlertedWakeDate: nil), "睡眠掉电：只掉 2% 低于阈值不提醒")
	
	let shortSleep = SleepDrainRecord(sleepDate: wake.addingTimeInterval(-30 * 60), wakeDate: wake, startPercent: 80, endPercent: 70)
	expect(!BatteryAlertController.shouldAlertSleepDrain(record: shortSleep, now: now, lastAlertedWakeDate: nil), "睡眠掉电：合盖不足一小时不提醒")
}

// MARK: - 充电会话状态机判定

do {
	// 落盘才过 5 分钟 → 续接
	let recent = ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(300), startPercent: 40, endPercent: 45, peakInputW: 30)
	expect(BatteryHistoryRecorder.shouldResumeRestoredSession(recent, now: t0.addingTimeInterval(600)), "会话续接：落盘后半小时内续接")
	
	// 落盘已过 1 小时 → 视为中间拔过电，不续接
	expect(!BatteryHistoryRecorder.shouldResumeRestoredSession(recent, now: t0.addingTimeInterval(3900)), "会话续接：超半小时断档不续接")
	
	// 归档过滤：不足 2 分钟且电量没涨 → 弃
	let blink = ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(30), startPercent: 40, endPercent: 40, peakInputW: 10)
	expect(!BatteryHistoryRecorder.isSessionWorthArchiving(blink), "会话归档：插拔瞬间的无效会话不归档")
	
	// 不足 2 分钟但电量涨了（闪充）→ 留
	let flashCharge = ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(30), startPercent: 40, endPercent: 41, peakInputW: 60)
	expect(BatteryHistoryRecorder.isSessionWorthArchiving(flashCharge), "会话归档：时长短但电量涨了仍保留")
}

// MARK: - 电源事件合并

do {
	var events: [PowerEvent] = []
	events = BatteryHistoryRecorder.appendingPowerEvent(events, kind: .pluggedIn, now: t0)
	expectEqual(events.count, 1, "事件合并：首条正常记录")
	
	// 同类 2 分钟内连发只留最新
	events = BatteryHistoryRecorder.appendingPowerEvent(events, kind: .pluggedIn, now: t0.addingTimeInterval(30))
	expectEqual(events.count, 1, "事件合并：同类连发合并")
	expectEqual(events.last?.date, t0.addingTimeInterval(30), "事件合并：合并后留最新时刻")
	
	events = BatteryHistoryRecorder.appendingPowerEvent(events, kind: .pluggedIn, now: t0.addingTimeInterval(180))
	expectEqual(events.count, 2, "事件合并：超 2 分钟不再合并")
	
	events = BatteryHistoryRecorder.appendingPowerEvent(events, kind: .unplugged, now: t0.addingTimeInterval(190))
	expectEqual(events.count, 3, "事件合并：不同类不合并")
	
	// 封顶：塞满 50 条后新的挤掉最旧的
	var full: [PowerEvent] = []
	for i in 0..<50 {
		full.append(PowerEvent(date: t0.addingTimeInterval(Double(i) * 300), kind: i % 2 == 0 ? .pluggedIn : .unplugged))
	}
	let capped = BatteryHistoryRecorder.appendingPowerEvent(full, kind: .chargedFull, now: t0.addingTimeInterval(50 * 300))
	expectEqual(capped.count, 50, "事件合并：总数封顶 50")
	expectEqual(capped.first?.date, t0.addingTimeInterval(300), "事件合并：超出挤掉最旧")
	expectEqual(capped.last?.kind, .chargedFull, "事件合并：最新一条在末尾")
}

// MARK: - 充电器档案

do {
	// 测试侧辅助：与真实调用方一样先算键再建档
	func upsert(_ profiles: [ChargerProfile], name: String, manufacturer: String, ratedWatts: Int, now: Date) -> [ChargerProfile] {
		BatteryHistoryRecorder.upsertingChargerProfile(
			profiles,
			key: BatteryHistoryRecorder.chargerKey(name: name, manufacturer: manufacturer, ratedWatts: ratedWatts),
			name: name, manufacturer: manufacturer, ratedWatts: ratedWatts, now: now
		)
	}

	var profiles: [ChargerProfile] = []
	profiles = upsert(profiles, name: "65W 氮化镓", manufacturer: "Anker", ratedWatts: 65, now: t0)
	expectEqual(profiles.count, 1, "充电器建档：第一次见建档")
	expectEqual(profiles.first?.connectCount, 1, "充电器建档：初始计次 1")

	// 半小时内再见（如应用重启）不重复计次
	profiles = upsert(profiles, name: "65W 氮化镓", manufacturer: "Anker", ratedWatts: 65, now: t0.addingTimeInterval(10 * 60))
	expectEqual(profiles.first?.connectCount, 1, "充电器建档：半小时内再见不计次")
	expectEqual(profiles.first?.lastSeen, t0.addingTimeInterval(10 * 60), "充电器建档：lastSeen 刷新")

	// 超窗再来算一次新连接
	profiles = upsert(profiles, name: "65W 氮化镓", manufacturer: "Anker", ratedWatts: 65, now: t0.addingTimeInterval(60 * 60))
	expectEqual(profiles.first?.connectCount, 2, "充电器建档：超窗重连计次")

	// 名字厂商都空 → 按瓦数兜底命名
	let anon = upsert([], name: "", manufacturer: "", ratedWatts: 30, now: t0)
	expectEqual(anon.first?.name, "30W 充电器", "充电器建档：无名按瓦数兜底")

	expectEqual(BatteryHistoryRecorder.chargerKey(name: "a", manufacturer: "b", ratedWatts: 65), "a|b|65", "充电器身份键：格式单一数据源")

	// 档案满了挤掉最久没见过的
	var crowded: [ChargerProfile] = []
	for i in 0..<20 {
		crowded = upsert(crowded, name: "充电器\(i)", manufacturer: "X", ratedWatts: 20 + i, now: t0.addingTimeInterval(Double(i) * 60))
	}
	expectEqual(crowded.count, 20, "充电器建档：档案上限 20")
	let after = upsert(crowded, name: "新面孔", manufacturer: "X", ratedWatts: 99, now: t0.addingTimeInterval(3600))
	expectEqual(after.count, 20, "充电器建档：满了仍 20 条")
	expect(!after.contains { $0.name == "充电器0" }, "充电器建档：挤掉最久没见的")
	expect(after.contains { $0.name == "新面孔" }, "充电器建档：新面孔入档")
}

// MARK: - 今日用电累计

do {
	var usage = DailyUsage(dayKey: "2026-08-08")
	usage = BatteryHistoryRecorder.accumulatingDailyUsage(usage, percent: 78, lastPercent: 80, powerSource: .battery, isCharging: false, secondsSinceLastSample: 10)
	expectEqual(usage.drainedPercent, 2, "今日用电：电池模式掉电计入")
	expectEqual(usage.chargedPercent, 0, "今日用电：充入不误计")
	
	usage = BatteryHistoryRecorder.accumulatingDailyUsage(usage, percent: 82, lastPercent: 78, powerSource: .powerAdapter, isCharging: true, secondsSinceLastSample: 10)
	expectEqual(usage.chargedPercent, 4, "今日用电：充电时涨的计入充入")
	
	// 反向不计：电池模式回升（校准波动）
	usage = BatteryHistoryRecorder.accumulatingDailyUsage(usage, percent: 83, lastPercent: 82, powerSource: .battery, isCharging: false, secondsSinceLastSample: 10)
	expectEqual(usage.drainedPercent, 2, "今日用电：电池模式回升不计")
	
	// 插电时掉电（供电不足）不算用户用电
	usage = BatteryHistoryRecorder.accumulatingDailyUsage(usage, percent: 82, lastPercent: 83, powerSource: .powerAdapter, isCharging: false, secondsSinceLastSample: 10)
	expectEqual(usage.drainedPercent, 2, "今日用电：插电时掉电不计")
	
	// 时长累计 + 睡眠断档不计
	expect(usage.batterySeconds > 0, "今日用电：电池时长累计")
	let before = usage
	let afterSleepGap = BatteryHistoryRecorder.accumulatingDailyUsage(usage, percent: 82, lastPercent: 82, powerSource: .battery, isCharging: false, secondsSinceLastSample: 3600)
	expectEqual(afterSleepGap.batterySeconds, before.batterySeconds, "今日用电：睡过的时间不计")
}

// MARK: - SOC 采样判定

do {
	expect(BatteryHistoryRecorder.shouldRecordSOCSample(last: nil, percent: 80, isCharging: false, now: t0), "SOC采样：首点必记")
	
	let sample = SOCSample(date: t0, percent: 80, isCharging: false)
	expect(!BatteryHistoryRecorder.shouldRecordSOCSample(last: sample, percent: 80, isCharging: false, now: t0.addingTimeInterval(60)), "SOC采样：常规间隔内无变化不记")
	expect(BatteryHistoryRecorder.shouldRecordSOCSample(last: sample, percent: 80, isCharging: true, now: t0.addingTimeInterval(5)), "SOC采样：充电状态翻转立即记")
	expect(!BatteryHistoryRecorder.shouldRecordSOCSample(last: sample, percent: 79, isCharging: false, now: t0.addingTimeInterval(60)), "SOC采样：电量变化但不足最小间隔不记")
	expect(BatteryHistoryRecorder.shouldRecordSOCSample(last: sample, percent: 79, isCharging: false, now: t0.addingTimeInterval(4 * 60)), "SOC采样：电量变化超最小间隔记")
	expect(BatteryHistoryRecorder.shouldRecordSOCSample(last: sample, percent: 80, isCharging: false, now: t0.addingTimeInterval(10 * 60)), "SOC采样：到常规间隔记定点")
}

// MARK: - 睡眠结算

do {
	let record = BatteryHistoryRecorder.settledSleepDrain(sleepDate: t0, startPercent: 80, wakeDate: t0.addingTimeInterval(2 * 3600), endPercent: 74)
	expect(record != nil, "睡眠结算：合盖超 20 分钟记录")
	expectEqual(record?.droppedPercent, 6, "睡眠结算：掉电计算正确")
	
	let nap = BatteryHistoryRecorder.settledSleepDrain(sleepDate: t0, startPercent: 80, wakeDate: t0.addingTimeInterval(10 * 60), endPercent: 79)
	expect(nap == nil, "睡眠结算：不足 20 分钟的小憩不记")
}

// MARK: - 历史数据损坏抢救

// 主档损坏（有数据却解不开）→ 回退备份；主档正常直接解码；双份都坏不崩；
// 主档无数据不碰备份（备份只救损坏，不做删除恢复）
do {
	let session = ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(600), startPercent: 40, endPercent: 50, peakInputW: 30)
	let good = try PropertyListEncoder().encode([session])
	let garbage = Data([0xFF, 0xFE, 0xFD, 0xFC])
	
	let rescued = BatteryHistoryRecorder.decodingWithFallback([ChargeSession].self, primaryData: garbage, backupData: good)
	expectEqual(rescued?.count, 1, "备份抢救：主档损坏回退备份")
	expectEqual(rescued?.first?.endPercent, 50, "备份抢救：备份内容读取正确")
	
	let normal = BatteryHistoryRecorder.decodingWithFallback([ChargeSession].self, primaryData: good, backupData: nil)
	expectEqual(normal?.count, 1, "备份抢救：主档正常直接解码")
	
	let lost = BatteryHistoryRecorder.decodingWithFallback([ChargeSession].self, primaryData: garbage, backupData: nil)
	expect(lost == nil, "备份抢救：双份都坏返回 nil 不崩")
	
	let missing = BatteryHistoryRecorder.decodingWithFallback([ChargeSession].self, primaryData: nil, backupData: good)
	expect(missing == nil, "备份抢救：主档无数据不碰备份")
} catch {
	expect(false, "备份抢救：测试构造不应失败（\(error)）")
}

// MARK: - CSV 数据导出

do {
	let session = ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(300), startPercent: 40, endPercent: 45, peakInputW: 60)
	let usage = DailyUsage(dayKey: "2026-08-13", drainedPercent: 10, chargedPercent: 20, acSeconds: 3600, batterySeconds: 1200)
	let health = HealthSample(date: t0, healthPercent: 95, cycleCount: 100)
	let soc = SOCSample(date: t0, percent: 80, isCharging: false)
	let event = PowerEvent(date: t0, kind: .pluggedIn)

	let csv = BatteryDataExporter.csv(
		sessions: [session],
		dailyHistory: [usage],
		healthSamples: [health],
		socSamples: [soc],
		powerEvents: [event]
	)
	expect(csv.contains("# 充电记录"), "CSV导出：含充电记录小节")
	expect(csv.contains("# 每日用电"), "CSV导出：含每日用电小节")
	expect(csv.contains("# 健康度趋势"), "CSV导出：含健康度小节")
	expect(csv.contains("# 24小时电量"), "CSV导出：含24小时电量小节")
	expect(csv.contains("# 电源事件"), "CSV导出：含电源事件小节")
	expect(csv.contains("40,45,60,5"), "CSV导出：充电记录整数/时长格式")
	expect(csv.contains("2026-08-13,10,20,3600,1200,0.750"), "CSV导出：每日用电插电占比")
	expect(csv.contains("接上电源"), "CSV导出：电源事件中文化")
	expect(csv.contains("95,100"), "CSV导出：健康度与循环次数")
	expect(csv.contains("80,否"), "CSV导出：24小时电量与充电状态")

	// 插电占比：样本不足半小时（1800 秒）应留空
	let short = DailyUsage(dayKey: "2026-08-13", drainedPercent: 1, chargedPercent: 1, acSeconds: 600, batterySeconds: 600)
	let csv2 = BatteryDataExporter.csv(sessions: [], dailyHistory: [short], healthSamples: [], socSamples: [], powerEvents: [])
	expect(csv2.contains("2026-08-13,1,1,600,600,"), "CSV导出：插电占比样本不足留空")
}

// MARK: - 充电器质量诊断

do {
	let key = "65W 氮化镓|Anker|65"
	// 样本不足 5 个不给慢充结论
	var fewStats = ChargerPowerStats(key: key, ratedWatts: 65)
	fewStats.sampleCount = 4
	fewStats.sumWatts = 4 * 20
	expect(fewStats.avgWatts == 20, "充电器诊断：平均协商功率计算")
	expect(!fewStats.isSuspiciouslySlow, "充电器诊断：样本不足不下慢充结论")

	// 样本足够且平均远低于额定 → 疑似慢充
	var slow = ChargerPowerStats(key: key, ratedWatts: 65)
	slow.sampleCount = 10
	slow.sumWatts = 10 * 20
	slow.maxWatts = 22
	expect(slow.isSuspiciouslySlow, "充电器诊断：平均 20W / 额定 65W 判慢充")

	// 平均接近额定 → 正常
	var good = ChargerPowerStats(key: key, ratedWatts: 65)
	good.sampleCount = 10
	good.sumWatts = 10 * 60
	expect(!good.isSuspiciouslySlow, "充电器诊断：平均 60W / 额定 65W 正常")
	expectEqual(good.maxWatts, 0, "充电器诊断：峰值未录入为 0")
}

// MARK: - 充电器偏慢洞察

do {
	var charging = batterySnap(percent: 60, onBattery: false)
	charging.isCharging = true
	charging.negotiatedVoltageMV = 5000
	charging.negotiatedCurrentMA = 3000   // 15W < 额定30W的60%(18W)，算慢充
	let current = ChargerProfile(key: "a|b|30", name: "30W", ratedWatts: 30, firstSeen: t0, lastSeen: t0, connectCount: 3)
	let faster = ChargerProfile(key: "c|d|65", name: "65W 氮化镓", ratedWatts: 65, firstSeen: t0, lastSeen: t0, connectCount: 5)

	let insight = ChargingHabitAnalyzer.analyzeCharger(snapshot: charging, currentCharger: current, knownChargers: [current, faster])
	expect(insight?.message.contains("能充得更快") == true, "充电器洞察：偏慢且有更快充电器给建议")

	// 没在充电 → 不给
	expect(ChargingHabitAnalyzer.analyzeCharger(snapshot: batterySnap(percent: 60), currentCharger: current, knownChargers: [current, faster]) == nil, "充电器洞察：未充电不给建议")

	// 协商接近额定（不慢）→ 不给
	var fast = batterySnap(percent: 60, onBattery: false)
	fast.isCharging = true
	fast.negotiatedVoltageMV = 5000
	fast.negotiatedCurrentMA = 5500   // 27.5W ≈ 额定 30W 的 92%
	let normalInsight = ChargingHabitAnalyzer.analyzeCharger(snapshot: fast, currentCharger: current, knownChargers: [current, faster])
	expect(normalInsight == nil, "充电器洞察：协商接近额定不给建议")

	// 没有更快的充电器 → 不给
	let noFaster = ChargingHabitAnalyzer.analyzeCharger(snapshot: charging, currentCharger: current, knownChargers: [current])
	expect(noFaster == nil, "充电器洞察：没有更快充电器不报")
}

// MARK: - 充电器质量信息行

do {
	var s = batterySnap(percent: 60, onBattery: false)
	s.isCharging = true
	s.adapterRatedWatts = 65
	let profile = ChargerProfile(key: "a|b|65", name: "65W 氮化镓", ratedWatts: 65, firstSeen: t0, lastSeen: t0, connectCount: 12)
	var stats = ChargerPowerStats(key: "a|b|65", ratedWatts: 65)
	stats.sampleCount = 10
	stats.sumWatts = 10 * 20

	let items = BatteryInfoFormatter(snapshot: s, configuration: fullConfig, chargerProfile: profile, chargerStats: stats).makeItems()
	let row = items.first { $0.label == "充电器" }
	expect(row?.value.contains("平均20W") == true, "充电器信息行：附平均协商功率")
	expect(row?.value.contains("疑似慢充") == true, "充电器信息行：慢充标出")
	expect(row?.valueTint == .orange, "充电器信息行：慢充电量染橙")

	// 样本不足不标慢充
	var few = ChargerPowerStats(key: "a|b|65", ratedWatts: 65)
	few.sampleCount = 3
	few.sumWatts = 3 * 20
	let items2 = BatteryInfoFormatter(snapshot: s, configuration: fullConfig, chargerProfile: profile, chargerStats: few).makeItems()
	let row2 = items2.first { $0.label == "充电器" }
	expect(row2?.value.contains("疑似慢充") != true, "充电器信息行：样本不足不标慢充")
}

// MARK: - 时段用电热力图

do {
	var stats = HourlyDrainStats()
	// 首次累计：天数 0→1，掉电计入 15 点桶
	stats = UsagePatternAnalyzer.accumulatingHourlyDrain(stats, hour: 15, droppedPercent: 2, dayKey: "2026-08-01")
	expectEqual(stats.accumulatedDays, 1, "时段用电：首日天数 1")
	expect(abs(stats.drainedByHour[15] - 2) < 0.001, "时段用电：掉电计入对应小时桶")

	// 同日再掉：天数不变
	stats = UsagePatternAnalyzer.accumulatingHourlyDrain(stats, hour: 15, droppedPercent: 1, dayKey: "2026-08-01")
	expectEqual(stats.accumulatedDays, 1, "时段用电：同日累计天数不变")

	// 跨天：天数 +1，没掉电也要推进
	stats = UsagePatternAnalyzer.accumulatingHourlyDrain(stats, hour: 9, droppedPercent: 0, dayKey: "2026-08-02")
	expectEqual(stats.accumulatedDays, 2, "时段用电：跨天天数 +1")

	// 日均与强度归一化：15 点桶累计 3、两天 → 日均 1.5，应为最大（强度 1）
	let averages = UsagePatternAnalyzer.hourlyAverageDrain(stats)
	expect(abs(averages[15] - 1.5) < 0.001, "时段用电：日均 = 累计÷天数")
	let intensity = UsagePatternAnalyzer.hourlyIntensity(stats)
	expect(abs(intensity[15] - 1.0) < 0.001, "时段用电：最大桶强度 1")
	expect(abs(intensity[9]) < 0.001, "时段用电：空桶强度 0")

	// 高峰：天数不足不给；够了给最大小时
	expect(UsagePatternAnalyzer.peakDrainHour(stats) == nil, "时段用电：天数不足不给高峰")
	var enough = stats
	for day in 3...5 {
		enough = UsagePatternAnalyzer.accumulatingHourlyDrain(enough, hour: 15, droppedPercent: 2, dayKey: "2026-08-0\(day)")
	}
	expectEqual(UsagePatternAnalyzer.peakDrainHour(enough), 15, "时段用电：高峰落在累计最多的小时")
}

// MARK: - 用电异常检测

do {
	// 基线 21 天日均 40%，近 7 天日均 60% → 异常（+50%）
	var history: [DailyUsage] = []
	for day in 1...21 { history.append(DailyUsage(dayKey: String(format: "2026-07-%02d", day), drainedPercent: 40)) }
	for day in 1...7 { history.append(DailyUsage(dayKey: String(format: "2026-08-%02d", day), drainedPercent: 60)) }
	// 今天的半天数据不应参与
	history.append(DailyUsage(dayKey: "2026-08-08", drainedPercent: 100))

	let anomaly = UsagePatternAnalyzer.drainAnomaly(dailyHistory: history, todayKey: "2026-08-08")
	expect(anomaly != nil, "异常检测：数据足够应给出对比")
	if let anomaly {
		expect(abs(anomaly.recentAvg - 60) < 0.001, "异常检测：近 7 天日均 60")
		expect(abs(anomaly.baselineAvg - 40) < 0.001, "异常检测：基线日均 40")
	}

	// 正常波动（近 7 天也是 40）不构成异常
	let normal = history.dropLast().map { DailyUsage(dayKey: $0.dayKey, drainedPercent: 40) }
	let normalAnomaly = UsagePatternAnalyzer.drainAnomaly(dailyHistory: normal, todayKey: "2026-08-08")
	expect(normalAnomaly != nil && abs(normalAnomaly!.recentAvg - normalAnomaly!.baselineAvg) < 0.001, "异常检测：正常波动比值 1")

	// 样本不足 → nil
	let short = UsagePatternAnalyzer.drainAnomaly(dailyHistory: Array(history.prefix(10)), todayKey: "2026-08-08")
	expect(short == nil, "异常检测：样本不足不给结论")

	// 基线太低（日均 <5%）不给
	var lowBase: [DailyUsage] = []
	for day in 1...21 { lowBase.append(DailyUsage(dayKey: String(format: "2026-07-%02d", day), drainedPercent: 2)) }
	for day in 1...7 { lowBase.append(DailyUsage(dayKey: String(format: "2026-08-%02d", day), drainedPercent: 30)) }
	expect(UsagePatternAnalyzer.drainAnomaly(dailyHistory: lowBase, todayKey: "2026-08-08") == nil, "异常检测：基线太低不比较")
}

// MARK: - 充电速度对比

do {
	let current = ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(60 * 60), startPercent: 20, endPercent: 80, peakInputW: 60) // 60%/60min = 1.0%/min
	let fastPast = ChargeSession(startDate: t0.addingTimeInterval(-7200), endDate: t0.addingTimeInterval(-7200 + 3600), startPercent: 20, endPercent: 80, peakInputW: 60)
	let slowPast = ChargeSession(startDate: t0.addingTimeInterval(-14400), endDate: t0.addingTimeInterval(-14400 + 9000), startPercent: 20, endPercent: 50, peakInputW: 30) // 30%/150min = 0.2

	// 平均 = (1.0 + 0.2)/2 = 0.6；current 1.0 → 快约 67%
	let faster = UsagePatternAnalyzer.chargeSpeedComparison(current: current, history: [fastPast, slowPast])
	expect(faster?.contains("比平时快") == true, "充速对比：明显快于平均")

	// current 换成慢的（0.2 vs 平均 0.6）→ 慢约 67%
	let slowNow = ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(60 * 250), startPercent: 20, endPercent: 50, peakInputW: 30)
	let slower = UsagePatternAnalyzer.chargeSpeedComparison(current: slowNow, history: [fastPast, slowPast])
	expect(slower?.contains("比平时慢") == true, "充速对比：明显慢于平均")

	// 只有一条历史 → 不给
	expect(UsagePatternAnalyzer.chargeSpeedComparison(current: current, history: [fastPast]) == nil, "充速对比：样本不足不给")

	// 时长太短的闪充 → 不给
	let blink = ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(60), startPercent: 40, endPercent: 45, peakInputW: 60)
	expect(UsagePatternAnalyzer.chargeSpeedComparison(current: blink, history: [fastPast, slowPast]) == nil, "充速对比：时长太短不给")
}

// MARK: - 月度报告

do {
	var cal = Calendar(identifier: .gregorian)
	cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!

	// 8 月 1 日 9 点后 → 本月 1 号 9 点
	let aug2 = cal.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 10))!
	let aug1Due = cal.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 9))!
	expectEqual(BatteryAlertController.mostRecentMonthlyDigestDue(before: aug2, calendar: cal), aug1Due, "月报：1 号 9 点后用本月 1 号")

	// 8 月 1 日 8 点 → 还没到点，用 7 月 1 号
	let aug1Early = cal.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 8))!
	let jul1Due = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 9))!
	expectEqual(BatteryAlertController.mostRecentMonthlyDigestDue(before: aug1Early, calendar: cal), jul1Due, "月报：1 号 9 点前用上月 1 号")

	// 月报正文：due 是 8 月 1 号 → 汇总 7 月数据
	let history = [
		DailyUsage(dayKey: "2026-07-01", drainedPercent: 30, chargedPercent: 40),
		DailyUsage(dayKey: "2026-07-15", drainedPercent: 31, chargedPercent: 35),
		DailyUsage(dayKey: "2026-08-01", drainedPercent: 99, chargedPercent: 99)  // 不该计入
	]
	let sessions = [
		ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(300), startPercent: 40, endPercent: 45, peakInputW: 60),
		ChargeSession(startDate: cal.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 12))!, endDate: cal.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 13))!, startPercent: 40, endPercent: 80, peakInputW: 60)
	]
	let health = [
		HealthSample(date: cal.date(from: DateComponents(year: 2026, month: 7, day: 1))!, healthPercent: 96, cycleCount: 100),
		HealthSample(date: cal.date(from: DateComponents(year: 2026, month: 7, day: 31))!, healthPercent: 95, cycleCount: 102)
	]
	let body = BatteryAlertController.monthlyDigestBody(history: history, sessions: sessions, healthSamples: health, due: aug1Due, calendar: cal)
	expect(body.contains("上月用电 61%、充入 75%、充电 1 次"), "月报：正文汇总只计上月")
	expect(body.contains("日均用电 2%"), "月报：日均按当月天数摊")
	expect(body.contains("月末健康度 95%"), "月报：取当月最后一个健康度样本")

	// 上月完全没数据 → 空串不发
	let empty = BatteryAlertController.monthlyDigestBody(history: [], sessions: [], healthSamples: [], due: aug1Due, calendar: cal)
	expect(empty.isEmpty, "月报：上月无数据返回空串")
}

// MARK: - 应用耗电累计

do {
	// 首次累计：建档并计入当日秒数
	var records = BatteryHistoryRecorder.appendingEnergySeconds(
		[], ids: ["com.a"], names: ["com.a": "应用A"], seconds: 10,
		dayKey: "2026-08-10", cutoffDayKey: "2026-07-11", now: t0, maxApps: 50
	)
	expectEqual(records.count, 1, "应用耗电：首次累计建档")
	expect(abs(records[0].secondsByDay["2026-08-10"]! - 10) < 0.001, "应用耗电：秒数计入当日")

	// 再次累计：同日累加
	records = BatteryHistoryRecorder.appendingEnergySeconds(
		records, ids: ["com.a", "com.b"], names: ["com.a": "应用A", "com.b": "应用B"], seconds: 5,
		dayKey: "2026-08-10", cutoffDayKey: "2026-07-11", now: t0, maxApps: 50
	)
	expectEqual(records.count, 2, "应用耗电：新应用入档")
	let recordA = records.first { $0.bundleId == "com.a" }
	expect(recordA != nil && abs(recordA!.secondsByDay["2026-08-10"]! - 15) < 0.001, "应用耗电：同日累计累加")

	// 过期天被清掉、封顶生效
	var crowded: [AppEnergyUsage] = []
	for i in 0..<60 {
		crowded.append(AppEnergyUsage(bundleId: "com.\(i)", name: "应用\(i)", secondsByDay: ["2026-06-01": 10, "2026-08-10": 5], lastSeen: t0.addingTimeInterval(Double(i))))
	}
	let capped = BatteryHistoryRecorder.appendingEnergySeconds(
		crowded, ids: ["com.0"], names: ["com.0": "应用0"], seconds: 5,
		dayKey: "2026-08-10", cutoffDayKey: "2026-07-11", now: t0.addingTimeInterval(999), maxApps: 50
	)
	expectEqual(capped.count, 50, "应用耗电：总数封顶 50")
	expect(capped.allSatisfy { $0.secondsByDay["2026-06-01"] == nil }, "应用耗电：过期天被清理")

	// 指定日期集合内累计（com.0 今天累计 5+5）
	let keys: Set<String> = ["2026-08-09", "2026-08-10"]
	let kept = capped.first { $0.bundleId == "com.0" }
	expect(kept != nil && abs(kept!.seconds(within: keys) - 10) < 0.001, "应用耗电：按日期集合累计")
}

// MARK: - 电池身份证解码

// 十六进制串转 Data（构造实机 fixture 用）
func dataFromHex(_ hex: String) -> Data {
	var bytes: [UInt8] = []
	var index = hex.startIndex
	while index < hex.endIndex {
		let next = hex.index(index, offsetBy: 2)
		bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
		index = next
	}
	return Data(bytes)
}

do {
	// 实机 ManufacturerData 原始字节（Mac14,10）：TLV 里藏 "1916" 日期码、
	// "002" 批次、
	// "ATL" 电芯厂商
	let fixture = dataFromHex("000000000b0001000a1400000431393136033030320341544c00090000000000")
	let parsed = BatteryIdentityDecoder.parseManufacturerData(fixture)
	expect(parsed != nil, "身份证：厂商数据可解析")
	expectEqual(parsed?.dateCode, "1916", "身份证：日期码提取")
	expectEqual(parsed?.vendorCode, "ATL", "身份证：电芯厂商码提取")

	// 纯二进制噪声里没有长度前缀 ASCII 串，不该解析出东西
	let noise = dataFromHex("0001ff00ffff0200aa")
	expect(BatteryIdentityDecoder.parseManufacturerData(noise) == nil, "身份证：二进制噪声不误报")

	// 无日期码但有厂商码的变体（[长度 3]"ATC"）
	let vendorOnly = dataFromHex("00034154434c")
	let vendorParsed = BatteryIdentityDecoder.parseManufacturerData(vendorOnly)
	expectEqual(vendorParsed?.vendorCode, "ATC", "身份证：无日期码时厂商码仍可提取")

	// 厂商展示名映射
	expectEqual(BatteryIdentityDecoder.vendorDisplayName("ATL"), "ATL（新能源科技）", "身份证：ATL 映射")
	expectEqual(BatteryIdentityDecoder.vendorDisplayName("LGC"), "LG 化学", "身份证：LGC 映射")
	expectEqual(BatteryIdentityDecoder.vendorDisplayName("XYZ"), "XYZ", "身份证：未收录厂商显示原码")
	expect(BatteryIdentityDecoder.vendorDisplayName(nil) == nil, "身份证：无厂商返回空")

	// YYWW 日期码
	expectEqual(BatteryIdentityDecoder.dateCodeText("1916"), "2019 年第 16 周", "身份证：YYWW 解码")
	expectEqual(BatteryIdentityDecoder.dateCodeText("2301"), "2023 年第 1 周", "身份证：个位数周解码")
	expect(BatteryIdentityDecoder.dateCodeText("2399") == nil, "身份证：周数超界拒绝")
	expect(BatteryIdentityDecoder.dateCodeText("2A16") == nil, "身份证：非数字码拒绝")

	// Apple Silicon 大整数日期（osquery 逆向的 100µs 计数，本机实值）
	expectEqual(
		BatteryIdentityDecoder.manufactureDateText(largeValue: 60_684_434_944_307, now: t0),
		"2020 年 3 月 25 日",
		"身份证：大整数日期解码（本机实值）"
	)
	// osquery issue 里的 Intel 实值，交叉验证编码
	expectEqual(
		BatteryIdentityDecoder.manufactureDateText(largeValue: 54_087_348_467_250, now: t0),
		"2018 年 2 月 21 日",
		"身份证：大整数日期解码（社区实值）"
	)
	// 噪声大整数（解出来不在合理区间）拒绝
	expect(BatteryIdentityDecoder.manufactureDateText(largeValue: 999_999_999_999_999, now: t0) == nil, "身份证：噪声大整数拒绝")

	// Intel SMBus 16 位日期字：(39<<9)|(4<<5)|17 = 2019-04-17
	let word = (39 << 9) | (4 << 5) | 17
	expectEqual(BatteryIdentityDecoder.smbusDateText(word, now: t0), "2019 年 4 月 17 日", "身份证：SMBus 日期字解码")
	// 0xFFFF：月份位溢出（15），拒绝
	expect(BatteryIdentityDecoder.smbusDateText(0xFFFF, now: t0) == nil, "身份证：SMBus 非法字段拒绝")

	// 电芯均衡
	expectEqual(BatteryIdentityDecoder.cellBalanceText([4281, 4280, 4278]), "3 芯 · 压差 3 mV", "身份证：电芯均衡文本")
	expect(BatteryIdentityDecoder.cellBalance([4281, 4278])?.deltaMV == 3, "身份证：压差计算")
	expect(BatteryIdentityDecoder.cellBalanceText([4200]) == nil, "身份证：单芯无均衡可言")
}

// MARK: - 续航换算

do {
	// 50% 电量、10%/小时：轻度 50/6.5=461 分，视频 50/12.5=240 分，会议 50/17=176 分
	expectEqual(RuntimeScenarioEstimator.minutesRemaining(socPercent: 50, percentPerHour: 10, multiplier: 0.65), 461, "续航换算：轻度场景")
	expectEqual(RuntimeScenarioEstimator.minutesRemaining(socPercent: 50, percentPerHour: 10, multiplier: 1.25), 240, "续航换算：视频场景")
	expectEqual(RuntimeScenarioEstimator.minutesRemaining(socPercent: 50, percentPerHour: 10, multiplier: 1.7), 176, "续航换算：会议场景")

	// 全场景结果按枚举顺序返回
	let rows = RuntimeScenarioEstimator.estimates(socPercent: 50, percentPerHour: 10)
	expectEqual(rows.count, 3, "续航换算：三场景齐全")
	expectEqual(rows.first?.scenario, .lightUse, "续航换算：顺序从轻度开始")
	expectEqual(rows.first?.minutes, 461, "续航换算：场景行数据一致")

	// 边界：没电、没掉速都不给结论
	expect(RuntimeScenarioEstimator.minutesRemaining(socPercent: 0, percentPerHour: 10, multiplier: 0.65) == nil, "续航换算：0% 不换算")
	expect(RuntimeScenarioEstimator.minutesRemaining(socPercent: 50, percentPerHour: 0, multiplier: 0.65) == nil, "续航换算：零掉速不换算")
}

// MARK: - 电量计跳变

do {
	// 判定：±2% 是跳变，1% 不是；回升（电量计自我修正）也算
	expect(UsagePatternAnalyzer.isSocJump(from: 98, to: 96), "跳变：下跳 2% 判跳")
	expect(UsagePatternAnalyzer.isSocJump(from: 95, to: 97), "跳变：回升 2% 判跳")
	expect(!UsagePatternAnalyzer.isSocJump(from: 98, to: 97), "跳变：1% 不算")
	expect(!UsagePatternAnalyzer.isSocJump(from: 50, to: 50), "跳变：持平不算")

	// 累计与封顶
	var events: [SocJumpEvent] = []
	for i in 0..<4 {
		events = BatteryHistoryRecorder.appendingSocJump(events, from: 90, to: 88, at: t0.addingTimeInterval(Double(i) * 60), maxEvents: 3)
	}
	expectEqual(events.count, 3, "跳变：事件数封顶")
	expectEqual(events.first?.fromPercent, 90, "跳变：封顶后丢最旧")

	// 时间窗计数：5 天前 + 40 天前各一跳，30 天窗只算 1 次
	let windowEvents = [
		SocJumpEvent(date: t0.addingTimeInterval(-5 * 86400), fromPercent: 90, toPercent: 88),
		SocJumpEvent(date: t0.addingTimeInterval(-40 * 86400), fromPercent: 80, toPercent: 78)
	]
	expectEqual(UsagePatternAnalyzer.socJumpCount(windowEvents, withinDays: 30, now: t0), 1, "跳变：窗口只计窗内")

	// 阈值判定
	expect(UsagePatternAnalyzer.gaugeNeedsCalibration(jumpCount: 5), "跳变：达到阈值建议校准")
	expect(!UsagePatternAnalyzer.gaugeNeedsCalibration(jumpCount: 4), "跳变：未达阈值不建议")
}

// MARK: - 充电阶段判定

do {
	// 64%（快充区间）
	expectEqual(UsagePatternAnalyzer.chargingPhase(socPercent: 64), .constantCurrent, "充电阶段：64% 恒流快充")
	// 79% 仍是恒流，80% 进恒压
	expectEqual(UsagePatternAnalyzer.chargingPhase(socPercent: 79), .constantCurrent, "充电阶段：79% 仍恒流")
	expectEqual(UsagePatternAnalyzer.chargingPhase(socPercent: 80), .constantVoltage, "充电阶段：80% 进恒压")
	// 95% 进涓流
	expectEqual(UsagePatternAnalyzer.chargingPhase(socPercent: 95), .trickle, "充电阶段：95% 进涓流")
	expectEqual(ChargingPhase.trickle.label, "涓流补足", "充电阶段：标签文案完整")
	expectEqual(ChargingPhase.constantVoltage.label, "恒压缓充", "充电阶段：恒压标签文案")
	expect(!ChargingPhase.trickle.explanation.isEmpty, "充电阶段：涓流解释文案非空")
	// 无电量数据不给结论
	expect(UsagePatternAnalyzer.chargingPhase(socPercent: nil) == nil, "充电阶段：无电量返回空")
	expect(UsagePatternAnalyzer.chargingPhase(socPercent: 150) == nil, "充电阶段：越界值拒绝")
}

// MARK: - IOKit 读取层纯函数

do {
	// 充电协议识别：FamilyCode 魔数优先，描述关键词兜底，无线优先
	expectEqual(IOKitBatteryReader.protocolName(familyCode: 0xE000400A, description: nil, isWireless: false), "USB-C PD", "协议识别：USB-C PD 魔数")
	expectEqual(IOKitBatteryReader.protocolName(familyCode: 0xE0004009, description: nil, isWireless: false), "USB-C", "协议识别：USB-C 魔数")
	expectEqual(IOKitBatteryReader.protocolName(familyCode: 0xE0004003, description: nil, isWireless: false), "USB", "协议识别：USB 魔数段")
	expectEqual(IOKitBatteryReader.protocolName(familyCode: 0xE0024123, description: nil, isWireless: false), "交流电源", "协议识别：交流电源魔数段")
	expectEqual(IOKitBatteryReader.protocolName(familyCode: nil, description: "65W USB-C PD Charger", isWireless: false), "USB-C PD", "协议识别：描述含 pd 兜底")
	expectEqual(IOKitBatteryReader.protocolName(familyCode: nil, description: nil, isWireless: true), "无线充电", "协议识别：无线优先")
	expect(IOKitBatteryReader.protocolName(familyCode: nil, description: "unknown", isWireless: false) == nil, "协议识别：认不出返回空")

	// 温度换算：0.01°C → °C，一位小数四舍五入，越界丢弃
	expectEqual(IOKitBatteryReader.temperatureC(fromRawCentiC: 3650), 36.5, "温度换算：3650 → 36.5°C")
	expectEqual(IOKitBatteryReader.temperatureC(fromRawCentiC: 3649), 36.5, "温度换算：36.49 进到 36.5")
	expectEqual(IOKitBatteryReader.temperatureC(fromRawCentiC: 3644), 36.4, "温度换算：36.44 保留 36.4")
	expect(IOKitBatteryReader.temperatureC(fromRawCentiC: 0) == nil, "温度换算：0 视为无数据")
	expect(IOKitBatteryReader.temperatureC(fromRawCentiC: 12_345) == nil, "温度换算：123.45°C 越界拒绝")

	// 整机功率降级链：SystemPower → AvgSystemPower → AverageSystemPower → 遥测 → SystemPowerIn-充电
	expectEqual(IOKitBatteryReader.systemPowerW(props: ["SystemPower": 5000], isExternalPowerConnected: true, chargingPowerW: 3.0), 5.0, "整机功率：SystemPower 优先")
	expectEqual(IOKitBatteryReader.systemPowerW(props: ["AvgSystemPower": 4000], isExternalPowerConnected: true, chargingPowerW: 3.0), 4.0, "整机功率：AvgSystemPower 次选")
	expectEqual(IOKitBatteryReader.systemPowerW(props: ["PowerTelemetryData": ["SystemPower": 2100]], isExternalPowerConnected: true, chargingPowerW: 3.0), 2.1, "整机功率：遥测 SystemPower 再次")
	expectEqual(IOKitBatteryReader.systemPowerW(props: ["PowerTelemetryData": ["SystemPowerIn": 20_000]], isExternalPowerConnected: true, chargingPowerW: 3.0), 17.0, "整机功率：SystemPowerIn 扣除充电功率")
	expect(IOKitBatteryReader.systemPowerW(props: ["PowerTelemetryData": ["SystemPowerIn": 20_000]], isExternalPowerConnected: false, chargingPowerW: nil) == nil, "整机功率：电池模式不用 SystemPowerIn")
	expect(IOKitBatteryReader.systemPowerW(props: [:], isExternalPowerConnected: true, chargingPowerW: nil) == nil, "整机功率：无数据返回空")
}

// MARK: - 免打扰时段判定与配置

do {
	// 默认 23 点–次日 8 点（跨零点）：起点含、终点不含
	expect(BatteryAlertController.isQuietHour(23, start: 23, end: 8), "免打扰：23 点开始")
	expect(BatteryAlertController.isQuietHour(3, start: 23, end: 8), "免打扰：凌晨 3 点静音")
	expect(!BatteryAlertController.isQuietHour(8, start: 23, end: 8), "免打扰：8 点整已结束")
	expect(!BatteryAlertController.isQuietHour(12, start: 23, end: 8), "免打扰：白天不静音")

	// 同日区间：1 点–5 点
	expect(BatteryAlertController.isQuietHour(1, start: 1, end: 5), "免打扰：同日区间起点含")
	expect(BatteryAlertController.isQuietHour(4, start: 1, end: 5), "免打扰：同日区间内")
	expect(!BatteryAlertController.isQuietHour(5, start: 1, end: 5), "免打扰：同日区间终点不含")

	// 起止相同视为关闭，避免整天静音
	expect(!BatteryAlertController.isQuietHour(12, start: 8, end: 8), "免打扰：起止相同视为关闭")

	// 旧档缺省 23/8；手改离谱值夹回 0~23
	let legacyJSON = #"{"enabledOptions":["alerts"],"menuBarContent":"icon"}"#.data(using: .utf8)!
	let legacy = try JSONDecoder().decode(AppConfiguration.self, from: legacyJSON)
	expectEqual(legacy.quietHoursStartHour, 23, "免打扰配置：旧档缺省开始 23 点")
	expectEqual(legacy.quietHoursEndHour, 8, "免打扰配置：旧档缺省结束 8 点")

	var config = AppConfiguration()
	config.quietHoursStartHour = 99
	config.quietHoursEndHour = -3
	let fixed = config.normalized()
	expectEqual(fixed.quietHoursStartHour, 23, "免打扰配置：开始夹到 0~23")
	expectEqual(fixed.quietHoursEndHour, 0, "免打扰配置：结束夹到 0~23")
} catch {
	expect(false, "免打扰配置：解码不应失败（\(error)）")
}

// MARK: - 充电器统计清理

do {
	let profiled = ChargerProfile(key: "a|b|65", name: "65W", ratedWatts: 65, firstSeen: t0, lastSeen: t0, connectCount: 2)
	var stats: [String: ChargerPowerStats] = [
		"a|b|65": ChargerPowerStats(key: "a|b|65", ratedWatts: 65),
		"ghost|g|30": ChargerPowerStats(key: "ghost|g|30", ratedWatts: 30)
	]
	stats["ghost|g|30"]?.sampleCount = 10

	let pruned = BatteryHistoryRecorder.pruningChargerPowerStats(stats, keeping: [profiled])
	expectEqual(pruned.count, 1, "统计清理：不在档案的充电器统计被清掉")
	expect(pruned["a|b|65"] != nil, "统计清理：在档统计保留")
	expect(pruned["ghost|g|30"] == nil, "统计清理：孤儿统计移除")
}

// MARK: - 设置文案完整性

do {
	// 每个开关都有一句说明（设置窗口行内展示 + 搜索匹配字段），漏一个就补
	expect(DisplayOption.allCases.allSatisfy { !$0.detail.isEmpty }, "设置文案：每个选项都有说明")
	expect(DisplayOption.allCases.allSatisfy { !$0.title.isEmpty }, "设置文案：每个选项都有标题")
	// 保养线阈值可调（70~90），开关名不能写死 80%
	expect(!DisplayOption.chargeCareReminder.title.contains("80"), "设置文案：保养提醒不写死阈值")
}

// MARK: - 跨睡眠电量归因

do {
	// 睡了一小时醒来掉 2%：不算“今天用电”——夜间掉电由睡眠掉电卡片负责
	var usage = DailyUsage(dayKey: "2026-08-29")
	usage = BatteryHistoryRecorder.accumulatingDailyUsage(
		usage, percent: 78, lastPercent: 80, powerSource: .battery, isCharging: false,
		secondsSinceLastSample: 3600
	)
	expectEqual(usage.drainedPercent, 0, "跨睡眠归因：睡一小时的掉电不计入今日用电")

	// 整夜插电充电醒来涨 8%：同理不计入今日充入
	usage = BatteryHistoryRecorder.accumulatingDailyUsage(
		usage, percent: 86, lastPercent: 78, powerSource: .powerAdapter, isCharging: true,
		secondsSinceLastSample: 8 * 3600
	)
	expectEqual(usage.chargedPercent, 0, "跨睡眠归因：整夜充电不计入今日充入")

	// 醒着时正常采样（间隔 ≤3 分钟）照常累计
	usage = BatteryHistoryRecorder.accumulatingDailyUsage(
		usage, percent: 84, lastPercent: 86, powerSource: .battery, isCharging: false,
		secondsSinceLastSample: 120
	)
	expectEqual(usage.drainedPercent, 2, "跨睡眠归因：3 分钟内正常采样照常计入")

	// 恰好 3 分钟算连续（边界锁死）
	usage = BatteryHistoryRecorder.accumulatingDailyUsage(
		usage, percent: 83, lastPercent: 84, powerSource: .battery, isCharging: false,
		secondsSinceLastSample: 180
	)
	expectEqual(usage.drainedPercent, 3, "跨睡眠归因：恰好 3 分钟视为连续")

	// 超窗 1 秒即断开
	usage = BatteryHistoryRecorder.accumulatingDailyUsage(
		usage, percent: 82, lastPercent: 83, powerSource: .battery, isCharging: false,
		secondsSinceLastSample: 181
	)
	expectEqual(usage.drainedPercent, 3, "跨睡眠归因：超 3 分钟不计入")
}

// MARK: - 应用耗电重复键防护

do {
	// 存档若出现重复 bundleId（手改/异常数据），合并不崩、保留首条再累计
	let duplicated: [AppEnergyUsage] = [
		AppEnergyUsage(bundleId: "com.a", name: "A1", secondsByDay: ["2026-08-29": 5], lastSeen: t0),
		AppEnergyUsage(bundleId: "com.a", name: "A2", secondsByDay: ["2026-08-29": 7], lastSeen: t0)
	]
	let merged = BatteryHistoryRecorder.appendingEnergySeconds(
		duplicated, ids: ["com.a"], names: ["com.a": "A"], seconds: 3,
		dayKey: "2026-08-29", cutoffDayKey: "2026-08-01", now: t0, maxApps: 50
	)
	expectEqual(merged.count, 1, "应用耗电：重复 bundleId 合并不崩")
	expect(merged.first.map { abs(($0.secondsByDay["2026-08-29"] ?? 0) - 8) < 0.001 } == true,
		   "应用耗电：重复键保留首条并累计新秒数")
}

// MARK: - 睡眠断言解析

do {
	let output = """
	Assertion status system-wide:
	   BackgroundTask                 0
	   PreventUserIdleSystemSleep     1
	   PreventUserIdleDisplaySleep    0
	Listed by owning process:
	   pid 345(coreaudiod): [0x0000abc123] 00:00:42 PreventUserIdleSystemSleep named: "com.apple.audio.context333"
	   pid 567(caffeinate): [0x0000def456] 03:12:11 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
	   pid 89(logd): [0x0000aaa] 00:10:00 PreventUserIdleDisplaySleep named: "display holder"
	"""
	let owners = SleepAssertionReader.parseAssertionOwners(output)
	expectEqual(owners, ["coreaudiod", "caffeinate"], "睡眠断言：只点名阻止系统睡眠的进程")
	expect(SleepAssertionReader.parseAssertionOwners("no assertions here").isEmpty, "睡眠断言：无关输出为空")
}

// MARK: - 库仑计数估算

do {
	// 恒流 500mA、容量 5000mAh、放电到 85%：剩余 4250mAh → 510 分钟
	var estimator = DrainRateEstimator()
	for i in 0...15 {
		var s = batterySnap(percent: 90 - i / 3)
		s.batteryAmperageMA = -500
		s.maxCapacityMAh = 5000
		estimator.record(snapshot: s, at: t0.addingTimeInterval(Double(i) * 120))
	}
	let estimate = estimator.estimate()
	expect(estimate != nil, "库仑计数：正常放电给出估算")
	expectEqual(estimate?.estimatedMinutesRemaining, 510, "库仑计数：剩余电荷÷平均电流")
	expect(abs((estimate?.percentPerHour ?? 0) - 10.0) < 0.01, "库仑计数：%/小时仍按电量差分")

	// 电流样本不足（5 条 < 10）退回百分比法：78% @ 60%/小时 = 78 分钟
	var fewLong = DrainRateEstimator()
	for i in 0...4 {
		var s = batterySnap(percent: 90 - i * 3)
		s.batteryAmperageMA = -500
		s.maxCapacityMAh = 5000
		fewLong.record(snapshot: s, at: t0.addingTimeInterval(Double(i) * 180))
	}
	let fewEstimate = fewLong.estimate()
	expect(fewEstimate != nil, "库仑计数：电流样本不足仍可给估算")
	expectEqual(fewEstimate?.estimatedMinutesRemaining, 78, "库仑计数：样本不足退回百分比法")
}

// 纯函数核心：时间加权平均电流（前 6 分钟 500mA、后 6 分钟 1000mA）
do {
	let samples: [(date: Date, dischargeMA: Double?, maxCapacityMAh: Int?)] = (0..<12).map { i in
		(t0.addingTimeInterval(Double(i) * 60), i < 6 ? 500.0 : 1000.0, 5000)
	}
	expectEqual(DrainRateEstimator.coulombMinutesRemaining(samples: samples, socPercent: 80), 329, "库仑计数：变电流按采样间隔加权")
	expect(DrainRateEstimator.coulombMinutesRemaining(samples: [], socPercent: 80) == nil, "库仑计数：无原料返回空")
}

// MARK: - 高电量驻留

do {
	var usage = DailyUsage(dayKey: "2026-08-30")
	usage.soc90to100Seconds = 600
	usage.soc80to90Seconds = 300
	usage.acSeconds = 1200
	usage.batterySeconds = 600
	expectEqual(usage.dwell80PlusMinutes, 15, "高电量驻留：80%+ 合计分钟")
	expect(abs((usage.highSocDwellShare ?? 0) - 0.5) < 0.001, "高电量驻留：占比 50%")

	var short = DailyUsage(dayKey: "2026-08-30")
	short.soc90to100Seconds = 600
	short.acSeconds = 600
	expect(short.dwell80PlusMinutes == nil, "高电量驻留：样本不足不给结论")
	expect(short.highSocDwellShare == nil, "高电量驻留：样本不足占比为空")

	let legacyJSON = #"[{"dayKey":"2026-08-29","drainedPercent":10}]"#.data(using: .utf8)!
	let decoded = try JSONDecoder().decode([DailyUsage].self, from: legacyJSON)
	expectEqual(decoded.first?.soc90to100Seconds, 0, "高电量驻留：旧档缺省 0")
} catch {
	expect(false, "高电量驻留：解码不应失败（\(error)）")
}

// MARK: - 健康样本月度折叠

do {
	let calendar = Calendar(identifier: .gregorian)
	let start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 12))!
	var samples: [HealthSample] = []
	for day in 0..<420 {
		samples.append(HealthSample(date: start.addingTimeInterval(Double(day) * 86400), healthPercent: 100 - day / 30, cycleCount: 100 + day))
	}

	// 封顶 400：最旧一个月（1 月 31 个日样本）折成 1 点
	let folded = BatteryHistoryRecorder.foldingHealthSamples(samples, maxRawCount: 400)
	expectEqual(folded.count, 390, "健康折叠：最旧一个月折成 1 点")
	expectEqual(folded.first?.healthPercent, samples[30].healthPercent, "健康折叠：保留当月最后读数")
	expectEqual(folded.first?.cycleCount, samples[30].cycleCount, "健康折叠：循环数同点保留")
	expectEqual(folded.last?.healthPercent, samples.last?.healthPercent, "健康折叠：近期数据原样保留")

	// 最旧月已是单点时本轮无进展（等新数据积累后再折叠），不崩不变
	let twice = BatteryHistoryRecorder.foldingHealthSamples(folded, maxRawCount: 380)
	expectEqual(twice.count, 390, "健康折叠：单点月无可折叠，原样返回")
}

// MARK: - 历史存档编解码

do {
	let archive = BatteryHistoryArchive(
		exportedAt: t0,
		sessions: [ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(600), startPercent: 40, endPercent: 50, peakInputW: 30)],
		healthSamples: [HealthSample(date: t0, healthPercent: 95, cycleCount: 100)],
		dailyHistory: [DailyUsage(dayKey: "2026-08-30", drainedPercent: 10, chargedPercent: 20, acSeconds: 3600, batterySeconds: 600, soc80to90Seconds: 300, soc90to100Seconds: 100)],
		lastSleepDrain: SleepDrainRecord(sleepDate: t0, wakeDate: t0.addingTimeInterval(3600), startPercent: 80, endPercent: 79),
		chargerProfiles: [ChargerProfile(key: "a|b|65", name: "65W", ratedWatts: 65, firstSeen: t0, lastSeen: t0, connectCount: 3)],
		socSamples: [SOCSample(date: t0, percent: 80, isCharging: false)],
		powerEvents: [PowerEvent(date: t0, kind: .pluggedIn)],
		chargerPowerStats: ["a|b|65": ChargerPowerStats(key: "a|b|65", ratedWatts: 65)],
		hourlyDrainStats: HourlyDrainStats(),
		appEnergy: [AppEnergyUsage(bundleId: "com.a", name: "A", secondsByDay: ["2026-08-30": 60], lastSeen: t0)],
		socJumpEvents: [SocJumpEvent(date: t0, fromPercent: 90, toPercent: 88)]
	)
	if let data = BatteryHistoryArchive.encode(archive), let decoded = BatteryHistoryArchive.decode(data) {
		expectEqual(decoded.sessions.count, 1, "存档：充电记录往返")
		expectEqual(decoded.sessions.first?.startDate, archive.sessions.first?.startDate, "存档：日期往返一致")
		expectEqual(decoded.dailyHistory.first?.soc90to100Seconds, 100, "存档：驻留字段往返")
		expectEqual(decoded.chargerProfiles.first?.connectCount, 3, "存档：充电器档案往返")
		expectEqual(decoded.version, BatteryHistoryArchive.currentVersion, "存档：版本号")
	} else {
		expect(false, "历史存档：编解码不应失败")
	}

	expect(BatteryHistoryArchive.decode(#"{"version":99}"#.data(using: .utf8)!) == nil, "存档：版本不符拒绝")
	expect(BatteryHistoryArchive.decode(Data([0xFF, 0xFE])) == nil, "存档：垃圾数据拒绝")
}

// MARK: - 合成一周不变量（属性测试）

do {
	// 确定性伪随机（LCG），种子固定整条时间线可复现
	var seed: UInt64 = 88
	func rand(_ n: Int) -> Int {
		seed = seed &* 6364136223846793005 &+ 1442695040888963407
		return Int((seed >> 33) % UInt64(max(n, 1)))
	}

	let calendar = Calendar(identifier: .gregorian)
	let monday8am = calendar.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 8))!
	var days: [DailyUsage] = []
	var hourly = HourlyDrainStats()
	var percentDouble = 100.0
	var previousSampled: Int?
	var lastDate: Date?
	var expectedDrained = 0
	var expectedCharged = 0

	for day in 0..<7 {
		percentDouble = 100.0  // 每晚插满，早上满电出门
		for minute in stride(from: 0, to: 16 * 60, by: 5) {
			let date = monday8am.addingTimeInterval(Double(day) * 86400 + Double(minute) * 60)
			let chargingPeriod = day == 2 && minute >= 240 && minute < 480  // 周三 12-16 点插电充电
			if chargingPeriod {
				percentDouble = min(100, percentDouble + 0.8)
			} else if percentDouble > 3 {
				percentDouble -= Double(4 + rand(8)) * 5 / 60  // 4~11%/小时
			}
			let sampled = Int(percentDouble)
			let key = UsagePatternAnalyzer.dayKeyString(date)
			if days.last?.dayKey != key { days.append(DailyUsage(dayKey: key)) }

			let gap = lastDate.map { date.timeIntervalSince($0) }
			let contiguous = (gap ?? 0) > 0 && (gap ?? 0) <= 180
			if contiguous {
				if !chargingPeriod, let previous = previousSampled, sampled < previous {
					expectedDrained += previous - sampled
				}
				if chargingPeriod, let previous = previousSampled, sampled > previous {
					expectedCharged += sampled - previous
				}
			}

			let before = days[days.count - 1]
			days[days.count - 1] = BatteryHistoryRecorder.accumulatingDailyUsage(
				before,
				percent: sampled,
				lastPercent: previousSampled,
				powerSource: chargingPeriod ? .powerAdapter : .battery,
				isCharging: chargingPeriod,
				secondsSinceLastSample: gap
			)
			let frameDrop = (!chargingPeriod && contiguous) ? previousSampled.map { sampled < $0 ? Double($0 - sampled) : 0 } ?? 0 : 0
			hourly = UsagePatternAnalyzer.accumulatingHourlyDrain(
				hourly,
				hour: calendar.component(.hour, from: date),
				droppedPercent: frameDrop,
				dayKey: key
			)

			previousSampled = sampled
			lastDate = date
		}
	}

	// 不变量：睡眠断档不掉电、清醒掉电全归因
	expectEqual(days.reduce(0) { $0 + $1.drainedPercent }, expectedDrained, "合成一周：掉电归因与规则完全一致")
	// 不变量：充电归因完整
	expectEqual(days.reduce(0) { $0 + $1.chargedPercent }, expectedCharged, "合成一周：充电归因与规则完全一致")
	// 不变量：日期键严格递增（跨天滚动正确）
	expect(days.map(\.dayKey) == days.map(\.dayKey).sorted(), "合成一周：日期键严格递增")
	// 不变量：时段桶与日用电同源
	let bucketSum = hourly.drainedByHour.reduce(0, +)
	expect(abs(bucketSum - Double(expectedDrained)) < 0.001, "合成一周：时段桶合计 = 日用电")
	// 不变量：7 个有效天
	expectEqual(hourly.accumulatedDays, 7, "合成一周：有效天数")
	// 不变量：驻留不超过总时长、累计非负
	let dwell = days.reduce(0.0) { $0 + $1.soc80to90Seconds + $1.soc90to100Seconds }
	let totalTime = days.reduce(0.0) { $0 + $1.acSeconds + $1.batterySeconds }
	expect(dwell <= totalTime + 0.001, "合成一周：驻留 ≤ 总时长")
	expect(days.allSatisfy { $0.drainedPercent >= 0 && $0.chargedPercent >= 0 }, "合成一周：累计非负")
}

// MARK: - 通知交互与会话归档判定

do {
	// 保养提醒延后:到点前静音,过了立即解除
	let now = Date()
	expect(!BatteryAlertController.isChargeCareSnoozed(snoozeUntil: nil, now: now), "通知交互:无延后标记不静音")
	expect(BatteryAlertController.isChargeCareSnoozed(snoozeUntil: now.addingTimeInterval(60), now: now), "通知交互:延后窗口内静音")
	expect(!BatteryAlertController.isChargeCareSnoozed(snoozeUntil: now.addingTimeInterval(-60), now: now), "通知交互:延后过期解除")

	// 会话归档:优化充电的暂停(仍插着电)不算结束,拔电才算
	expect(!BatteryHistoryRecorder.shouldArchiveActiveSession(powerSource: .powerAdapter), "会话归档:暂停充电不归档")
	expect(BatteryHistoryRecorder.shouldArchiveActiveSession(powerSource: .battery), "会话归档:拔电归档")
}

// MARK: - 充电器命名

do {
	// 展示名解析：用户命名 > 系统识别名 > 额定瓦数兜底
	let anonymous = ChargerProfile(key: "||65", name: "", ratedWatts: 65, firstSeen: t0, lastSeen: t0, connectCount: 1)
	expectEqual(anonymous.displayName, "65W 充电器", "命名：认不出按瓦数兜底")
	var claimed = anonymous
	claimed.customName = "Anker · 桌面"
	expectEqual(claimed.displayName, "Anker · 桌面", "命名：用户命名优先")
	let apple = ChargerProfile(key: "96W USB-C Power Adapter|Apple Inc.|96", name: "96W USB-C Power Adapter", ratedWatts: 96, firstSeen: t0, lastSeen: t0, connectCount: 5)
	expectEqual(apple.displayName, "96W USB-C Power Adapter", "命名：系统识别名次之")

	// 重连更新档案时用户命名必须存活（只动 lastSeen/connectCount）
	let profiles = [claimed]
	let after = BatteryHistoryRecorder.upsertingChargerProfile(
		profiles,
		key: BatteryHistoryRecorder.chargerKey(name: "", manufacturer: "", ratedWatts: 65),
		name: "", manufacturer: "", ratedWatts: 65, now: t0.addingTimeInterval(3600)
	)
	expectEqual(after.first?.customName, "Anker · 桌面", "命名：重连保留用户命名")
	expectEqual(after.first?.connectCount, 2, "命名：重连超窗正常计次")

	// 旧版存档没有 customName 字段，解码缺省 nil 不炸
	let legacyJSON = #"[{"key":"a|b|65","name":"65W","ratedWatts":65,"firstSeen":0,"lastSeen":0,"connectCount":3}]"#.data(using: .utf8)!
	let decoder = JSONDecoder()
	decoder.dateDecodingStrategy = .secondsSince1970
	let decoded = try decoder.decode([ChargerProfile].self, from: legacyJSON)
	expect(decoded.first?.customName == nil, "命名：旧档缺字段解码为 nil")
	expectEqual(decoded.first?.displayName, "65W", "命名：旧档展示名正常")

	// 同瓦数不同充电器：PD 档位表不同 → 身份键分开，不再合并成一只
	let tiersA = [PowerTier(maxVoltageMV: 20000, maxCurrentMA: 5000), PowerTier(maxVoltageMV: 15000, maxCurrentMA: 3000)]
	let tiersB = [PowerTier(maxVoltageMV: 20000, maxCurrentMA: 5000), PowerTier(maxVoltageMV: 9000, maxCurrentMA: 3000)]
	let keyA = BatteryHistoryRecorder.chargerKey(name: "", manufacturer: "", ratedWatts: 100, tiers: tiersA)
	let keyB = BatteryHistoryRecorder.chargerKey(name: "", manufacturer: "", ratedWatts: 100, tiers: tiersB)
	expect(keyA != keyB, "身份键：不同档位表分开建档")
	// 档位顺序无关（排序稳定）
	expectEqual(BatteryHistoryRecorder.chargerKey(name: "", manufacturer: "", ratedWatts: 100, tiers: tiersA.reversed()), keyA, "身份键：档位顺序无关")
	// 非 PD 头无档位表 → 键退回旧格式，存量档案不重置
	expectEqual(BatteryHistoryRecorder.chargerKey(name: "a", manufacturer: "b", ratedWatts: 65, tiers: []), "a|b|65", "身份键：无档位保持旧格式")
	// 无线头带标记，与同瓦数有线头区分
	expect(BatteryHistoryRecorder.chargerKey(name: "", manufacturer: "", ratedWatts: 0, isWireless: true).hasSuffix("|无线"), "身份键：无线标记")
	// 新建档时档位签名入档（设置区展示用）
	let signed = BatteryHistoryRecorder.upsertingChargerProfile(
		[], key: keyA, name: "", manufacturer: "", ratedWatts: 100,
		tierSignature: BatteryHistoryRecorder.tierSignature(tiersA), now: t0
	)
	expect(signed.first?.tierSignature?.contains("20000V5000A") == true, "身份键：新档保存签名")
}

// MARK: - 电池更换检测与趋势边界

do {
	// 纯判定：首次只记基准；读不到不误报；变了才算更换
	expect(!BatteryHistoryRecorder.shouldFlagBatterySwap(stored: nil, current: "S1"), "电池更换：首次运行只记基准")
	expect(!BatteryHistoryRecorder.shouldFlagBatterySwap(stored: "S1", current: "S1"), "电池更换：序列号未变不报")
	expect(BatteryHistoryRecorder.shouldFlagBatterySwap(stored: "S1", current: "S2"), "电池更换：序列号变化报更换")
	expect(!BatteryHistoryRecorder.shouldFlagBatterySwap(stored: "", current: "S2"), "电池更换：空序列号不误报")
	expect(!BatteryHistoryRecorder.shouldFlagBatterySwap(stored: "S1", current: nil), "电池更换：读不到当前序列号不误报")

	// 趋势过滤：更换边界前的样本全部丢弃
	let calendar = Calendar(identifier: .gregorian)
	let day1 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
	let day200 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 20))!
	let replacedAt = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
	let samples = [
		HealthSample(date: day1, healthPercent: 88, cycleCount: 500),
		HealthSample(date: day200, healthPercent: 100, cycleCount: 10)
	]
	let filtered = BatteryHistoryRecorder.filteringHealthSamplesForTrend(samples, replacedAt: replacedAt)
	expectEqual(filtered.count, 1, "电池更换：趋势只看更换后")
	expectEqual(filtered.first?.healthPercent, 100, "电池更换：基线重置为新电池")
	expectEqual(BatteryHistoryRecorder.filteringHealthSamplesForTrend(samples, replacedAt: nil).count, 2, "电池更换：无边界保留全部")
}

// MARK: - 会话关联充电器

do {
	// 旧档没有 chargerKey 字段，解码为 nil 不炸
	let legacyJSON = #"[{"startDate":0,"endDate":300,"startPercent":40,"endPercent":55,"peakInputW":60}]"#.data(using: .utf8)!
	let decoder = JSONDecoder()
	decoder.dateDecodingStrategy = .secondsSince1970
	let legacy = try decoder.decode([ChargeSession].self, from: legacyJSON)
	expect(legacy.first?.chargerKey == nil, "会话认头：旧档缺字段解码为 nil")

	// 同头对比：两只头速度不同，混着比会骗人——认得出头时只和同一只比
	let current = ChargeSession(startDate: t0, endDate: t0.addingTimeInterval(3600), startPercent: 20, endPercent: 80, peakInputW: 60, chargerKey: "anker")
	let ankerPast = [
		ChargeSession(startDate: t0.addingTimeInterval(-7200), endDate: t0.addingTimeInterval(-3600), startPercent: 20, endPercent: 80, peakInputW: 60, chargerKey: "anker"),
		ChargeSession(startDate: t0.addingTimeInterval(-14400), endDate: t0.addingTimeInterval(-10800), startPercent: 20, endPercent: 80, peakInputW: 60, chargerKey: "anker")
	]
	let appleFast = ChargeSession(startDate: t0.addingTimeInterval(-18000), endDate: t0.addingTimeInterval(-16200), startPercent: 20, endPercent: 80, peakInputW: 96, chargerKey: "apple")
	// 同头样本足够：措辞是"用这只充电器"，不被苹果头的快样本拉偏
	let sameChargerText = UsagePatternAnalyzer.chargeSpeedComparison(current: current, history: ankerPast + [appleFast])
	expect(sameChargerText?.contains("用这只充电器") == true, "会话认头：优先与同一只充电器对比")
	expect(sameChargerText?.contains("相当") == true, "会话认头：同头同速判相当")
	// 同头样本不足：退回全局对比，措辞"平时"
	let globalText = UsagePatternAnalyzer.chargeSpeedComparison(current: current, history: [appleFast, ankerPast[0]])
	expect(globalText?.contains("平时") == true, "会话认头：同头样本不足退回全局")
}

// MARK: - 温度 × 时段用电交叉洞察

do {
	var drain = HourlyDrainStats()
	var temp = HourlyTempStats()
	// 3 天：18 点用电最多，18 点也是温度峰值时段
	for day in 1...3 {
		let key = "2026-09-0\(day)"
		drain = UsagePatternAnalyzer.accumulatingHourlyDrain(drain, hour: 18, droppedPercent: 3, dayKey: key)
		drain = UsagePatternAnalyzer.accumulatingHourlyDrain(drain, hour: 9, droppedPercent: 1, dayKey: key)
		temp = UsagePatternAnalyzer.accumulatingHourlyTemp(temp, hour: 18, celsius: 38, dayKey: key)
		temp = UsagePatternAnalyzer.accumulatingHourlyTemp(temp, hour: 9, celsius: 31, dayKey: key)
	}
	let insight = UsagePatternAnalyzer.heatUsageOverlapInsight(drain: drain, temp: temp)
	expect(insight?.contains("18 点") == true, "热叠加洞察：高峰与最热时段重叠时给提示")
	expect(insight?.contains("散热") == true, "热叠加洞察：文案含建议")

	// 高峰在凉快时段（9 点）不打扰
	var coolDrain = HourlyDrainStats()
	for day in 1...3 {
		coolDrain = UsagePatternAnalyzer.accumulatingHourlyDrain(coolDrain, hour: 9, droppedPercent: 3, dayKey: "2026-09-0\(day)")
		coolDrain = UsagePatternAnalyzer.accumulatingHourlyDrain(coolDrain, hour: 18, droppedPercent: 1, dayKey: "2026-09-0\(day)")
	}
	expect(UsagePatternAnalyzer.heatUsageOverlapInsight(drain: coolDrain, temp: temp) == nil, "热叠加洞察：高峰不在热时段不打扰")

	// 温度未达 35°C 阈值不提示
	var mildTemp = HourlyTempStats()
	for day in 1...3 {
		mildTemp = UsagePatternAnalyzer.accumulatingHourlyTemp(mildTemp, hour: 18, celsius: 32, dayKey: "2026-09-0\(day)")
	}
	expect(UsagePatternAnalyzer.heatUsageOverlapInsight(drain: drain, temp: mildTemp) == nil, "热叠加洞察：不够热不提示")

	// 样本不足（1 天）不下结论
	var fewDrain = HourlyDrainStats()
	var fewTemp = HourlyTempStats()
	fewDrain = UsagePatternAnalyzer.accumulatingHourlyDrain(fewDrain, hour: 18, droppedPercent: 3, dayKey: "2026-09-01")
	fewTemp = UsagePatternAnalyzer.accumulatingHourlyTemp(fewTemp, hour: 18, celsius: 38, dayKey: "2026-09-01")
	expect(UsagePatternAnalyzer.heatUsageOverlapInsight(drain: fewDrain, temp: fewTemp) == nil, "热叠加洞察：样本不足不下结论")

	// 温度画像按小时保留历史峰值（36 记入后 33 不覆盖）
	var t = HourlyTempStats()
	t = UsagePatternAnalyzer.accumulatingHourlyTemp(t, hour: 14, celsius: 36, dayKey: "2026-09-01")
	t = UsagePatternAnalyzer.accumulatingHourlyTemp(t, hour: 14, celsius: 33, dayKey: "2026-09-02")
	expect(abs(t.maxTempByHour[14] - 36) < 0.001, "温度画像：每小时保留历史峰值")
	expectEqual(t.accumulatedDays, 2, "温度画像：跨天推进有效天数")
}

// MARK: - 汇总

print("")
if failedNames.isEmpty {
	print("✅ 全部通过：\(passed) 项")
} else {
	print("❌ 通过 \(passed) 项，失败 \(failedNames.count) 项")
}
exit(failedNames.isEmpty ? 0 : 1)
