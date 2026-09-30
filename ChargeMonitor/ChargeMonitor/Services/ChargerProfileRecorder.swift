import AppKit
import Combine
import Foundation

// 充电器档案：身份键、物理头归并、协商功率统计。
// 身份键的后三项都是协商产物（多口充电器被分走功率时会漂移），所以用别名归并而不是改主键。
@MainActor
final class ChargerProfileRecorder: ObservableObject {
	// 档案键、上限与「多口降档」识别的等待窗口
	nonisolated private static let chargerProfilesKey = "chargerProfiles"
	nonisolated private static let chargerPowerStatsKey = "chargerPowerStats"
	nonisolated private static let maxChargerProfiles = 20
	// 半小时内重复见到同一充电器（如应用重启）不重复计次
	nonisolated private static let chargerRecountSeconds: TimeInterval = 30 * 60
	// 适配器名称/厂商信息可能晚几秒才到位，最多等这么久再退而求其次按额定功率建档
	nonisolated private static let chargerIdentityWaitSeconds: TimeInterval = 10

	// 见过的充电器档案
	@Published private(set) var chargerProfiles: [ChargerProfile] = []
	// 充电器质量诊断：按充电器累计的协商功率样本
	@Published private(set) var chargerPowerStats: [String: ChargerPowerStats] = [:]
	// 充电器档案：本次接入已建档的身份键与接入时刻
	private(set) var activeChargerKey: String?
	private var adapterConnectedAt: Date?
	private var lastChargerStatsSave = Date.distantPast

	private let persistence: HistoryPersistence
	// 时间从构造器进来：测试给一个可推进的假钟就能把跨午夜/断档这类状态机走完
	private let clock: HistoryClock

	init(persistence: HistoryPersistence, clock: HistoryClock = .live) {
		self.clock = clock
		self.persistence = persistence
	}

	// 落盘转发（与拆分前的写法保持一致，调用点不用改）
	private func load<T: Decodable>(_ type: T.Type, key: String) -> T? { persistence.load(type, key: key) }
	private func save<T: Encodable>(_ value: T, key: String) { persistence.save(value, key: key) }


	// 充电器身份键：名称|厂商|额定功率[|PD档位签名][|无线]，建档与相认都靠它，各处必须同源。
	// 档位签名让"两只都是 100W"的不同充电器分开——不同品牌/型号广播的 PDO 组合
	// 几乎必然不同；非 PD 头没有档位表，键退回旧格式，存量档案不重置。
	nonisolated static func chargerKey(
		name: String,
		manufacturer: String,
		ratedWatts: Int,
		tiers: [PowerTier] = [],
		isWireless: Bool = false
	) -> String {
		var key = "\(name)|\(manufacturer)|\(ratedWatts)"
		let signature = tierSignature(tiers)
		if !signature.isEmpty { key += "|\(signature)" }
		if isWireless { key += "|无线" }
		return key
	}

	// 档位集合排序拼接的稳定签名（顺序无关）；读不到档位时为空
	nonisolated static func tierSignature(_ tiers: [PowerTier]) -> String {
		tiers.map { "\($0.maxVoltageMV)V\($0.maxCurrentMA)A" }.sorted().joined(separator: "/")
	}

	// 兜底名判定：建档时名称/厂商没广播出来，档案名落到"N瓦 充电器"模式——
	// 这是"没认出来"的痕迹而非真名，归并判定与真名回填都以它为信号
	nonisolated static func isFallbackChargerName(_ name: String, ratedWatts: Int?) -> Bool {
		if name.isEmpty { return true }
		if name.hasSuffix("W 充电器") { return true }
		if let ratedWatts, ratedWatts > 0, name == "\(ratedWatts)W 充电器" { return true }
		return false
	}

	// 识别 v2：降档形态判定——同一只头被分走功率时，本口广播的档位与满载母集
	// 同数量、同电压阶梯、电流只降不增（如 20V/3.5A 是 20V/5A 的降档形态）。
	// 刻意要求档位数量一致：不同的小头（如 65W 缺 15V 档）逐档被包含也不算同一只
	nonisolated static func tiers(_ degraded: [PowerTier], degradationOf mother: [PowerTier]) -> Bool {
		guard degraded.count == mother.count, !degraded.isEmpty else { return false }
		return degraded.allSatisfy { tier in
			mother.contains { $0.maxVoltageMV == tier.maxVoltageMV && $0.maxCurrentMA >= tier.maxCurrentMA }
		}
	}

