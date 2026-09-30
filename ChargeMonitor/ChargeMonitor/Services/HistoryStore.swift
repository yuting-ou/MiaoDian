import Foundation

// 历史字节的落盘位置。
//
// 旧世界：所有历史键和用户配置挤在同一个 UserDefaults plist 里。两个后果——
// ① plist 是全量重写的，时间序列越长每次 save 的写放大越大；
// ② 一个键坏掉整档一起赔（BatteryHistoryRecorder 旧注：「损坏即静默清零」）。
// 新世界：一键一文件（Application Support/ChargeMonitor/history/<键>.plist），原子写。
//
// 迁移语义（三条，逐条有单测钉住）：
//   1. 首次读某键：文件不在 → 把 UserDefaults 里的旧字节**抄**过来
//   2. **不删旧键**：回滚到旧版本时历史回到迁移那一刻的样子，而不是清零
//   3. 幂等：文件一旦存在就再也不看旧键，重复启动不会来回搬
//
// 唯一的例外是**显式删除**（removeObject）：这时必须连带删掉旧键，
// 否则下次启动"文件不在 → 迁回旧键"会把刚被忘掉的数据复活。
nonisolated protocol HistoryByteStore {
	func data(forKey key: String) -> Data?
	func set(_ data: Data, forKey key: String)
	func removeObject(forKey key: String)
}

/// 旧家：字节仍在 UserDefaults 里。两个用途——单测直接驱动，以及当迁移来源（只读）
nonisolated final class UserDefaultsHistoryByteStore: HistoryByteStore {
	private let defaults: UserDefaults

	init(defaults: UserDefaults) {
		self.defaults = defaults
	}

	func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

	func set(_ data: Data, forKey key: String) { defaults.set(data, forKey: key) }

	func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }
}

/// 新家：一键一文件。目录由 `BatteryHistoryRecorder.historyDirectoryForTooling` 决定
/// （量具必须改道，见那里的注释）。
nonisolated final class FileHistoryByteStore: HistoryByteStore {
	private let directory: URL
	private let migrationSource: HistoryByteStore?
	private let fileManager = FileManager.default

	// 迁移只该被记一次日志，不是每个键一条
	private var didLogMigration = false

	init(directory: URL, migrationSource: HistoryByteStore? = nil) {
		self.directory = directory
		self.migrationSource = migrationSource
	}

	/// 全项目的文件名映射只此一处：键 → 文件。键都是 camelCase 标识符，不含路径分隔符
	private func url(forKey key: String) -> URL {
		directory.appendingPathComponent("\(key).plist", isDirectory: false)
	}

	func data(forKey key: String) -> Data? {
		if let onDisk = try? Data(contentsOf: url(forKey: key)) {
			return onDisk
		}
		// 文件不在 = 还没迁过这一键。旧字节抄一份过来，**旧键原样留着**（回滚安全）
		guard let legacy = migrationSource?.data(forKey: key) else { return nil }
		if !didLogMigration {
			didLogMigration = true
			DiagnosticLog.failureOnce(
				"history-migration",
				category: "HistoryStore",
				"历史数据已从 UserDefaults 迁到 \(directory.path)（旧键保留，回滚旧版本仍可读）"
			)
		}
		// 抄写失败也不丢这一次的读数：仍把旧字节交出去，下次启动再试
		write(legacy, forKey: key)
		return legacy
	}

	func set(_ data: Data, forKey key: String) {
		write(data, forKey: key)
	}

	/// 写失败只记一次日志，**不回写旧键**——故意保持"文件"是唯一真源。
	/// 回写会让旧键变成一份会过期的影子副本，下次启动读文件反而丢掉更新的值。
	/// 这里丢的是一次增量采样，下一个 tick 会重写；比制造两个真源便宜。
	private func write(_ data: Data, forKey key: String) {
		do {
			try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
			try data.write(to: url(forKey: key), options: .atomic)
		} catch {
			DiagnosticLog.failureOnce(
				"history-file-save-\(key)",
				category: "HistoryStore",
				"历史文件写入失败（\(key)）：\(error.localizedDescription)"
			)
		}
	}

	/// 显式遗忘：文件和旧键一起清，否则迁移会把刚删掉的值复活
	func removeObject(forKey key: String) {
		try? fileManager.removeItem(at: url(forKey: key))
		migrationSource?.removeObject(forKey: key)
	}
}

/// 不落盘：量具显式关闭持久化（`MIAODIAN_HISTORY_DIR=""`）时用，跑完即忘
nonisolated final class InMemoryHistoryByteStore: HistoryByteStore {
	private var storage: [String: Data] = [:]

	func data(forKey key: String) -> Data? { storage[key] }

	func set(_ data: Data, forKey key: String) { storage[key] = data }

	func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
}
