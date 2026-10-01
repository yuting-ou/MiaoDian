import AppKit
import Combine
import Foundation

// 历史采集的门面：把 7 个按数据域拆开的 recorder 收成一个 @Published 面，供面板/设置/提醒读取。
//
// 为什么拆：这个类原本 1400 行、15 组互不相关的累计器挤在一起，24 处直接调 Date()，
// 想给"睡眠掉电"写个测试得先绕过"充电器档案"。现在每个域自持状态与时钟入口，
// 各自的纯判定就是那个域的公开 API，能单独测。
//
// 门面只做三件事：① 转发 @Published（视图的观察面一个成员都没变）；
// ② 按拆分前**逐字一致**的顺序驱动各域；③ 持有持久化管道与系统通知的生命周期。
@MainActor
final class BatteryHistoryRecorder: ObservableObject {
	// 域 recorder。构造顺序有依赖：睡眠结算要把时长记进当天用电行，所以 daily 先于 sleep
	let sessions: ChargeSessionRecorder
	let health: HealthTrendRecorder
	let daily: DailyUsageRecorder
	let sleep: SleepDrainRecorder
	let charger: ChargerProfileRecorder
	let soc: SocSampleRecorder
	let events: PowerEventRecorder

	private let monitor: BatteryMonitor
	private var cancellables: Set<AnyCancellable> = []
	// 子 recorder 的 @Published 转发到门面的 objectWillChange。
	// 视图观察的是门面：少转发一条就是"界面不刷新"的静默 bug，所以这里用数组一次挂全
	private var childCancellables: Set<AnyCancellable> = []

