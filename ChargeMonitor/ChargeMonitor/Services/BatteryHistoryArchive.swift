import Foundation

// 全量历史存档：换机/重装前的"数据逃生舱"，JSON 落盘、人可读、带版本号
// 只含历史数据，不含活动充电会话等运行态——存档管"历史"，运行态由应用自己接管
nonisolated struct BatteryHistoryArchive: Codable {
	static let currentVersion = 1

	var version: Int = BatteryHistoryArchive.currentVersion
	var exportedAt: Date
	var sessions: [ChargeSession]
	var healthSamples: [HealthSample]
	var dailyHistory: [DailyUsage]
	var lastSleepDrain: SleepDrainRecord?
	var chargerProfiles: [ChargerProfile]
	var socSamples: [SOCSample]
	var powerEvents: [PowerEvent]
	var chargerPowerStats: [String: ChargerPowerStats]
	var hourlyDrainStats: HourlyDrainStats
	var appEnergy: [AppEnergyUsage]
	var socJumpEvents: [SocJumpEvent]

	static func encode(_ archive: BatteryHistoryArchive) -> Data? {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		return try? encoder.encode(archive)
	}

	// 版本不匹配（未来格式）直接拒绝，宁可导入失败也不静默丢字段
	static func decode(_ data: Data) -> BatteryHistoryArchive? {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		guard
			let archive = try? decoder.decode(BatteryHistoryArchive.self, from: data),
			archive.version == BatteryHistoryArchive.currentVersion
		else { return nil }
		return archive
	}
}
