import Foundation

// 子进程执行器：读取系统命令的标准输出，带超时看门狗强制终止，
// 避免轮询路径因子进程卡死而永久卡住（stderr 必须丢弃，否则缓冲区写满会死锁）
nonisolated enum SubprocessRunner {
	static func run(_ path: String, arguments: [String], timeout: TimeInterval = 10) -> Data? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: path)
		process.arguments = arguments

		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice

		do {
			try process.run()
		} catch {
			DiagnosticLog.failureOnce("launch-failed-\(path)", category: "SubprocessRunner", "启动 \(path) 失败：\(error.localizedDescription)")
			return nil
		}

		let killer = DispatchWorkItem {
			if process.isRunning {
				process.terminate()
				DiagnosticLog.failureOnce("timeout-\(path)", category: "SubprocessRunner", "\(path) 超过 \(Int(timeout)) 秒未返回，已强制终止")
			}
		}
		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		killer.cancel()
		return data
	}
}