	// 别名感知的档案查找：正式键或别名键都认（归并后的历史会话键是别名）
	nonisolated static func chargerProfile(matching key: String, in profiles: [ChargerProfile]) -> ChargerProfile? {
		profiles.first { $0.key == key || $0.aliases?.contains(key) == true }
	}

	// 识别 v2 核心：把"无名降档孤儿"归并进"有名母档案"，返回归并后档案与正式键。
	// 孤儿 = 名称为空的档案或未建档的新键（多口分功率时名称/厂商/瓦数/档位会一起漂移）；
	// 母档案条件 = 有名 + 孤儿档位 ⊆ 母档位 + 无线标记一致。
	// 幂等：归并后孤儿键进 aliases，再次调用命中别名直接返回母键。
	// 保守边界：有名的新键视为真新头不归并；无名对无名不归并（无信号）。
	nonisolated static func foldingOrphanCharger(
		profiles: [ChargerProfile],
		orphanKey: String,
		orphanName: String,
		orphanConnectCount: Int,
		orphanRatedWatts: Int?,
		orphanTiers: [PowerTier],
		isWireless: Bool
	) -> (profiles: [ChargerProfile], canonicalKey: String) {
		// 精确命中（正式键或别名）→ 正式键；命中的若是有名档案即完成
		if let hit = chargerProfile(matching: orphanKey, in: profiles) {
			// 命中的是无名/兜底名档案：尝试把它并入某个有名母档案（历史遗留孤儿的收编）
			if !isFallbackChargerName(hit.name, ratedWatts: hit.ratedWatts) { return (profiles, hit.key) }
			// 命中的是无名档案：尝试把它并入某个有名母档案（历史遗留孤儿的收编）；
			// 必须带上孤儿自己的档位/次数/瓦数——它们描述的是同一只头的降档历史
			if let resolved = foldingOrphanIntoMother(
				profiles: profiles,
				orphanKey: orphanKey,
				orphanConnectCount: hit.connectCount,
				orphanRatedWatts: hit.ratedWatts,
				orphanTiers: tiers(fromSignature: hit.tierSignature ?? ""),
				isWireless: hit.key.hasSuffix("|无线")
			) {
				return (resolved.profiles, resolved.canonicalKey)
			}
			return (profiles, hit.key)
		}
		// 未建档的新键：无名（含兜底名）才可能是有名母档案的降档形态；有名新键就是新头
		guard isFallbackChargerName(orphanName, ratedWatts: orphanRatedWatts), !orphanTiers.isEmpty,
			let resolved = foldingOrphanIntoMother(
				profiles: profiles,
				orphanKey: orphanKey,
				orphanConnectCount: 0,
				orphanRatedWatts: orphanRatedWatts,
				orphanTiers: orphanTiers,
				isWireless: isWireless
			) else { return (profiles, orphanKey) }
		return (resolved.profiles, resolved.canonicalKey)
	}

