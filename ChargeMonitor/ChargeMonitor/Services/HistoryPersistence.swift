import Foundation

// 历史持久化管道：编码/解码、滚动备份、损坏回退。
//
// 这段逻辑原本长在 BatteryHistoryRecorder 里。按数据域拆分后，每个域 recorder 都要落盘，
// 管道只该有一份——域 recorder 各持一个引用，谁也不复制它。
@MainActor
final class HistoryPersistence {
	// 滚动备份的文件名与落盘间隔；测试直接引用文件名，保持单一数据源
	nonisolated static let backupFileName = "history-backup.plist"
	nonisolated private static let backupIntervalSeconds: TimeInterval = 30 * 60

	private let byteStore: HistoryByteStore
	private let decoder = PropertyListDecoder()
	private let encoder = PropertyListEncoder()
	// 滚动备份：写入时顺手把各历史键的最新编码攒在内存，定期滚到独立文件；
	// 主档损坏时从中抢救（主档现在是一键一文件，这是第二道保险）
	private let backupDirectory: URL?
	private var backupRaw: [String: Data] = [:]
	private var lastBackupSave = Date.distantPast

	init(byteStore: HistoryByteStore, backupDirectory: URL?) {
		self.byteStore = byteStore
		self.backupDirectory = backupDirectory
		// 备份先于主档加载：主档损坏时靠它抢救
		self.backupRaw = [:]
		self.backupRaw = loadBackupRaw()
	}

	private var backupFileURL: URL? {
		backupDirectory?.appendingPathComponent(Self.backupFileName)
	}

	private func loadBackupRaw() -> [String: Data] {
		guard let url = backupFileURL, let data = try? Data(contentsOf: url) else { return [:] }
		return (try? PropertyListDecoder().decode([String: Data].self, from: data)) ?? [:]
	}

	private func saveBackupIfDue(now: Date = Date()) {
		guard let url = backupFileURL, now.timeIntervalSince(lastBackupSave) >= Self.backupIntervalSeconds else { return }
		lastBackupSave = now
		do {
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try PropertyListEncoder().encode(backupRaw).write(to: url, options: .atomic)
		} catch {
			DiagnosticLog.failureOnce("backup-save-failed", category: "BatteryHistoryRecorder", "历史滚动备份写入失败：\(error.localizedDescription)")
		}
	}

	func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
		let primary = byteStore.data(forKey: key)
		let recovered = Self.decodingWithFallback(type, primaryData: primary, backupData: backupRaw[key])
		if let primary, (try? decoder.decode(type, from: primary)) == nil {
			DiagnosticLog.failureOnce("history-corrupt-\(key)", category: "BatteryHistoryRecorder", "历史数据 \(key) 损坏\(recovered != nil ? "，已从滚动备份恢复" : "，且无可用的滚动备份")")
		}
		return recovered
	}

	// 纯函数：主档 + 备份的解码策略，供单测直接调
	// 主档正常直接解码；主档有数据却解不开（损坏）回退备份；
	// 主档无数据（首次运行/被清空）不碰备份——备份只救损坏，不做删除恢复
	nonisolated static func decodingWithFallback<T: Decodable>(_ type: T.Type, primaryData: Data?, backupData: Data?) -> T? {
		guard let primaryData else { return nil }
		if let value = try? PropertyListDecoder().decode(type, from: primaryData) { return value }
		guard let backupData else { return nil }
		return try? PropertyListDecoder().decode(type, from: backupData)
	}

	func save<T: Encodable>(_ value: T, key: String) {
		guard let data = try? encoder.encode(value) else { return }
		byteStore.set(data, forKey: key)
		// 备份内存随写入保持最新，定期滚到磁盘
		backupRaw[key] = data
		saveBackupIfDue()
	}

	/// 显式遗忘（会话归档、恢复存档时清空某键）。走 byteStore 才会连带清掉 UserDefaults 旧键，
	/// 否则下次启动"文件不在 → 迁回旧键"会把刚删掉的数据复活
	func remove(key: String) {
		byteStore.removeObject(forKey: key)
		backupRaw.removeValue(forKey: key)
	}
}