	// backupDirectory 显式传 nil 表示关闭**备份**（单测/量具用）——它只管备份这一件事：
	// 历史主档仍走 defaultByteStore（生产=文件，量具被 MIAODIAN_HISTORY_DIR 改道）。
	// byteStore 只有显式传才换存储。
	//
	// 这里踩过一次：早先 byteStore 不传就默认成内存档，于是"关备份"顺手把历史也清空了——
	// 三个量具（离屏验收 2 处、滚动成本 2 处）全中，面板掉一半高度、真档案腿整条跳过。
	// **不要把"关备份"和"不落盘"耦合成一个默认值**；真要不落盘请显式传 InMemoryHistoryByteStore()。
	// 内部名用 store 而不是 byteStore：参数会遮蔽同名属性，init 里少写一个 self. 就会静默变成可选参数
	// clock 生产恒为 .live；它是给测试传的——7 个域必须**同一个**钟，漏传一个就是真假混合、
	// 断言看运气绿（这条由 run_tests.sh 的源文件级守卫按 `clock: clock` 出现次数核对）
	init(
		monitor: BatteryMonitor,
		defaults: UserDefaults,
		backupDirectory: URL?,
		byteStore store: HistoryByteStore? = nil,
		clock: HistoryClock = .live
	) {
		let persistence = HistoryPersistence(
			byteStore: Self.resolvedByteStore(override: store, defaults: defaults),
			backupDirectory: backupDirectory
		)
		self.monitor = monitor
		self.events = PowerEventRecorder(persistence: persistence, clock: clock)
		self.sessions = ChargeSessionRecorder(persistence: persistence, clock: clock)
		self.health = HealthTrendRecorder(persistence: persistence, defaults: defaults, events: events, monitor: monitor, clock: clock)
		self.daily = DailyUsageRecorder(persistence: persistence, monitor: monitor, clock: clock)
		self.sleep = SleepDrainRecorder(persistence: persistence, daily: daily, clock: clock)
		self.charger = ChargerProfileRecorder(persistence: persistence, clock: clock)
		self.soc = SocSampleRecorder(persistence: persistence, clock: clock)

		// 各域自己认领自己的键；门面不越权拆包（否则拆出来的域等于没拆）
		// events 先加载：health 的换电池检测会往事件时间线写一笔，顺序反了会丢那一条
		events.loadFromDisk()
		sessions.loadFromDisk()
		health.loadFromDisk()
		daily.loadFromDisk()
		sleep.loadFromDisk()
		charger.loadFromDisk()
		soc.loadFromDisk()

		// 子 recorder 的变更转发给门面：视图只订阅门面一个对象
		for publisher in [
			sessions.objectWillChange, health.objectWillChange, daily.objectWillChange,
			sleep.objectWillChange, charger.objectWillChange, soc.objectWillChange,
			events.objectWillChange,
		] {
			publisher
				.sink { [weak self] _ in self?.objectWillChange.send() }
				.store(in: &childCancellables)
		}

		// 监听系统睡眠/唤醒，统计合盖期间掉了多少电
		let workspaceCenter = NSWorkspace.shared.notificationCenter
		workspaceCenter.addObserver(self, selector: #selector(handleWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
		workspaceCenter.addObserver(self, selector: #selector(handleDidWake), name: NSWorkspace.didWakeNotification, object: nil)

		// 订阅一建立就会立刻收到当前快照，所以必须放在各项数据加载之后
		monitor.$snapshot
			.sink { [weak self] snapshot in
				self?.process(snapshot)
			}
			.store(in: &cancellables)
	}

	convenience init(monitor: BatteryMonitor, defaults: UserDefaults = .standard) {
		self.init(
			monitor: monitor,
			defaults: defaults,
			backupDirectory: Self.defaultBackupDirectory(),
			byteStore: Self.defaultByteStore(defaults: defaults)
		)
	}

	// MARK: - 对外数据面（转发，成员名与拆分前逐字一致）

	var recentSessions: [ChargeSession] { sessions.recentSessions }
	var isChargingSessionAlive: Bool { sessions.isChargingSessionAlive }
	var healthSamples: [HealthSample] { health.healthSamples }
	var healthTrend: (earliest: HealthSample, latest: HealthSample)? { health.healthTrend }
	var trendHealthSamples: [HealthSample] { health.trendHealthSamples }
	var dailyHistory: [DailyUsage] { daily.dailyHistory }
	var todayUsage: DailyUsage? { daily.todayUsage }
	var lastSleepDrain: SleepDrainRecord? { sleep.lastSleepDrain }
	var sleepDrainHistory: [SleepDrainRecord] { sleep.sleepDrainHistory }
	var chargerProfiles: [ChargerProfile] { charger.chargerProfiles }
	var currentChargerProfile: ChargerProfile? { charger.currentChargerProfile }
	var currentChargerPowerStats: ChargerPowerStats? { charger.currentChargerPowerStats }
	var socSamples: [SOCSample] { soc.socSamples }
	var socJumpEvents: [SocJumpEvent] { soc.socJumpEvents }
	var powerEvents: [PowerEvent] { events.powerEvents }
	var chargerPowerStats: [String: ChargerPowerStats] { charger.chargerPowerStats }
	var hourlyDrainStats: HourlyDrainStats { daily.hourlyDrainStats }
	var hourlyTempStats: HourlyTempStats { daily.hourlyTempStats }
	var appEnergy: [AppEnergyUsage] { daily.appEnergy }

	func setChargerCustomName(key: String, customName: String?) {
		charger.setChargerCustomName(key: key, customName: customName)
	}

	// MARK: - 每拍驱动

	// 顺序与拆分前逐字一致，两处顺序是**有理由的**，改动前先读注释：
	// ① 先认充电器再开会话：新会话要带上"是谁充的"身份键
	// ② 睡眠结算要在建好当天日行之后：跨午夜那一觉醒来时"今天"的行还不存在，
	//    先结算会被 creditingSleepTime 的"缺行跳过"整夜吞掉
	//
	// 这两条顺序原先只靠本注释钉着——调乱了 1473 项测试一项都不会红（每域各自自洽，
	// 错的只是跨域的接线）。现由「门面顺序」那组断言逐条钉住，见 测试/main.swift。
	// **internal 只为让那组断言能直接驱动**（生产入口只有上面 init 里那一处订阅），
	// 不许长出第二条调用路径；要加入口先想清楚会不会有第二个 driver 同时喂快照。
	func process(_ snapshot: BatterySnapshot) {
		charger.updateChargerProfile(snapshot)
		sessions.updateChargeSession(snapshot, chargerKey: charger.activeChargerKey)
		charger.accumulateChargerPower(snapshot)
		health.recordDailyHealth(snapshot)
		daily.updateDailyUsage(snapshot)
		sleep.finalizeSleepDrainIfNeeded(snapshot)
		soc.recordSOCSample(snapshot)
		events.recordPowerEvents(snapshot)
		daily.accumulateAppEnergy()
		soc.trackSocJumps(snapshot)
		daily.accumulateHourlyTemp(snapshot)
	}

	// MARK: - 合盖/唤醒（转给睡眠与事件两个域）
	//
	// @objc 是 NSWorkspace 通知的 selector 需要，internal 是顺序断言需要（同 process 的理由）。
	@objc func handleWillSleep() {
		events.appendPowerEvent(.sleep)
		// lastPercentForDaily 是每日用电域维护的"最后一次采样电量"，合盖那一刻的电量由它提供；
		// 供电来源要在这一刻定格（见 SleepDrainRecorder.handleWillSleep 的 onAC 语义）。
		// 注意：测试里 monitor 是空默认档（powerSource 恒 .battery），这条 handler 的
		// "定格供电来源"语义测试盖不住，只测顺序——见 测试/main.swift 该组断言的前提说明。
		sleep.handleWillSleep(
			onAC: monitor.snapshot.powerSource == .powerAdapter,
			lastPercent: daily.lastPercentForDaily
		)
	}

	@objc func handleDidWake() {
		events.appendPowerEvent(.wake)
		sleep.handleDidWake()
	}

	// MARK: - 持久化

	// 历史曾经和设置挤在同一个 UserDefaults plist 里（损坏即静默清零）；
	// 现在主档是一键一文件（HistoryStore.swift），这里保留的是**第二道**保险：
	// 把历史键的最新编码滚到独立备份文件，主档损坏时回退备份，最多丢一个备份间隔
	private static func defaultBackupDirectory() -> URL? {
		backupDirectoryForTooling(env: ProcessInfo.processInfo.environment)
	}

	/// 生产的历史主档：一键一文件，首次启动把 UserDefaults 里的旧字节抄过来（旧键保留）
	nonisolated static func defaultByteStore(
		defaults: UserDefaults,
		env: [String: String] = ProcessInfo.processInfo.environment
	) -> HistoryByteStore {
		guard let directory = historyDirectoryForTooling(env: env) else {
			return InMemoryHistoryByteStore()
		}
		return FileHistoryByteStore(
			directory: directory,
			migrationSource: UserDefaultsHistoryByteStore(defaults: defaults)
		)
	}

	/// 存储决策：显式传了就用传的，否则走生产路径。**单独抽出来是为了能被测到**——
	/// 这里曾经写成 `store ?? InMemoryHistoryByteStore()`，把"关备份"和"不落盘"耦合成一个默认值，
	/// 三个量具的历史一起变空（面板掉一半高度、真档案腿整条跳过），而当时没有任何断言看着这一行。
	nonisolated static func resolvedByteStore(
		override store: HistoryByteStore?,
		defaults: UserDefaults,
		env: [String: String] = ProcessInfo.processInfo.environment
	) -> HistoryByteStore {
		store ?? defaultByteStore(defaults: defaults, env: env)
	}

	/// 历史备份目录。**生产不设环境变量时行为与历史完全一致**；离屏量具必须把它重定向到临时目录，
	/// 否则量具一次 `save()` 就把用户"主档损坏时的抢救源"换成量具快照（v2.9.15 审查抓到：
	/// 这条路径硬编码在 App Support/ChargeMonitor，**不吃 bundle id**，所以换域名挡不住它）。
	/// 空字符串 = 关闭备份。
	nonisolated static func backupDirectoryForTooling(env: [String: String]) -> URL? {
		if let raw = env["MIAODIAN_BACKUP_DIR"] {
			return raw.isEmpty ? nil : URL(fileURLWithPath: raw, isDirectory: true)
		}
		return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
			.appendingPathComponent("ChargeMonitor", isDirectory: true)
	}

	/// 历史主档目录。生产默认 App Support/ChargeMonitor/history；量具必须重定向到临时目录。
	///
	/// **兜底比显式变量更重要**：量具只设了 `MIAODIAN_BACKUP_DIR` 而忘了设 HISTORY 时，
	/// 历史目录跟着备份目录一起改道——v2.9.15 抓到过同型事故（备份路径重定向了，
	/// 另一条硬编码路径却把用户的真数据写花），所以这里用默认值把那条路直接堵死，
	/// 不指望每个量具作者都记得加一行 export。
	///
	/// 空字符串 = 关闭持久化（走内存档，跑完即忘）。与 `backupDirectoryForTooling` 同语义。
	nonisolated static func historyDirectoryForTooling(env: [String: String]) -> URL? {
		if let raw = env["MIAODIAN_HISTORY_DIR"] {
			return raw.isEmpty ? nil : URL(fileURLWithPath: raw, isDirectory: true)
		}
		if let backupRaw = env["MIAODIAN_BACKUP_DIR"] {
			guard !backupRaw.isEmpty else { return nil }
			return URL(fileURLWithPath: backupRaw, isDirectory: true)
				.appendingPathComponent("history", isDirectory: true)
		}
		return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
			.appendingPathComponent("ChargeMonitor", isDirectory: true)
			.appendingPathComponent("history", isDirectory: true)
	}

	// MARK: - 全量存档（换机/重装的数据逃生舱）

	func makeArchive() -> BatteryHistoryArchive {
		BatteryHistoryArchive(
			exportedAt: Date(),
			sessions: sessions.recentSessions,
			healthSamples: health.healthSamples,
			dailyHistory: daily.dailyHistory,
			lastSleepDrain: sleep.lastSleepDrain,
			sleepDrainHistory: sleep.sleepDrainHistory,
			chargerProfiles: charger.chargerProfiles,
			socSamples: soc.socSamples,
			powerEvents: events.powerEvents,
			chargerPowerStats: charger.chargerPowerStats,
			hourlyDrainStats: daily.hourlyDrainStats,
			hourlyTempStats: daily.hourlyTempStats,
			appEnergy: daily.appEnergy,
			socJumpEvents: soc.socJumpEvents,
			batterySerialLastSeen: health.batterySerialLastSeen,
			batteryReplacedAt: health.batteryReplacedAt
		)
	}

	// 从存档恢复全部历史并逐键落盘（滚动备份随之刷新）；
	// 活动充电会话是运行态，不覆盖——若恢复时正在充电，本次会话继续记账。
	// 每个域只认领自己那一段，门面不拆包
	func restore(from archive: BatteryHistoryArchive) {
		sessions.restore(from: archive)
		health.restore(from: archive)
		daily.restore(from: archive)
		sleep.restore(from: archive)
		charger.restore(from: archive)
		soc.restore(from: archive)
		events.restore(from: archive)
	}
}