	// 归并执行：孤儿（已有档案或仅新键）并入母档案。次数相加、首见取早、末见取晚、
	// 观察瓦数并集、别名收编（孤儿自己的别名一并带上，链式归并不断链）
	nonisolated private static func foldingOrphanIntoMother(
		profiles: [ChargerProfile],
		orphanKey: String,
		orphanConnectCount: Int = 0,
		orphanRatedWatts: Int? = nil,
		orphanTiers: [PowerTier] = [],
		isWireless: Bool = false
	) -> (profiles: [ChargerProfile], canonicalKey: String)? {
		guard let motherIndex = profiles.firstIndex(where: { mother in
			// "有名" = 有真名或用户认领名（customName 是最强身份信号）；
			// 纯兜底名（"100W 充电器"）即使是母头本尊，也因无真名信号而保持独立
			(!isFallbackChargerName(mother.name, ratedWatts: mother.ratedWatts)
				|| mother.customName?.isEmpty == false)
				&& mother.key != orphanKey
				&& tiers(orphanTiers, degradationOf: tiers(fromSignature: mother.tierSignature ?? ""))
				&& mother.key.hasSuffix("|无线") == isWireless
		}) else { return nil }

		var mother = profiles[motherIndex]
		var aliases = mother.aliases ?? []
		aliases.append(orphanKey)

		var result = profiles
		if let orphanIndex = result.firstIndex(where: { $0.key == orphanKey }) {
			let orphan = result[orphanIndex]
			mother.connectCount += orphan.connectCount
			mother.firstSeen = Swift.min(mother.firstSeen, orphan.firstSeen)
			mother.lastSeen = Swift.max(mother.lastSeen, orphan.lastSeen)
			if mother.customName == nil { mother.customName = orphan.customName }
			aliases.append(contentsOf: orphan.aliases ?? [])
			result.remove(at: orphanIndex)
		}
		var observed = Set(mother.observedWatts ?? [])
		if let orphanRatedWatts, orphanRatedWatts > 0 { observed.insert(orphanRatedWatts) }
		if let motherRated = mother.ratedWatts, motherRated > 0 { observed.insert(motherRated) }
		mother.aliases = Array(Set(aliases)).filter { $0 != mother.key }.sorted()
		mother.observedWatts = observed.sorted()
		result[motherIndex] = mother
		return (result, mother.key)
	}

	// 识别 v2 迁移：把历史遗留的"无名降档孤儿档案"并回有名母档案（幂等，读档后跑一次）。
	// 一轮归并可能露出新的可归并对（别名链），循环到不再变化
	nonisolated static func foldingOrphanProfiles(_ profiles: [ChargerProfile]) -> [ChargerProfile] {
		var result = profiles
		var changed = true
		while changed {
			changed = false
			for orphan in result where isFallbackChargerName(orphan.name, ratedWatts: orphan.ratedWatts) {
				let orphanTiers = tiers(fromSignature: orphan.tierSignature ?? "")
				guard !orphanTiers.isEmpty else { continue }
				let folded = foldingOrphanCharger(
					profiles: result,
					orphanKey: orphan.key,
					orphanName: orphan.name,
					orphanConnectCount: orphan.connectCount,
					orphanRatedWatts: orphan.ratedWatts,
					orphanTiers: orphanTiers,
					isWireless: orphan.key.hasSuffix("|无线")
				)
				guard folded.profiles.count < result.count else { continue }
				result = folded.profiles
				changed = true
				break
			}
		}
		return result
	}

	// 名称后到补全：建档时名没广播出来（10 秒兜底建档），后续采样把真名补上——
	// 显示与归并判定都以真名为准
	nonisolated static func backfillingChargerName(profiles: [ChargerProfile], key: String, name: String) -> [ChargerProfile] {
		var profiles = profiles
		guard !name.isEmpty,
			let index = profiles.firstIndex(where: { $0.key == key || $0.aliases?.contains(key) == true }),
			isFallbackChargerName(profiles[index].name, ratedWatts: profiles[index].ratedWatts) else { return profiles }
		var profile = profiles[index]
		profile.name = name
		profiles[index] = profile
		return profiles
	}

