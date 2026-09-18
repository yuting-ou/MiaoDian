import Foundation

/// nonisolated：存储协议不绑 MainActor，测试面可同步驱动；Manager 在 MainActor 调用即可
nonisolated protocol ConfigurationStoring {
	/// 磁盘上是否已有配置字节（解码失败时用于区分「从未写过」与「有档但坏了」）
	var hasStoredBytes: Bool { get }
	/// 成功则返回配置；解码失败返回 nil，且**不得**由调用方写回默认覆盖原字节
	func load() -> AppConfiguration?
	func save(_ configuration: AppConfiguration)
}

final class UserDefaultsConfigurationStore: ConfigurationStoring {
	private let defaults: UserDefaults
	private let key: String
	private let decoder = PropertyListDecoder()
	private let encoder = PropertyListEncoder()

	init(defaults: UserDefaults = .standard, key: String = "appConfiguration") {
		self.defaults = defaults
		self.key = key
	}

	var hasStoredBytes: Bool {
		defaults.data(forKey: key) != nil
	}

	func load() -> AppConfiguration? {
		guard let data = defaults.data(forKey: key) else { return nil }
		do {
			return try decoder.decode(AppConfiguration.self, from: data)
		} catch {
			// CRITICAL 纪律：解码失败只返回 nil，**绝不**在这里或 Manager 里把
			// 默认配置写回同一 key——那会静默销毁用户损坏档里仍可抢救的字段。
			// 调用方见 ConfigurationManager.init：有字节但解码失败 → 内存用默认、磁盘原样保留。
			return nil
		}
	}

	func save(_ configuration: AppConfiguration) {
		guard let data = try? encoder.encode(configuration) else { return }
		defaults.set(data, forKey: key)
	}
}
