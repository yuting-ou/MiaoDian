import Foundation
import os

// 失败/降级分支的一次性诊断日志：同一原因仅记录一次，避免轮询热路径刷屏
// 可在任意线程调用，内部用锁保护去重集合
// 查看方式：log stream --predicate 'subsystem == "fun.crashsystem.ChargeMonitor"'
nonisolated enum DiagnosticLog {
	private static let lock = NSLock()
	nonisolated(unsafe) private static var loggedKeys = Set<String>()
	private static let subsystem = Bundle.main.bundleIdentifier ?? "fun.crashsystem.ChargeMonitor"
	
	static func failureOnce(_ key: String, category: String, _ message: String) {
		lock.lock()
		let inserted = loggedKeys.insert(key).inserted
		lock.unlock()
		guard inserted else { return }
		Logger(subsystem: subsystem, category: category).error("\(message, privacy: .public)")
	}
}