	// 已知身份的充电器更新或建档：
	// 重连窗口内再见不重复计次（如应用重启），超窗算一次新连接；档案满了挤掉最久没见的
	nonisolated static func upsertingChargerProfile(
		_ profiles: [ChargerProfile],
		key: String,
		name: String,
		manufacturer: String,
		ratedWatts: Int,
		tierSignature: String? = nil,
		observedWatts: Int? = nil,
		now: Date
	) -> [ChargerProfile] {
		var profiles = profiles
		if let index = profiles.firstIndex(where: { $0.key == key }) {
			if now.timeIntervalSince(profiles[index].lastSeen) > chargerRecountSeconds {
				profiles[index].connectCount += 1
			}
			profiles[index].lastSeen = now
			// 名称后到补全 + 观察瓦数并集（同一头随负载浮动，见多识广不是换头）
			if profiles[index].name.isEmpty, !name.isEmpty { profiles[index].name = name }
			if let observedWatts, observedWatts > 0 {
				var seen = Set(profiles[index].observedWatts ?? [])
				seen.insert(observedWatts)
				if let rated = profiles[index].ratedWatts, rated > 0 { seen.insert(rated) }
				profiles[index].observedWatts = Array(seen).sorted()
			}
		} else {
			let fallbackName = manufacturer.isEmpty ? "\(ratedWatts)W 充电器" : manufacturer
			profiles.append(ChargerProfile(
				key: key,
				name: name.isEmpty ? fallbackName : name,
				ratedWatts: ratedWatts > 0 ? ratedWatts : nil,
				firstSeen: now,
				lastSeen: now,
				connectCount: 1,
				tierSignature: tierSignature,
				aliases: nil,
				observedWatts: ratedWatts > 0 ? [ratedWatts] : nil
			))
			if profiles.count > maxChargerProfiles {
				profiles.sort { $0.lastSeen < $1.lastSeen }
				profiles.removeFirst(profiles.count - maxChargerProfiles)
			}
		}
		return profiles
	}

	// 功率统计只保留仍建档的充电器（纯函数，单测直测）
	nonisolated static func pruningChargerPowerStats(
		_ stats: [String: ChargerPowerStats],
		keeping profiles: [ChargerProfile]
	) -> [String: ChargerPowerStats] {
		let keys = Set(profiles.map(\.key))
		guard stats.count > keys.count else { return stats }
		return stats.filter { keys.contains($0.key) }
	}

	// 当前接着的充电器对应的档案（拔电后为 nil）
	var currentChargerProfile: ChargerProfile? {
		guard let key = activeChargerKey else { return nil }
		return Self.chargerProfile(matching: key, in: chargerProfiles)
	}

	// 用户给充电器起的名字（系统识别不了时由用户认领）；空字符串视为清除
	func setChargerCustomName(key: String, customName: String?) {
		guard let index = chargerProfiles.firstIndex(where: { $0.key == key }) else { return }
		var profile = chargerProfiles[index]
		profile.customName = (customName?.isEmpty == false) ? customName : nil
		chargerProfiles[index] = profile
		save(chargerProfiles, key: Self.chargerProfilesKey)
	}

	func updateChargerProfile(_ snapshot: BatterySnapshot) {
		guard snapshot.powerSource == .powerAdapter else {
			activeChargerKey = nil
			adapterConnectedAt = nil
			return
		}
		if adapterConnectedAt == nil { adapterConnectedAt = clock.now() }
		guard activeChargerKey == nil else {
			// 已建档的会话：名广播出来后回填（建档时名没到位走的是兜底建档）——
			// 显示与归并判定都以真名为准
			if let key = activeChargerKey {
				let incomingName = snapshot.adapterName ?? ""
				chargerProfiles = Self.backfillingChargerName(profiles: chargerProfiles, key: key, name: incomingName)
			}
			return
		}

		let name = snapshot.adapterName ?? ""
		let manufacturer = snapshot.adapterManufacturer ?? ""
		let rated = snapshot.adapterRatedWatts ?? 0
		// 名称/厂商任一到位就建档；都没有则等几秒，超时后按额定功率建档
		if name.isEmpty, manufacturer.isEmpty {
			guard rated > 0,
				let connectedAt = adapterConnectedAt,
				clock.now().timeIntervalSince(connectedAt) >= Self.chargerIdentityWaitSeconds
			else { return }
		}
		// 档位签名进键：两只同瓦数的不同充电器分开建档；无线头带标记。
		// 识别 v2：无名降档会话先做物理头归并解析——同一只头（多口分功率/协议降档）沿用老档案，
		// 统计与速度对比连成一条线；正式键 = 母档案首建档键，降档键收进别名
		let signature = Self.tierSignature(snapshot.powerTiers)
		let wireless = snapshot.chargingProtocol == "无线充电"
		let rawKey = Self.chargerKey(
			name: name,
			manufacturer: manufacturer,
			ratedWatts: rated,
			tiers: snapshot.powerTiers,
			isWireless: wireless
		)
		let resolved = Self.foldingOrphanCharger(
			profiles: chargerProfiles,
			orphanKey: rawKey,
			orphanName: name,
			orphanConnectCount: 0,
			orphanRatedWatts: rated > 0 ? rated : nil,
			orphanTiers: snapshot.powerTiers,
			isWireless: wireless
		)
		chargerProfiles = resolved.profiles
		activeChargerKey = resolved.canonicalKey
		chargerProfiles = Self.upsertingChargerProfile(
			chargerProfiles,
			key: resolved.canonicalKey,
			name: name,
			manufacturer: manufacturer,
			ratedWatts: rated,
			tierSignature: signature.isEmpty ? nil : signature,
			observedWatts: rated > 0 ? rated : nil,
			now: clock.now()
		)
		save(chargerProfiles, key: Self.chargerProfilesKey)
		// 功率统计跟着档案走：档案挤掉最旧后，对应统计一并清理，不留孤儿数据
		let prunedStats = Self.pruningChargerPowerStats(chargerPowerStats, keeping: chargerProfiles)
		if prunedStats.count != chargerPowerStats.count {
			chargerPowerStats = prunedStats
			save(chargerPowerStats, key: Self.chargerPowerStatsKey)
		}
	}

	// 当前充电器累计的协商功率样本（供诊断；拔电后为 nil）
	var currentChargerPowerStats: ChargerPowerStats? {
		guard let key = activeChargerKey else { return nil }
		return chargerPowerStats[key]
	}

	// 充电期间累计协商功率：每帧把当前协商瓦数滚进对应充电器的统计，
	// 事后算平均，识别"额定 65W 却一直只协商 20W"这类劣质线/口
	// 落盘限频：纯累计变化最多一分钟存一次，避免每 2 秒写一次
	func accumulateChargerPower(_ snapshot: BatterySnapshot) {
		guard let key = activeChargerKey else { return }
		guard snapshot.powerSource == .powerAdapter, snapshot.isCharging else { return }
		guard
			let voltageMV = snapshot.negotiatedVoltageMV,
			let currentMA = snapshot.negotiatedCurrentMA,
			voltageMV > 0, currentMA > 0
		else { return }
		let watts = Double(voltageMV) * Double(currentMA) / 1_000_000.0
		guard watts >= IOKitBatteryReader.minimumVisibleWatts else { return }

		var stats = chargerPowerStats[key] ?? ChargerPowerStats(key: key, ratedWatts: snapshot.adapterRatedWatts)
		stats.sampleCount += 1
		stats.sumWatts += watts
		stats.maxWatts = max(stats.maxWatts, watts)
		chargerPowerStats[key] = stats

		if clock.now().timeIntervalSince(lastChargerStatsSave) >= 60 {
			lastChargerStatsSave = clock.now()
			save(chargerPowerStats, key: Self.chargerPowerStatsKey)
		}
	}

	// 档位签名反解析（归并判定要拿母档案的档位集合比较）
	nonisolated static func tiers(fromSignature signature: String) -> [PowerTier] {
		signature.split(separator: "/").compactMap { token in
			let parts = token.split(separator: "V")
			guard parts.count == 2, let v = Int(parts[0]), let a = Int(parts[1].dropLast()) else { return nil }
			return PowerTier(maxVoltageMV: v, maxCurrentMA: a)
		}
	}

	// MARK: - 自己的加载与恢复

	func loadFromDisk() {
		chargerProfiles = Self.foldingOrphanProfiles(load([ChargerProfile].self, key: Self.chargerProfilesKey) ?? [])
		chargerPowerStats = load([String: ChargerPowerStats].self, key: Self.chargerPowerStatsKey) ?? [:]
	}

	func restore(from archive: BatteryHistoryArchive) {
		chargerProfiles = archive.chargerProfiles
		chargerPowerStats = archive.chargerPowerStats
		save(chargerProfiles, key: Self.chargerProfilesKey)
		save(chargerPowerStats, key: Self.chargerPowerStatsKey)
	}
}
